-- =====================================================================
--  MÓDULO 6 · Leer rápido: índice primario, proyección, índice de salto,
--             réplicas en paralelo, caché
-- =====================================================================
--  Para cada consulta, apunta en la consola: duración, filas leídas, GB leídos.
--  Las cifras "Medido" vienen del servicio de pruebas: 3 réplicas de
--  64 GB (16 vCPU), configurado como el tuyo, sobre 1,488 mil M de puntos.
--
--  Las cinco palancas, de la más importante a la más puntual:
--    1. leer menos filas gracias al ORDER BY (índice primario)
--    2. repartir un escaneo grande entre todas las réplicas (parallel replicas)
--    3. preagregar (proyección)
--    4. saltar bloques en una columna fuera de la clave (índice de salto)
--    5. no recalcular lo que se acaba de calcular (caché de consultas)
-- =====================================================================


-- CONSULTA 1 · La curva de UN contador en el mes (el caso del portal de cliente)
--  El filtro sigue el inicio del ORDER BY (magnitud, id_contador): ClickHouse salta
--  directamente a los gránulos correctos (regla schema-pk-filter-on-orderby).
SELECT toTimeZone(ts, 'Europe/Madrid') AS hora, valor_w
FROM silver.curva_carga_xl
WHERE magnitud = 'CONS' AND id_contador = sim_id_contador(123456)   -- las 2 primeras columnas del ORDER BY
ORDER BY ts;
-- Medido: 264 ms · 16 384 filas leídas (272 KB) en la primera llamada a una réplica (lectura en frío), luego de 5 a 55 ms
-- Qué observar: la 1.ª lectura viene del almacenamiento de objetos; en las siguientes
-- ha tomado el relevo la caché de disco local de la réplica.

--  EXPLAIN indexes = 1 muestra lo que ha descartado el índice, sin ejecutar la consulta.
EXPLAIN indexes = 1
SELECT valor_w FROM silver.curva_carga_xl WHERE magnitud = 'CONS' AND id_contador = sim_id_contador(123456);
-- Qué observar: bajo "PrimaryKey", la línea "Granules". Dos gránulos de 8 192 filas
-- leídos de ~180 000: por eso la consulta es instantánea.


-- CONSULTA 2 · Por provincia: 1 500 millones de filas, 3 000 millones de dictGet
--  Aquí ningún índice puede ayudar: queremos TODAS las filas. Es un escaneo
--  completo, y su velocidad depende del número de núcleos que trabajan en él.
SELECT
    dictGet('ref.dict_municipio', 'codigo_provincia', dictGet('ref.dict_contador', 'codigo_ine', id_contador)) AS codigo_provincia,
    dictGet('ref.dict_provincia', 'nombre', codigo_provincia) AS provincia,
    round(sum(valor_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.curva_carga_xl
GROUP BY codigo_provincia
ORDER BY gwh DESC
LIMIT 10;
-- Medido: 5,72 s · 1,488 mil M filas leídas (16,6 GB) · 382,6 MB de memoria
-- Qué observar: Madrid (138 GWh) y Barcelona (107 GWh) en cabeza, luego Valencia,
-- Alicante y Sevilla. El parque simulado se reparte según el padrón: sigue la población.


-- OPTIMIZACIÓN A · Repartir el escaneo entre las 3 réplicas (parallel replicas)
--  Por defecto, una consulta se ejecuta en la réplica que la recibe. Con
--  enable_parallel_replicas = 1, la tabla se trocea y cada réplica
--  procesa una parte. Es la separación almacenamiento/cómputo:
--  todas las réplicas leen los mismos datos del almacenamiento de objetos, basta con añadir
--  cómputo para ir más rápido.
SELECT
    dictGet('ref.dict_municipio', 'codigo_provincia', dictGet('ref.dict_contador', 'codigo_ine', id_contador)) AS codigo_provincia,
    dictGet('ref.dict_provincia', 'nombre', codigo_provincia) AS provincia,
    round(sum(valor_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.curva_carga_xl
GROUP BY codigo_provincia
ORDER BY gwh DESC
LIMIT 10
SETTINGS enable_parallel_replicas = 1;
-- Medido: 3,12 s · 1,488 mil M filas leídas (16,6 GB) · 199,9 MB de memoria
-- Mejora: 5,72 s → 3,12 s (×1,8) con 3 réplicas, sin cambiar una línea de SQL
-- Qué observar: mismo resultado, mismo número de filas leídas, duración casi dividida
-- por dos (repartir el trabajo y fusionar los resultados tiene un coste). La mejora es
-- mayor en las consultas que calculan mucho por fila (aquí los dictGet).


-- OPTIMIZACIÓN B · La PROJECTION de agregación (declarada al crear la tabla)
--  El optimizador decide solo leer la proyección cuando responde a
--  la pregunta: la consulta no cambia. Para medir la diferencia, primero la
--  desactivamos con optimize_use_projections = 0.
--  La punta nacional del mes, SIN la proyección:
SELECT toTimeZone(ts, 'Europe/Madrid') AS instante, round(sum(valor_w) / 1e6) AS mw
FROM silver.curva_carga_xl
GROUP BY ts
ORDER BY mw DESC
LIMIT 5
SETTINGS optimize_use_projections = 0;
-- Medido: 2,54 s · 1,488 mil M filas leídas (11,1 GB) · 264 MB de memoria

--  … y CON ella (el ajuste por defecto):
SELECT toTimeZone(ts, 'Europe/Madrid') AS instante, round(sum(valor_w) / 1e6) AS mw
FROM silver.curva_carga_xl
GROUP BY ts
ORDER BY mw DESC
LIMIT 5;
-- Medido: 34 ms · 22 290 filas leídas (435,4 KB)
-- Mejora: 2,54 s → 34 ms (×75), y 67 000 veces menos filas leídas
-- Qué observar: mismo resultado (punta de 1 947 MW el 30 de octubre a las 19h), unas
-- 22 000 filas leídas en lugar de 1 500 millones.
-- La proyección ya contiene una fila por media hora (y por part).

--  Extra: el consumo de España día a día aprovecha la misma proyección,
--  porque toDate(ts) se calcula a partir de ts, que está en la proyección.
SELECT toDate(ts - 1, 'Europe/Madrid') AS dia, round(sum(valor_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.curva_carga_xl
GROUP BY dia
ORDER BY dia;
-- Medido: 6 ms · 22 290 filas leídas (435,4 KB), frente a más de 1 s y 1,488 mil M de filas sin proyección

--  En una tabla ya cargada, la proyección se añadiría así:
--    ALTER TABLE silver.curva_carga_xl ADD PROJECTION p_curva_nacional (SELECT ts, sum(valor_w), count() GROUP BY ts);
--    ALTER TABLE silver.curva_carga_xl MATERIALIZE PROJECTION p_curva_nacional SETTINGS mutations_sync = 1;
--  MATERIALIZE reescribe todas las parts existentes: con 1 500 millones de filas hay que
--  contar una veintena de segundos (medido: 22 s), mejor fuera de las horas punta.


-- OPTIMIZACIÓN C · El ÍNDICE DE SALTO minmax sobre el valor
--  "¿Qué puntos superan 100 kW?": solo los grandes sitios industriales (C2)
--  llegan a ese nivel. Son ~0,2 % del parque, así que la mayoría de los gránulos
--  tienen un máx por debajo de 100 kW y se pueden saltar.
--  SIN el índice (use_skip_indexes = 0):
SELECT count() AS puntos_sobre_100kw, uniqExact(id_contador) AS contador
FROM silver.curva_carga_xl
WHERE valor_w > 100000
SETTINGS use_skip_indexes = 0;
-- Medido: 736 ms · 1,488 mil M filas leídas (5,7 GB) · 232,2 MB de memoria

--  CON el índice:
SELECT count() AS puntos_sobre_100kw, uniqExact(id_contador) AS contador
FROM silver.curva_carga_xl
WHERE valor_w > 100000;
-- Medido: 121 ms · 22,6 M filas leídas (246,8 MB) · 99,2 MB de memoria
-- Mejora: 736 ms → 121 ms (×6,1), 1,5 % de la tabla leída

EXPLAIN indexes = 1
SELECT count() FROM silver.curva_carga_xl WHERE valor_w > 100000;
-- Qué observar: bajo "Skip", el número de gránulos conservados, una pequeña fracción de la tabla.
-- Un índice de salto solo ayuda si los valores buscados están agrupados en pocos
-- gránulos. En una columna donde todos los valores se mezclan, no salta nada.
--  En una tabla ya cargada: ALTER TABLE … ADD INDEX, y luego MATERIALIZE INDEX.
--  Atención: MATERIALIZE INDEX sobre 1 500 millones de filas supera con creces 60 s (medido: 109 s)
--  (la consola abandona). Por eso declaramos el índice en el CREATE TABLE.


-- OPTIMIZACIÓN D · La caché de consultas (dashboards que se refrescan en bucle)
--  El resultado de una consulta se guarda en memoria durante query_cache_ttl segundos.
--  La misma consulta, con el mismo texto y los mismos ajustes, se sirve desde
--  la caché sin releer nada.
--  Atención: dictGet se considera "no determinista" (el diccionario puede
--  recargarse): sin query_cache_nondeterministic_function_handling, ClickHouse
--  se niega a cachear (error 704). Aquí los referenciales cambian como mucho cada
--  hora, un TTL de 5 min no supone ningún riesgo.
--  Primero vaciamos la caché, para que la demo parta de cero aunque vuelvas a lanzar
--  el fichero (la caché sobrevive a la recreación de las tablas, ver más abajo).
SYSTEM DROP QUERY CACHE;

SELECT
    dictGet('ref.dict_municipio', 'codigo_provincia', dictGet('ref.dict_contador', 'codigo_ine', id_contador)) AS codigo_provincia,
    dictGet('ref.dict_provincia', 'nombre', codigo_provincia) AS provincia,
    round(sum(valor_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.curva_carga_xl
GROUP BY codigo_provincia
ORDER BY gwh DESC
LIMIT 10
SETTINGS use_query_cache = 1, query_cache_ttl = 300,
         query_cache_nondeterministic_function_handling = 'save';
-- Medido: 5,25 s · 1,488 mil M filas leídas (16,6 GB) · 381 MB de memoria

--  … vuelve a lanzar exactamente la misma consulta:
SELECT
    dictGet('ref.dict_municipio', 'codigo_provincia', dictGet('ref.dict_contador', 'codigo_ine', id_contador)) AS codigo_provincia,
    dictGet('ref.dict_provincia', 'nombre', codigo_provincia) AS provincia,
    round(sum(valor_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.curva_carga_xl
GROUP BY codigo_provincia
ORDER BY gwh DESC
LIMIT 10
SETTINGS use_query_cache = 1, query_cache_ttl = 300,
         query_cache_nondeterministic_function_handling = 'save';
-- Medido: 1 ms (resultado servido por la caché, ningún dato releído)
-- Mejora: 5,25 s → 1 ms
-- Qué observar: la 2.ª ejecución responde en un milisegundo y no lee ninguna fila.
-- Atención: la caché es propia de cada réplica. Si la consola te manda a
-- otra réplica, la 1.ª llamada recalcula allí: lánzala una vez más.
-- Atención: la caché NO se vacía cuando cambia la tabla, solo cuenta el TTL.
-- Se reserva para los paneles en los que unos minutos de retraso son aceptables.


-- PARA IR MÁS LEJOS · PREWHERE es automático
--  ClickHouse lee primero la columna del filtro más selectivo (id_contador), y luego
--  solo las demás columnas de las filas retenidas. EXPLAIN lo muestra.
EXPLAIN actions = 1
SELECT sum(valor_w) FROM silver.curva_carga_xl WHERE id_contador = sim_id_contador(42) AND valor_w > 1000;
