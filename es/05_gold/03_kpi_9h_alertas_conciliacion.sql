-- =====================================================================
--  MÓDULO 5 · Gold (3/4): completitud a las 9h, alertas, conciliación
-- =====================================================================


-- PASO 1 · KPI "99 % de los datos recibidos a las 9h"
--  Dos lecturas del mismo seguimiento de recogida:
--    · datos_9h_pct: puntos recibidos antes de las 9h / puntos esperados en todo el parque
--      (es el objetivo contractual: 99 %)
--    · contadores_completos_9h_pct: contadores con el día COMPLETO a las 9h, más estricto
--      (basta con que falte un punto para que el contador no cuente)
--  En producción: REFRESH EVERY 1 DAY OFFSET 9 HOUR (todos los días a las 9h).
--  La vista lee gold.recogida_contador_dia (pequeña) y no silver: el cálculo es inmediato.
CREATE OR REPLACE TABLE gold.kpi_completitud_dia
(
    dia                      Date,
    parque_contadores                  UInt32,
    contadores_recibidos                 UInt32,
    puntos_esperados           UInt64,
    puntos_recibidos_9h           UInt64,
    datos_9h_pct       Float64,
    contadores_completos_9h         UInt32,
    contadores_completos_9h_pct  Float64
)
ENGINE = MergeTree
ORDER BY dia;

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_kpi_completitud
REFRESH EVERY 1 DAY OFFSET 9 HOUR
TO gold.kpi_completitud_dia
AS
WITH
    (SELECT uniqExact(id_contador) FROM gold.recogida_contador_dia) AS parque,
    por_contador AS
    (
        SELECT
            dia,
            id_contador,
            uniqExactMerge(puntos_recibidos)                                                                      AS recibidos,
            uniqExactIfMerge(puntos_antes_9h)                                                                 AS antes_9h,
            dateDiff('minute', toDateTime(dia, 'Europe/Paris'), toDateTime(dia + 1, 'Europe/Paris')) / 30   AS esperados
        FROM gold.recogida_contador_dia
        GROUP BY dia, id_contador
    )
SELECT
    dia,
    parque                                                     AS parque_contadores,
    count()                                                  AS contadores_recibidos,
    toUInt64(parque * any(esperados))                           AS puntos_esperados,   -- un contador mudo también cuenta
    sum(antes_9h)                                            AS puntos_recibidos_9h,
    round(100 * puntos_recibidos_9h / puntos_esperados, 2)        AS datos_9h_pct,
    countIf(antes_9h = esperados)                             AS contadores_completos_9h,
    round(100 * contadores_completos_9h / parque, 2)                 AS contadores_completos_9h_pct
FROM por_contador
GROUP BY dia;

SYSTEM REFRESH VIEW gold.rmv_kpi_completitud;
SYSTEM WAIT VIEW gold.rmv_kpi_completitud;
-- Medido: 655 ms

SELECT dia, datos_9h_pct, contadores_completos_9h_pct,
       if(datos_9h_pct >= 99, 'OK', 'bajo el objetivo') AS objetivo_99
FROM gold.kpi_completitud_dia
ORDER BY dia;
-- Medido: 16 ms · 31 filas leídas
-- Qué observar: la mayoría de los días alcanzan el objetivo. Los que quedan por debajo: uno o
--    varios ficheros llegados por la tarde (un lote = 1000 contadores, el 5 % del parque de golpe).

--  ¿Cuáles? Los ficheros CURVA llegados después de las 9h, hora de París
SELECT toDate(ingested_at, 'Europe/Paris') - 1 AS dia, file_name, toTimeZone(ingested_at, 'Europe/Paris') AS llegada
FROM bronze.flujos_brutos
WHERE codigo_flujo = 'CURVA' AND toHour(ingested_at, 'Europe/Paris') >= 9
  AND file_name NOT LIKE '%REENVIO%' AND file_name NOT LIKE '%CORRECCION%'
ORDER BY ingested_at
LIMIT 10;
-- Medido: 6 ms · 116 filas leídas (7,7 KB)


-- PASO 2 · Las alertas de exceso de potencia contratada
--  La potencia de referencia es la VIGENTE el día del exceso:
--  dictGet sobre el diccionario "a fecha" del módulo 4, con el día como 2.ª clave.
CREATE OR REPLACE TABLE gold.alertas_pmax
(
    dia             Date,
    id_contador           UInt64,
    municipio          String,
    codigo_epci        LowCardinality(String),
    segmento          LowCardinality(String),
    kva_contratado     UInt16,
    pmax_va          UInt32,
    exceso_pct  Float64,
    instante_punta     DateTime('Europe/Paris')
)
ENGINE = MergeTree
ORDER BY (dia, id_contador);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_alertas_pmax
REFRESH EVERY 10 MINUTE
TO gold.alertas_pmax
AS
SELECT
    dia,
    id_contador,
    dictGet('ref.dict_municipio', 'nombre', dictGet('ref.dict_contador', 'codigo_insee', id_contador))       AS municipio,
    dictGet('ref.dict_municipio', 'codigo_epci', dictGet('ref.dict_contador', 'codigo_insee', id_contador)) AS codigo_epci,
    dictGet('ref.dict_contador', 'segmento', id_contador)                                               AS segmento,
    dictGet('ref.dict_potencia_asof', 'potencia_kva', id_contador, dia)                        AS kva_contratado,
    pmax_va,
    round(100 * (pmax_va / (kva_contratado * 1000) - 1), 1)                                    AS exceso_pct,
    ts_pmax                                                                                  AS instante_punta
FROM silver.pmax_dia FINAL
WHERE pmax_va > dictGet('ref.dict_potencia_asof', 'potencia_kva', id_contador, dia) * 1000;

SYSTEM REFRESH VIEW gold.rmv_alertas_pmax;
SYSTEM WAIT VIEW gold.rmv_alertas_pmax;
-- Medido: 495 ms

SELECT dia, count() AS n_alertas, round(avg(exceso_pct), 1) AS exceso_medio_pct
FROM gold.alertas_pmax
GROUP BY dia
ORDER BY dia;
-- Medido: 39 ms · 257 filas leídas (2,5 KB)

--  Por segmento: en C5, el interruptor del contador corta antes de que haya exceso.
--  Por eso las alertas solo afectan a C4 y C2 (excesos facturados).
SELECT segmento, count() AS alertas, uniqExact(id_contador) AS contador, round(avg(exceso_pct), 1) AS exceso_medio_pct
FROM gold.alertas_pmax
GROUP BY segmento;
-- Medido: 2 ms · 257 filas leídas (4,3 KB)

--  Los contadores que aumentaron su potencia en octubre: ¿menos alertas después?
SELECT
    countIf(a.dia <= h.valid_to)  AS alertas_antes_cambio,
    countIf(a.dia >  h.valid_to)  AS alertas_despues_cambio,
    uniqExact(a.id_contador)            AS contador
FROM gold.alertas_pmax AS a
INNER JOIN (SELECT id_contador, valid_to FROM ref.historial_contador WHERE valid_to BETWEEN '2026-10-01' AND '2026-10-30') AS h
    ON h.id_contador = a.id_contador;
-- Medido: 12 ms · 1 M filas leídas (9,8 MB) · 65,8 MB de memoria
-- Qué observar: el cliente se pasaba, aumentó su potencia y las alertas caen.
--    Es dict_potencia_asof lo que hace que sea correcto: se compara con la potencia DEL DÍA.


-- PASO 3 · Conciliación: energía diaria (índices) vs integral de la curva CURVA
--  Un desvío revela una curva incompleta: sabemos DÓNDE y CUÁNTO falta.
--  La energía diaria viene de los índices del contador: está completa aunque la curva tenga huecos.
--  Una vista normal (CREATE VIEW) no almacena nada: la consulta se ejecuta en cada lectura.
CREATE OR REPLACE VIEW gold.v_conciliacion AS
SELECT
    e.dia,
    e.id_contador,
    e.energia_wh / 1000                                          AS energia_dia_kwh,
    c.energia_curva_kwh,
    c.n_puntos,
    round(100 * (1 - c.energia_curva_kwh / (e.energia_wh / 1000)), 2) AS desvio_pct
FROM silver.energia_dia AS e FINAL
INNER JOIN
(
    SELECT dia, id_contador, sum(valor_w * paso_min / 60) / 1000 AS energia_curva_kwh, count() AS n_puntos
    FROM silver.curva_carga FINAL
    WHERE magnitud = 'CONS'
    GROUP BY dia, id_contador
) AS c ON c.dia = e.dia AND c.id_contador = e.id_contador
WHERE e.magnitud = 'CONS';

SELECT
    multiIf(abs(desvio_pct) < 0.5, '1. < 0,5% (normal)', abs(desvio_pct) < 3, '2. 0,5 a 3% (1 punto faltante)', '3. > 3% (varios huecos)') AS clase_desvio,
    count()                    AS contador_dias,
    round(avg(n_puntos), 1)   AS puntos_medios
FROM gold.v_conciliacion
GROUP BY clase_desvio
ORDER BY clase_desvio;
-- Medido: 235 ms · 31,2 M filas leídas (825,8 MB) · 446,2 MB de memoria
-- Qué observar: más del 97 % de los contador-días cuadran con menos de un 0,5 %. Al resto
-- le faltan 1 o 2 puntos (47 o 46 puntos en lugar de 48): hay que completar la curva.


-- CHECKPOINT MÓDULO 5
--  31 días de KPI, y al menos una alerta y una fila en cada tabla gold.
SELECT
    if((SELECT count() FROM gold.recogida_contador_dia) > 500000, 'OK', 'ERROR')          AS recogida,
    if((SELECT count() FROM gold.energia_municipio_dia) > 0, 'OK', 'ERROR')            AS energia,
    if((SELECT count() FROM gold.resumen_entidad_dia) > 0, 'OK', 'ERROR')      AS resumen,
    if((SELECT count() FROM gold.kpi_completitud_dia) = 31, 'OK', 'ERROR')            AS kpi_9h,
    if((SELECT count() FROM gold.alertas_pmax) > 0, 'OK', 'ERROR')                    AS alertas
SETTINGS select_sequential_consistency = 1;   -- leer la última versión, sea cual sea la réplica
