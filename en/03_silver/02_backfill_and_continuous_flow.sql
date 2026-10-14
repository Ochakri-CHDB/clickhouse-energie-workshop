-- =====================================================================
--  MODULE 3 · Backfilling the history, then the continuous flow
-- =====================================================================


-- STEP 1 · Backfill: replay bronze through the MVs, with one INSERT … SELECT
--  We run the MV query ourselves, over the whole bronze history.
--  Watch out: do this AFTER creating the MV, otherwise files arriving in
--  between would be lost. Here bronze receives nothing during the operation.
INSERT INTO silver.load_curve
SELECT
    toUInt64(m.meterId), g.businessQuantity, parseDateTimeBestEffort(p.d, 'UTC'), toUInt32(p.v),
    toUInt8(extract(m.step, '\\d+')), m.stage, ingested_at
FROM bronze.raw_flows
ARRAY JOIN JSONExtract(payload, 'measurements',
    'Array(Tuple(meterId String, stage String, step String, quantity Array(Tuple(businessQuantity String, points Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.quantity AS g
ARRAY JOIN g.points   AS p
WHERE flow_code = 'CURVE' AND toUInt32OrNull(p.v) IS NOT NULL
SETTINGS max_block_size = 4;
-- Measured: 17.6 s · 600 files read (1.3 GB of JSON) · 29.9 M rows written · 1.7 GB of memory
-- What to look for: ~30 million points extracted from the JSON. Check the rows/s speed
-- at the bottom of the console: all the JSON parsing happens inside the database.

INSERT INTO silver.rejects
SELECT ingested_at, file_name, flow_code, m.meterId, p.d, p.v, 'non-numeric value'
FROM bronze.raw_flows
ARRAY JOIN JSONExtract(payload, 'measurements', 'Array(Tuple(meterId String, quantity Array(Tuple(points Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.quantity AS g
ARRAY JOIN g.points   AS p
WHERE flow_code = 'CURVE' AND toUInt32OrNull(p.v) IS NULL
SETTINGS max_block_size = 4;
-- Measured: 2.66 s · 600 files read (1.3 GB of JSON) · 8,758 rows written · 1.1 GB of memory

INSERT INTO silver.daily_energy
SELECT toUInt64(m.meterId), g.businessQuantity, toDate(p.d), toDecimal64(p.v, 2), m.stage, ingested_at
FROM bronze.raw_flows
ARRAY JOIN JSONExtract(payload, 'measurements', 'Array(Tuple(meterId String, stage String, quantity Array(Tuple(businessQuantity String, points Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.quantity AS g
ARRAY JOIN g.points   AS p
WHERE flow_code = 'ENERGY';
-- Measured: 684 ms · 600 files read (163.8 MB of JSON) · 625,080 rows written · 413.4 MB of memory

INSERT INTO silver.daily_pmax
SELECT toUInt64(m.meterId), toDate(m.period.startDate), toUInt32(p.v), parseDateTimeBestEffort(p.d, 'UTC'), ingested_at
FROM bronze.raw_flows
ARRAY JOIN JSONExtract(payload, 'measurements', 'Array(Tuple(meterId String, period Tuple(startDate String), quantity Array(Tuple(points Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.quantity AS g
ARRAY JOIN g.points   AS p
WHERE flow_code = 'PMAX';
-- Measured: 830 ms · 600 files read (142.6 MB of JSON) · 600,000 rows written · 405 MB of memory

SELECT
    (SELECT count() FROM silver.load_curve) AS curve_points,
    (SELECT count() FROM silver.daily_energy)  AS energy_rows,
    (SELECT count() FROM silver.daily_pmax)     AS pmax_rows,
    (SELECT count() FROM silver.rejects)        AS rejects;
-- Measured: 4 ms · 5 rows read


-- STEP 2 · The continuous flow: October 31 arrives
--  We insert ONLY into bronze. Watch silver fill up on its own.
--  The whole chain fires: bronze → MV → silver → MV (module 5) → gold.
SELECT count() AS points_before FROM silver.load_curve WHERE day = '2026-10-31';
-- Measured: 56 ms · 29.9 M rows read (57.1 MB)

INSERT INTO bronze.raw_flows
SELECT * FROM simulator.curve_files(start = 600, n = 20)
SETTINGS max_block_size = 2;
-- Measured: 5.91 s · 100 files read (183.5 MB of JSON) · 996,334 rows written · 305.8 MB of memory

SELECT count() AS points_after FROM silver.load_curve WHERE day = '2026-10-31';
-- Measured: 52 ms · 25.1 M rows read (47.9 MB)
-- What to look for: the number of points for the 31st goes from 0 to ~1 million.
-- Whatever the source of the INSERT into bronze, the materialized views propagate it.


-- STEP 3 · What compression does to the curves
--  What to look for: bronze (JSON) weighs tens of kilobytes per file, silver
--  about 1.5 bytes per point. The typed columnar format is the real win.
SELECT
    table,
    formatReadableQuantity(sum(rows))                                AS row_count,
    formatReadableSize(sum(data_uncompressed_bytes))                 AS raw,
    formatReadableSize(sum(data_compressed_bytes))                   AS on_disk,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes)) AS ratio,
    round(sum(data_compressed_bytes) / sum(rows), 2)                 AS bytes_per_point
FROM system.parts
WHERE database IN ('bronze', 'silver') AND active
GROUP BY table
ORDER BY sum(data_compressed_bytes) DESC;

--  Per column (sizes are readable thanks to min_bytes_for_wide_part = 0, see module 1).
--  What to look for: ts and meter_id cost almost nothing thanks to sorting and codecs;
--  value_w, which holds the "noise" of the measurements, weighs the most.
SELECT name, type, compression_codec,
       formatReadableSize(data_compressed_bytes) AS on_disk,
       round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio
FROM system.columns
WHERE database = 'silver' AND table = 'load_curve';


-- CHECKPOINT
--  More than 28 M points, 600,000 PMax (20,000 meters × 30 days) and the 31st delivered by the flow.
SELECT
    if((SELECT count() FROM silver.load_curve) > 28000000, 'OK', 'FAIL') AS curves,
    if((SELECT count() FROM silver.daily_energy)  > 600000,   'OK', 'FAIL') AS energy,
    if((SELECT count() FROM silver.daily_pmax)     = 600000,   'OK', 'FAIL') AS pmax,
    if((SELECT count() FROM silver.load_curve WHERE day = '2026-10-31') > 900000, 'OK', 'FAIL') AS continuous_flow
SETTINGS select_sequential_consistency = 1;   -- read the latest version, whichever replica serves it
