-- =====================================================================
--  MÓDULO 5 · Gold (1/4): el seguimiento de la recogida, en tiempo real
-- =====================================================================
--  bronze ──MV──► silver ──MV──► gold      (MV en CASCADA)
--  Contamos, para cada contador y cada día, los puntos recibidos y los
--  recibidos ANTES de las 9h. Agregación al insertar: AggregatingMergeTree.
--  Gold recibe agregados ya preparados: el KPI se lee en una tabla pequeña
--  en lugar de volver a contar millones de puntos (regla query-mv-incremental).
-- =====================================================================


-- PASO 1 · Una tabla de agregados: guarda ESTADOS, no valores
--  Un estado es un cálculo "en curso" (por ejemplo, el conjunto de marcas de tiempo vistas).
--  Dos estados se fusionan sin perder nada: es lo que hacen los merges.
--  SimpleAggregateFunction basta para min y max, que se fusionan de forma trivial.
CREATE OR REPLACE TABLE gold.recogida_contador_dia
(
    dia               Date,
    id_contador             UInt64,
    puntos_recibidos       AggregateFunction(uniqExact, DateTime('UTC')),
    puntos_antes_9h    AggregateFunction(uniqExactIf, DateTime('UTC'), UInt8),
    primera_llegada   SimpleAggregateFunction(min, DateTime64(3, 'UTC')),
    ultima_llegada   SimpleAggregateFunction(max, DateTime64(3, 'UTC'))
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(dia)
ORDER BY (dia, id_contador);


-- PASO 2 · La MV conectada a silver (la dispara la MV bronze → silver)
--  uniqExact es IDEMPOTENTE: un fichero reenviado no cuenta dos veces.
--  El sufijo -State produce el estado en lugar del resultado final.
CREATE OR REPLACE MATERIALIZED VIEW gold.mv_recogida TO gold.recogida_contador_dia AS
SELECT
    dia,
    id_contador,
    uniqExactState(ts)                                                                  AS puntos_recibidos,
    uniqExactIfState(ts, toUInt8(version < toDateTime(dia + 1, 'Europe/Paris') + INTERVAL 9 HOUR)) AS puntos_antes_9h,
    min(version)                                                                        AS primera_llegada,
    max(version)                                                                        AS ultima_llegada
FROM silver.curva_carga
WHERE magnitud = 'CONS'
GROUP BY dia, id_contador;


-- PASO 3 · Backfill desde silver (la MV solo ve el futuro, recuerda)
INSERT INTO gold.recogida_contador_dia
SELECT
    dia, id_contador,
    uniqExactState(ts),
    uniqExactIfState(ts, toUInt8(version < toDateTime(dia + 1, 'Europe/Paris') + INTERVAL 9 HOUR)),
    min(version), max(version)
FROM silver.curva_carga
WHERE magnitud = 'CONS'
GROUP BY dia, id_contador;
-- Medido: 5,22 s · 29,8 M filas leídas (653,8 MB) · 618 163 filas escritas · 3,2 GB de memoria


-- PASO 4 · Leer estados: el sufijo -Merge
--  uniqExactMerge fusiona los estados de todas las parts y devuelve el número final.
--  Siempre con un GROUP BY: puede haber varias filas para un mismo contador-día.
SELECT
    dia,
    uniqExactMerge(puntos_recibidos)     AS puntos,
    uniqExactIfMerge(puntos_antes_9h) AS puntos_antes_9h,
    min(primera_llegada)            AS primera_llegada
FROM gold.recogida_contador_dia
WHERE id_contador = sim_id_contador(42)
GROUP BY dia
ORDER BY dia
LIMIT 10;
-- Medido: 58 ms · 253 952 filas leídas (62,5 MB) · 241,6 MB de memoria


-- PASO 5 · El experimento del duplicado: una SUMA en una MV, ¿es segura?
--  Creamos una MV que suma la energía por día y después reenviamos un fichero.
CREATE OR REPLACE TABLE gold.energia_ingenua
(
    dia        Date,
    energia_kwh SimpleAggregateFunction(sum, Float64)
)
ENGINE = AggregatingMergeTree
ORDER BY dia;

CREATE OR REPLACE MATERIALIZED VIEW gold.mv_energia_ingenua TO gold.energia_ingenua AS
SELECT dia, sum(valor_w * paso_min / 60 / 1000) AS energia_kwh
FROM silver.curva_carga
WHERE magnitud = 'CONS'
GROUP BY dia;

INSERT INTO gold.energia_ingenua
SELECT dia, sum(valor_w * paso_min / 60 / 1000) FROM silver.curva_carga FINAL WHERE magnitud = 'CONS' GROUP BY dia;
-- Medido: 298 ms · 30,4 M filas leídas (810,1 MB) · 31 filas escritas · 363,7 MB de memoria

--  Reenviamos un fichero ya recibido (el lote 3 del 20 de octubre)
INSERT INTO bronze.flujos_brutos
SELECT replaceOne(file_name, '_488903_', '_488903_REENVIO_'), codigo_flujo, ingested_at + INTERVAL 1 DAY, payload
FROM bronze.flujos_brutos
WHERE file_name LIKE 'DSO_CURVA_30MIN_PUB_100383_488903_2%';
-- Medido: 205 ms · 102 106 filas leídas (20,1 MB) · 51 149 filas escritas · 96,8 MB de memoria

SELECT
    (SELECT round(sum(energia_kwh)) FROM gold.energia_ingenua WHERE dia = '2026-10-20')                         AS suma_por_mv,
    (SELECT round(sum(valor_w * paso_min / 60 / 1000)) FROM silver.curva_carga FINAL WHERE magnitud = 'CONS' AND dia = '2026-10-20') AS suma_real,
    (SELECT sum(n) FROM (SELECT uniqExactMerge(puntos_recibidos) AS n FROM gold.recogida_contador_dia WHERE dia = '2026-10-20' GROUP BY id_contador)) AS puntos_mv_uniq,
    (SELECT count() FROM silver.curva_carga FINAL WHERE magnitud = 'CONS' AND dia = '2026-10-20')           AS puntos_reales;
-- Medido: 355 ms · 61,1 M filas leídas (1,5 GB) · 355 MB de memoria
-- Qué observar: la suma se desvía un 6 % aproximadamente (el fichero reenviado se cuenta
--    2 veces), uniqExact sigue siendo correcto.
--    Regla: sum en una MV incremental solo si la fuente nunca tiene duplicados.
--    Si no: vista materializada REFRESCABLE sobre silver FINAL (fichero siguiente).

--  Eliminamos el experimento: ya no sirve.
DROP VIEW gold.mv_energia_ingenua;
DROP TABLE gold.energia_ingenua;
