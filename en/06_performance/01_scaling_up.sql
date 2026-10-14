-- =====================================================================
--  MODULE 6 · Scaling up: 1 million meters, 1.5 billion points
-- =====================================================================
--  So far: 20,000 meters. Now we move to the simulator's full fleet:
--  1,000,000 meters × 31 days × 48 half-hours = 1,488,000,000 points.
--  We write straight into silver (skipping the JSON) to measure ClickHouse's
--  raw write and read speed.
--
--  The console gives up on a statement after ~60 s. So we insert in
--  8 batches of 125,000 meters (186 M points each), one statement per batch.
-- =====================================================================


-- STEP 1 · The table (same model as silver.load_curve)
--  We declare two accelerators right away, measured in the next file:
--    · a PROJECTION: a pre-aggregated copy per timestamp, which ClickHouse
--      keeps up to date on every INSERT, like an index that already holds the sums;
--    · a minmax SKIP INDEX: for each granule (8,192 rows), the min and the
--      max of value_w. A "value_w > X" query skips the granules whose max
--      is below X without reading them (rule query-index-skipping-indices).
--  Declaring them BEFORE loading costs a little time on insert.
--  Adding them AFTER (ALTER … MATERIALIZE) rewrites the whole table: see 02.
CREATE OR REPLACE TABLE silver.load_curve_xl
(
    meter_id    UInt64,
    quantity  LowCardinality(String),
    ts        DateTime('UTC') CODEC(Delta, ZSTD(1)),
    value_w  UInt32          CODEC(T64, ZSTD(1)),
    INDEX idx_value value_w TYPE minmax GRANULARITY 1,
    PROJECTION p_national_curve (SELECT ts, sum(value_w), count() GROUP BY ts)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (quantity, meter_id, ts);   -- lowest to highest cardinality: 2 values, then the meter, then time


-- STEP 2 · The generator, stored in a parameterized view
--  Point no. k: meter no. k / 1488, half-hour no. k % 1488.
--  numbers_mt is the parallel version of numbers(): blocks of numbers
--  are produced and transformed on all the replica's cores at the same time.
CREATE OR REPLACE VIEW simulator.xl_points AS
WITH
    sim_meter_id(intDiv(number, 1488))                                                        AS id,
    toDateTime('2026-10-01 00:30:00', 'Europe/London') + toIntervalSecond(1800 * (number % 1488)) AS t,
    dictGet('simulator.dict_meter', ('profile', 'power_kva'), id)                         AS a
SELECT
    id                              AS meter_id,
    'CONS'                          AS quantity,
    t                               AS ts,
    sim_cons_w(id, a.1, a.2, t)    AS value_w
FROM numbers_mt({start:UInt64} * 1488, {n:UInt64} * 1488);


-- STEP 3 · 1.5 billion points, in 8 INSERT … SELECT
--  Large batches = few parts = few merges (rule insert-batch-size).
--  max_insert_threads = 8: 8 parallel write streams on the replica.
--  An INSERT runs on ONE replica: its speed depends on that replica's cores.
INSERT INTO silver.load_curve_xl SELECT * FROM simulator.xl_points(start = 0,      n = 125000) SETTINGS max_insert_threads = 8;
-- Measured: 8.4 s · 186 M rows read (1.4 GB) · 186 M rows written · 1.2 GB memory
INSERT INTO silver.load_curve_xl SELECT * FROM simulator.xl_points(start = 125000, n = 125000) SETTINGS max_insert_threads = 8;
-- Measured: 8.45 s · 186 M rows read (1.4 GB) · 186 M rows written · 1.2 GB memory
INSERT INTO silver.load_curve_xl SELECT * FROM simulator.xl_points(start = 250000, n = 125000) SETTINGS max_insert_threads = 8;
-- Measured: 8.33 s · 186 M rows read (1.4 GB) · 186 M rows written · 1.1 GB memory
INSERT INTO silver.load_curve_xl SELECT * FROM simulator.xl_points(start = 375000, n = 125000) SETTINGS max_insert_threads = 8;
-- Measured: 8.33 s · 186 M rows read (1.4 GB) · 186 M rows written · 1.1 GB memory
INSERT INTO silver.load_curve_xl SELECT * FROM simulator.xl_points(start = 500000, n = 125000) SETTINGS max_insert_threads = 8;
-- Measured: 8.4 s · 186 M rows read (1.4 GB) · 186 M rows written · 1.1 GB memory
INSERT INTO silver.load_curve_xl SELECT * FROM simulator.xl_points(start = 625000, n = 125000) SETTINGS max_insert_threads = 8;
-- Measured: 8.34 s · 186 M rows read (1.4 GB) · 186 M rows written · 1.1 GB memory
INSERT INTO silver.load_curve_xl SELECT * FROM simulator.xl_points(start = 750000, n = 125000) SETTINGS max_insert_threads = 8;
-- Measured: 8.11 s · 186 M rows read (1.4 GB) · 186 M rows written · 1.1 GB memory
INSERT INTO silver.load_curve_xl SELECT * FROM simulator.xl_points(start = 875000, n = 125000) SETTINGS max_insert_threads = 8;
-- Measured: 8.21 s · 186 M rows read (1.4 GB) · 186 M rows written · 1.2 GB memory
-- What to look for: at the bottom of the console, the rows/s of each batch. Every point is
-- computed (dictGet + sim_cons_w), sorted by the ORDER BY, compressed, then written to object storage.


-- STEP 4 · How much it weighs
SELECT
    formatReadableQuantity(sum(rows))                                AS points,
    formatReadableSize(sum(data_uncompressed_bytes))                 AS raw,
    formatReadableSize(sum(data_compressed_bytes))                   AS on_disk,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio,
    round(sum(data_compressed_bytes) / sum(rows), 2)                 AS bytes_per_point
FROM system.parts
WHERE database = 'silver' AND table = 'load_curve_xl' AND active
SETTINGS select_sequential_consistency = 1;
-- What to look for: about 1.4 bytes per point. A "raw" point (8 + 1 + 4 + 4 bytes)
-- weighs 17: compression divides it by more than 10.

--  Column by column: here the parts are over 1 GB, so they are "wide"
--  (one column = one file) and system.parts_columns gives their size.
SELECT
    column,
    formatReadableSize(sum(column_data_compressed_bytes))   AS on_disk,
    round(sum(column_data_uncompressed_bytes) / sum(column_data_compressed_bytes), 1) AS ratio
FROM system.parts_columns
WHERE database = 'silver' AND table = 'load_curve_xl' AND active
  AND NOT startsWith(column, '_')          -- internal technical columns
GROUP BY column
ORDER BY sum(column_data_compressed_bytes) DESC;
-- What to look for: ts (Delta) and quantity (LowCardinality) cost almost nothing,
-- and neither does meter_id, because rows are sorted by meter. The bulk is the measurement,
-- which carries the real noise of consumption and compresses poorly.

--  At the scale of a large territory (3.5 M meters × 365 days × 48 points ≈ 61 billion):
SELECT formatReadableSize(61e9 * (
    SELECT sum(data_compressed_bytes) / sum(rows) FROM system.parts
    WHERE database = 'silver' AND table = 'load_curve_xl' AND active)) AS one_year_of_curves_estimate;
-- What to look for: under 100 GB for a full year of curves for 3.5 M meters.


-- CHECKPOINT
--  1,488,000,000 points expected (8 batches of 186,000,000).
SELECT
    if((SELECT count() FROM silver.load_curve_xl) = 1488000000, 'OK', 'FAIL') AS xl_points
SETTINGS select_sequential_consistency = 1;
