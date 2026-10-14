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
SELECT toTimeZone(ts, 'Europe/Paris') AS hora, valor_w
FROM silver.curva_carga_xl
WHERE magnitud = 'CONS' AND id_contador = sim_id_contador(123456)   -- las 2 primeras columnas del ORDER BY
ORDER BY ts;
-- Medido: 16 384 filas leídas (272 KB) · de 250 a 265 ms en la primera llamada a una réplica
-- (lectura desde el almacenamiento de objetos), luego de 5 a 55 ms: ha tomado el relevo
-- la caché de disco local de la réplica

--  EXPLAIN indexes = 1 muestra lo que ha descartado el índice, sin ejecutar la consulta.
EXPLAIN indexes = 1
SELECT valor_w FROM silver.curva_carga_xl WHERE magnitud = 'CONS' AND id_contador = sim_id_contador(123456);
-- Qué observar: bajo "PrimaryKey", la línea "Granules". Dos gránulos de 8 192 filas
-- leídos de ~180 000: por eso la consulta es instantánea.


-- CONSULTA 2 · Por departamento: 1 500 millones de filas, 3 000 millones de dictGet
--  Aquí ningún índice puede ayudar: queremos TODAS las filas. Es un escaneo
--  completo, y su velocidad depende del número de núcleos que trabajan en él.
SELECT
    dictGet('ref.dict_municipio', 'codigo_dpto', dictGet('ref.dict_contador', 'codigo_insee', id_contador)) AS dpto,
    dictGet('ref.dict_departamento', 'nombre', dpto) AS departamento,
    round(sum(valor_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.curva_carga_xl
GROUP BY dpto
ORDER BY gwh DESC
LIMIT 10;
-- Medido: 5,77 s · 1,488 mil M filas leídas (16,6 GB) · 388,3 MB de memoria


-- OPTIMIZACIÓN A · Repartir el escaneo entre las 3 réplicas (parallel replicas)
--  Por defecto, una consulta se ejecuta en la réplica que la recibe. Con
--  enable_parallel_replicas = 1, la tabla se trocea y cada réplica
--  procesa una parte. Es la separación almacenamiento/cómputo:
--  todas las réplicas leen los mismos datos del almacenamiento de objetos, basta con añadir
--  cómputo para ir más rápido.
SELECT
    dictGet('ref.dict_municipio', 'codigo_dpto', dictGet('ref.dict_contador', 'codigo_insee', id_contador)) AS dpto,
    dictGet('ref.dict_departamento', 'nombre', dpto) AS departamento,
    round(sum(valor_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.curva_carga_xl
GROUP BY dpto
ORDER BY gwh DESC
LIMIT 10
SETTINGS enable_parallel_replicas = 1;
-- Medido: 2,17 s · 1,488 mil M filas leídas (16,6 GB) · 197,1 MB de memoria
-- Mejora: 5,77 s → 2,17 s (×2,7) con 3 réplicas, sin cambiar una línea de SQL
-- Qué observar: mismo resultado, mismo número de filas leídas, duración dividida por
-- aproximadamente el número de réplicas. La mejora es mayor en las consultas
-- que calculan mucho por fila (aquí los dictGet).


-- OPTIMIZACIÓN B · La PROJECTION de agregación (declarada al crear la tabla)
--  El optimizador decide solo leer la proyección cuando responde a
--  la pregunta: la consulta no cambia. Para medir la diferencia, primero la
--  desactivamos con optimize_use_projections = 0.
--  La punta nacional del mes, SIN la proyección:
SELECT toTimeZone(ts, 'Europe/Paris') AS instante, round(sum(valor_w) / 1e6) AS mw
FROM silver.curva_carga_xl
GROUP BY ts
ORDER BY mw DESC
LIMIT 5
SETTINGS optimize_use_projections = 0;
-- Medido: 1,3 s · 1,488 mil M filas leídas (11,1 GB) · 229,5 MB de memoria

--  … y CON ella (el ajuste por defecto):
SELECT toTimeZone(ts, 'Europe/Paris') AS instante, round(sum(valor_w) / 1e6) AS mw
FROM silver.curva_carga_xl
GROUP BY ts
ORDER BY mw DESC
LIMIT 5;
-- Medido: 33 ms · 17 835 filas leídas (348,3 KB)
-- Mejora: 1,3 s → 33 ms (×39), y 83 000 veces menos filas leídas
-- Qué observar: mismo resultado, unos miles de filas leídas en lugar de 1 500 millones.
-- La proyección ya contiene una fila por media hora (y por part).

--  Extra: el consumo de Francia día a día aprovecha la misma proyección,
--  porque toDate(ts) se calcula a partir de ts, que está en la proyección.
SELECT toDate(ts - 1, 'Europe/Paris') AS dia, round(sum(valor_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.curva_carga_xl
GROUP BY dia
ORDER BY dia;
-- Medido: 7 ms · 17 835 filas leídas (348,3 KB), frente a ~1 s y 1,488 mil M de filas sin proyección

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
-- Medido: 692 ms · 1,488 mil M filas leídas (5,7 GB) · 250 MB de memoria

--  CON el índice:
SELECT count() AS puntos_sobre_100kw, uniqExact(id_contador) AS contador
FROM silver.curva_carga_xl
WHERE valor_w > 100000;
-- Medido: 159 ms · 22,5 M filas leídas (245,6 MB) · 106,5 MB de memoria
-- Mejora: 692 ms → 159 ms (×4,4), 1,5 % de la tabla leída

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
    dictGet('ref.dict_municipio', 'codigo_dpto', dictGet('ref.dict_contador', 'codigo_insee', id_contador)) AS dpto,
    dictGet('ref.dict_departamento', 'nombre', dpto) AS departamento,
    round(sum(valor_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.curva_carga_xl
GROUP BY dpto
ORDER BY gwh DESC
LIMIT 10
SETTINGS use_query_cache = 1, query_cache_ttl = 300,
         query_cache_nondeterministic_function_handling = 'save';
-- Medido: 4,93 s · 1,488 mil M filas leídas (16,6 GB) · 387,7 MB de memoria

--  … vuelve a lanzar exactamente la misma consulta:
SELECT
    dictGet('ref.dict_municipio', 'codigo_dpto', dictGet('ref.dict_contador', 'codigo_insee', id_contador)) AS dpto,
    dictGet('ref.dict_departamento', 'nombre', dpto) AS departamento,
    round(sum(valor_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.curva_carga_xl
GROUP BY dpto
ORDER BY gwh DESC
LIMIT 10
SETTINGS use_query_cache = 1, query_cache_ttl = 300,
         query_cache_nondeterministic_function_handling = 'save';
-- Medido: 1 ms (resultado servido por la caché, ningún dato releído)
-- Mejora: 4,93 s → 1 ms
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
