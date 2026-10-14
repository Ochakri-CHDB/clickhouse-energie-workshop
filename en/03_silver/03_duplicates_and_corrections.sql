-- =====================================================================
--  MODULE 3 · File resends and corrections: ReplacingMergeTree
-- =====================================================================
--  In real life: a file is sent twice, a RAW curve is corrected
--  a few days later. What does silver do?
-- =====================================================================


-- The meter we will follow (sim_meter_id turns a number into a meter identifier)
SELECT sim_meter_id(42) AS tracked_meter;
-- Measured: 2 ms · 1 row read


-- STEP 1 · A file is resent unchanged, 3 days later
INSERT INTO bronze.raw_flows
SELECT
    replaceOne(file_name, '_488903_', '_488903_RESEND_') AS file_name,
    flow_code,
    ingested_at + INTERVAL 3 DAY                          AS ingested_at,
    payload
FROM bronze.raw_flows
WHERE flow_code = 'CURVE'
  AND file_name LIKE 'DSO_CURVE_30MIN_PUB_100280_%';   -- batch 0 of October 15 (Greater London)
-- Measured: 146 ms · 624 files read (11.5 MB of JSON) · 49,865 rows written · 101.6 MB of memory

--  The points are now duplicated on disk…
--  What to look for: 96 rows for 48 distinct timestamps. Nothing was overwritten at INSERT.
SELECT count() AS row_count, uniqExact(ts) AS distinct_points
FROM silver.load_curve
WHERE meter_id = sim_meter_id(42) AND day = '2026-10-15';
-- Measured: 74 ms · 90,662 rows read (742.2 KB)


-- STEP 2 · Three ways to read WITHOUT duplicates
--  a) FINAL: ClickHouse deduplicates at read time.
--     Simple and correct. It costs a bit more than a normal read, especially
--     without a filter: keep it for filtered queries, or for gold tables.
SELECT count() AS row_count
FROM silver.load_curve FINAL
WHERE meter_id = sim_meter_id(42) AND day = '2026-10-15';
-- Measured: 126 ms · 98,854 rows read (1.9 MB)

--  b) argMax(value, version): the value of the row with the highest version.
--     Same result as FINAL, written by hand.
SELECT toTimeZone(ts, 'Europe/London') AS local_time, argMax(value_w, version) AS value_w
FROM silver.load_curve
WHERE meter_id = sim_meter_id(42) AND day = '2026-10-15'
GROUP BY local_time
ORDER BY local_time
LIMIT 5;
-- Measured: 103 ms · 16,384 rows read (205.3 KB)

--  c) Let the merges clean up: they deduplicate in the background,
--     with no guaranteed timing. We do NOT call OPTIMIZE TABLE … FINAL: it rewrites
--     the whole partition (rule insert-optimize-avoid-final). FINAL at read time is enough.


-- STEP 3 · A correction: the distribution system operator republishes the 15th as CORRECTED
INSERT INTO bronze.raw_flows
SELECT
    replaceOne(file_name, '_488903_', '_488903_CORRECTION_'),
    flow_code,
    ingested_at + INTERVAL 5 DAY,
    replaceAll(payload, '"stage":"RAW"', '"stage":"CORRECTED"')
FROM bronze.raw_flows
WHERE flow_code = 'CURVE'
  AND file_name LIKE 'DSO_CURVE_30MIN_PUB_100280_488903_2%';
-- Measured: 155 ms · 625 files read (11.5 MB of JSON) · 49,865 rows written · 103.6 MB of memory

SELECT stage, count() AS points, max(version) AS kept_version
FROM silver.load_curve FINAL
WHERE meter_id = sim_meter_id(42) AND day = '2026-10-15'
GROUP BY stage;
-- Measured: 89 ms · 123,430 rows read (2.7 MB)
-- What to look for: a single visible version, CORRECTED replaced RAW, without any UPDATE.
-- This is the ClickHouse way to correct data: reinsert a more recent version
-- (rule insert-mutation-avoid-update).


-- STEP 4 · The trap to know about (we come back to it in module 5)
--  An MV sees the INSERTs, not the deduplicated state. A sum computed by an
--  MV would count the resent file twice. Idempotent aggregates
--  (max, min, uniq) are not affected. Sums are.
