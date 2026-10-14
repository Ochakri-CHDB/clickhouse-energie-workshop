-- =====================================================================
--  MÓDULO 6 · Cambio de escala: 1 millón de contadores, 1 500 millones de puntos
-- =====================================================================
--  Hasta ahora: 20 000 contadores. Pasamos al parque completo del simulador:
--  1 000 000 de contadores × 31 días × 48 medias horas = 1 488 000 000 puntos.
--  Escribimos directamente en silver (sin pasar por el JSON) para medir
--  la velocidad bruta de escritura y de lectura de ClickHouse.
--
--  La consola abandona una instrucción pasados ~60 s. Por eso insertamos
--  en 8 lotes de 125 000 contadores (186 M de puntos cada uno), una instrucción por lote.
-- =====================================================================


-- PASO 1 · La tabla (mismo modelo que silver.curva_carga)
--  Declaramos ya dos aceleradores, que se miden en el fichero siguiente:
--    · una PROJECTION: una copia preagregada por marca de tiempo, que ClickHouse
--      mantiene al día en cada INSERT, como un índice que ya contuviera las sumas;
--    · un ÍNDICE DE SALTO minmax: para cada gránulo (8 192 filas), el mín y el
--      máx de valor_w. Una consulta "valor_w > X" se salta los gránulos cuyo máx
--      es inferior a X sin leerlos (regla query-index-skipping-indices).
--  Declararlos ANTES de cargar cuesta un poco de tiempo en la inserción.
--  Añadirlos DESPUÉS (ALTER … MATERIALIZE) reescribe toda la tabla: ver 02.
CREATE OR REPLACE TABLE silver.curva_carga_xl
(
    id_contador    UInt64,
    magnitud  LowCardinality(String),
    ts        DateTime('UTC') CODEC(Delta, ZSTD(1)),
    valor_w  UInt32          CODEC(T64, ZSTD(1)),
    INDEX idx_valor valor_w TYPE minmax GRANULARITY 1,
    PROJECTION p_curva_nacional (SELECT ts, sum(valor_w), count() GROUP BY ts)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (magnitud, id_contador, ts);   -- de menor a mayor cardinalidad: 2 valores, luego el contador, luego el tiempo


-- PASO 2 · El generador, guardado en una vista parametrizada
--  Punto n.º k: contador n.º k / 1488, media hora n.º k % 1488.
--  numbers_mt es la versión paralela de numbers(): los bloques de números
--  se producen y transforman en todos los núcleos de la réplica a la vez.
CREATE OR REPLACE VIEW simulador.puntos_xl AS
WITH
    sim_id_contador(intDiv(number, 1488))                                                        AS id,
    toDateTime('2026-10-01 00:30:00', 'Europe/Madrid') + toIntervalSecond(1800 * (number % 1488)) AS t,
    dictGet('simulador.dict_contador', ('perfil', 'potencia_kva'), id)                         AS a
SELECT
    id                              AS id_contador,
    'CONS'                          AS magnitud,
    t                               AS ts,
    sim_consumo_w(id, a.1, a.2, t)    AS valor_w
FROM numbers_mt({inicio:UInt64} * 1488, {n:UInt64} * 1488);


-- PASO 3 · 1 500 millones de puntos, en 8 INSERT … SELECT
--  Lotes grandes = pocas parts = pocos merges (regla insert-batch-size).
--  max_insert_threads = 8: 8 flujos de escritura en paralelo en la réplica.
--  Un INSERT se ejecuta en UNA réplica: su velocidad depende de los núcleos de esa réplica.
INSERT INTO silver.curva_carga_xl SELECT * FROM simulador.puntos_xl(inicio = 0,      n = 125000) SETTINGS max_insert_threads = 8;
-- Medido: 8 s · 186 M filas leídas (1,4 GB) · 186 M filas escritas · 1,1 GB de memoria
INSERT INTO silver.curva_carga_xl SELECT * FROM simulador.puntos_xl(inicio = 125000, n = 125000) SETTINGS max_insert_threads = 8;
-- Medido: 8,15 s · 186 M filas leídas (1,4 GB) · 186 M filas escritas · 1,1 GB de memoria
INSERT INTO silver.curva_carga_xl SELECT * FROM simulador.puntos_xl(inicio = 250000, n = 125000) SETTINGS max_insert_threads = 8;
-- Medido: 8,4 s · 186 M filas leídas (1,4 GB) · 186 M filas escritas · 1,1 GB de memoria
INSERT INTO silver.curva_carga_xl SELECT * FROM simulador.puntos_xl(inicio = 375000, n = 125000) SETTINGS max_insert_threads = 8;
-- Medido: 8,03 s · 186 M filas leídas (1,4 GB) · 186 M filas escritas · 1,1 GB de memoria
INSERT INTO silver.curva_carga_xl SELECT * FROM simulador.puntos_xl(inicio = 500000, n = 125000) SETTINGS max_insert_threads = 8;
-- Medido: 7,74 s · 186 M filas leídas (1,4 GB) · 186 M filas escritas · 1,1 GB de memoria
INSERT INTO silver.curva_carga_xl SELECT * FROM simulador.puntos_xl(inicio = 625000, n = 125000) SETTINGS max_insert_threads = 8;
-- Medido: 8,02 s · 186 M filas leídas (1,4 GB) · 186 M filas escritas · 1,1 GB de memoria
INSERT INTO silver.curva_carga_xl SELECT * FROM simulador.puntos_xl(inicio = 750000, n = 125000) SETTINGS max_insert_threads = 8;
-- Medido: 7,86 s · 186 M filas leídas (1,4 GB) · 186 M filas escritas · 1,1 GB de memoria
INSERT INTO silver.curva_carga_xl SELECT * FROM simulador.puntos_xl(inicio = 875000, n = 125000) SETTINGS max_insert_threads = 8;
-- Medido: 7,78 s · 186 M filas leídas (1,4 GB) · 186 M filas escritas · 1,2 GB de memoria
-- Qué observar: abajo en la consola, las filas/s de cada lote. Cada punto se calcula
-- (dictGet + sim_consumo_w), se ordena según el ORDER BY, se comprime y se escribe en el almacenamiento de objetos.


-- PASO 4 · Lo que ocupa
SELECT
    formatReadableQuantity(sum(rows))                                AS puntos,
    formatReadableSize(sum(data_uncompressed_bytes))                 AS bruto,
    formatReadableSize(sum(data_compressed_bytes))                   AS en_disco,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio,
    round(sum(data_compressed_bytes) / sum(rows), 2)                 AS bytes_por_punto
FROM system.parts
WHERE database = 'silver' AND table = 'curva_carga_xl' AND active
SETTINGS select_sequential_consistency = 1;
-- Qué observar: alrededor de 1,4 bytes por punto. Un punto "en bruto" (8 + 1 + 4 + 4 bytes)
-- ocupa 17: la compresión divide por más de 10.

--  Columna a columna: aquí las parts superan 1 GB, son "wide"
--  (una columna = un fichero) y system.parts_columns da su tamaño.
SELECT
    column,
    formatReadableSize(sum(column_data_compressed_bytes))   AS en_disco,
    round(sum(column_data_uncompressed_bytes) / sum(column_data_compressed_bytes), 1) AS ratio
FROM system.parts_columns
WHERE database = 'silver' AND table = 'curva_carga_xl' AND active
  AND NOT startsWith(column, '_')          -- columnas técnicas internas
GROUP BY column
ORDER BY sum(column_data_compressed_bytes) DESC;
-- Qué observar: ts (Delta) y magnitud (LowCardinality) casi no cuestan nada,
-- id_contador tampoco, porque las filas están ordenadas por contador. Lo gordo es la medida,
-- que contiene el ruido real del consumo y se comprime poco.

--  A la escala de un gran territorio (3,5 M de contadores × 365 días × 48 puntos ≈ 61 mil millones):
SELECT formatReadableSize(61e9 * (
    SELECT sum(data_compressed_bytes) / sum(rows) FROM system.parts
    WHERE database = 'silver' AND table = 'curva_carga_xl' AND active)) AS estimacion_un_ano_curvas;
-- Qué observar: menos de 100 GB para un año completo de curvas de 3,5 M de contadores.


-- CHECKPOINT
--  1 488 000 000 puntos esperados (8 lotes de 186 000 000).
SELECT
    if((SELECT count() FROM silver.curva_carga_xl) = 1488000000, 'OK', 'ERROR') AS puntos_xl
SETTINGS select_sequential_consistency = 1;
