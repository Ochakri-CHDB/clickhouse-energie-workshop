-- =====================================================================
--  MODULE 6 · Reading fast: primary index, projection, skip index,
--             parallel replicas, cache
-- =====================================================================
--  For each query, note in the console: duration, rows read, GB read.
--  The "Measured" numbers come from the test service: 3 replicas of
--  64 GB (16 vCPU), configured like yours, on 1.488 B points.
--
--  The five levers, from the most important to the most specific:
--    1. read fewer rows thanks to the ORDER BY (primary index)
--    2. spread a big scan over all replicas (parallel replicas)
--    3. pre-aggregate (projection)
--    4. skip blocks on a column outside the key (skip index)
--    5. do not recompute what was just computed (query cache)
-- =====================================================================


-- QUERY 1 · The curve of ONE meter over the month (the customer portal case)
--  The filter follows the start of the ORDER BY (quantity, meter_id): ClickHouse jumps
--  straight to the right granules (rule schema-pk-filter-on-orderby).
SELECT toTimeZone(ts, 'Europe/Paris') AS hour, value_w
FROM silver.load_curve_xl
WHERE quantity = 'CONS' AND meter_id = sim_meter_id(123456)   -- the first 2 columns of the ORDER BY
ORDER BY ts;
-- Measured: 16,384 rows read (272 KB) · 250 to 265 ms on the first call on a replica
-- (read from object storage), then 5 to 55 ms: the replica's local disk cache took over

--  EXPLAIN indexes = 1 shows what the index eliminated, without running the query.
EXPLAIN indexes = 1
SELECT value_w FROM silver.load_curve_xl WHERE quantity = 'CONS' AND meter_id = sim_meter_id(123456);
-- What to look for: under "PrimaryKey", the "Granules" line. Two granules of 8,192 rows
-- read out of ~180,000: that is why the query is instant.


-- QUERY 2 · Per department: 1.5 billion rows, 3 billion dictGet calls
--  No index can help here: we want ALL the rows. It is a full
--  scan, and its speed depends on the number of cores working on it.
SELECT
    dictGet('ref.dict_municipality', 'dept_code', dictGet('ref.dict_meter', 'insee_code', meter_id)) AS dept,
    dictGet('ref.dict_department', 'name', dept) AS department,
    round(sum(value_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.load_curve_xl
GROUP BY dept
ORDER BY gwh DESC
LIMIT 10;
-- Measured: 5.77 s · 1.488 B rows read (16.6 GB) · 388.3 MB memory


-- OPTIMIZATION A · Spread the scan over the 3 replicas (parallel replicas)
--  By default, a query runs on the replica that receives it. With
--  enable_parallel_replicas = 1, the table is split into chunks and each
--  replica processes a share. This is storage/compute separation:
--  all replicas read the same data from object storage, so you just add
--  compute to go faster.
SELECT
    dictGet('ref.dict_municipality', 'dept_code', dictGet('ref.dict_meter', 'insee_code', meter_id)) AS dept,
    dictGet('ref.dict_department', 'name', dept) AS department,
    round(sum(value_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.load_curve_xl
GROUP BY dept
ORDER BY gwh DESC
LIMIT 10
SETTINGS enable_parallel_replicas = 1;
-- Measured: 2.17 s · 1.488 B rows read (16.6 GB) · 197.1 MB memory
-- Gain: 5.77 s → 2.17 s (×2.7) with 3 replicas, without changing a line of SQL
-- What to look for: same result, same number of rows read, duration divided by
-- roughly the number of replicas. The gain is largest on queries
-- that compute a lot per row (here the dictGet calls).


-- OPTIMIZATION B · The aggregation PROJECTION (declared when the table was created)
--  The optimizer decides on its own to read the projection when it answers
--  the question: the query does not change. To measure the difference, we first
--  turn it off with optimize_use_projections = 0.
--  The national peak of the month, WITHOUT the projection:
SELECT toTimeZone(ts, 'Europe/Paris') AS instant, round(sum(value_w) / 1e6) AS mw
FROM silver.load_curve_xl
GROUP BY ts
ORDER BY mw DESC
LIMIT 5
SETTINGS optimize_use_projections = 0;
-- Measured: 1.3 s · 1.488 B rows read (11.1 GB) · 229.5 MB memory

--  … and WITH it (the default setting):
SELECT toTimeZone(ts, 'Europe/Paris') AS instant, round(sum(value_w) / 1e6) AS mw
FROM silver.load_curve_xl
GROUP BY ts
ORDER BY mw DESC
LIMIT 5;
-- Measured: 33 ms · 17,835 rows read (348.3 KB)
-- Gain: 1.3 s → 33 ms (×39), and 83,000 times fewer rows read
-- What to look for: same result, a few thousand rows read instead of 1.5 billion.
-- The projection already holds one row per half-hour (and per part).

--  Bonus: France's consumption day by day benefits from the same projection,
--  because toDate(ts) is computed from ts, which is in the projection.
SELECT toDate(ts - 1, 'Europe/Paris') AS day, round(sum(value_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.load_curve_xl
GROUP BY day
ORDER BY day;
-- Measured: 7 ms · 17,835 rows read (348.3 KB), versus ~1 s and 1.488 B rows without the projection

--  On a table that is already loaded, you would add the projection like this:
--    ALTER TABLE silver.load_curve_xl ADD PROJECTION p_national_curve (SELECT ts, sum(value_w), count() GROUP BY ts);
--    ALTER TABLE silver.load_curve_xl MATERIALIZE PROJECTION p_national_curve SETTINGS mutations_sync = 1;
--  MATERIALIZE rewrites every existing part: on 1.5 B rows, expect about
--  twenty seconds (measured: 22 s), to be scheduled outside peak hours.


-- OPTIMIZATION C · The minmax SKIP INDEX on the value
--  "Which points exceed 100 kW?": only the large industrial sites (C2)
--  reach that level. They are ~0.2% of the fleet, so most granules
--  have a max below 100 kW and can be skipped.
--  WITHOUT the index (use_skip_indexes = 0):
SELECT count() AS points_over_100kw, uniqExact(meter_id) AS meter
FROM silver.load_curve_xl
WHERE value_w > 100000
SETTINGS use_skip_indexes = 0;
-- Measured: 692 ms · 1.488 B rows read (5.7 GB) · 250 MB memory

--  WITH the index:
SELECT count() AS points_over_100kw, uniqExact(meter_id) AS meter
FROM silver.load_curve_xl
WHERE value_w > 100000;
-- Measured: 159 ms · 22.5 M rows read (245.6 MB) · 106.5 MB memory
-- Gain: 692 ms → 159 ms (×4.4), 1.5% of the table read

EXPLAIN indexes = 1
SELECT count() FROM silver.load_curve_xl WHERE value_w > 100000;
-- What to look for: under "Skip", the number of granules kept, a small fraction of the table.
-- A skip index only helps if the values you look for are grouped in few
-- granules. On a column where all values are mixed together, it skips nothing.
--  On a table that is already loaded: ALTER TABLE … ADD INDEX, then MATERIALIZE INDEX.
--  Watch out: MATERIALIZE INDEX on 1.5 B rows takes well over 60 s (measured: 109 s)
--  (the console gives up). That is why we declare the index in the CREATE TABLE.


-- OPTIMIZATION D · The query cache (dashboards refreshed in a loop)
--  A query's result is kept in memory for query_cache_ttl seconds.
--  The same query, with the same text and the same settings, is served from
--  the cache without reading anything again.
--  Watch out: dictGet is deemed "non-deterministic" (the dictionary can be
--  reloaded): without query_cache_nondeterministic_function_handling, ClickHouse
--  refuses to cache (error 704). Here the reference data changes at most every
--  hour, so a 5-min TTL is safe.
--  We clear the cache first, so the demo starts from scratch even if you rerun
--  the file (the cache survives tables being recreated, see below).
SYSTEM DROP QUERY CACHE;

SELECT
    dictGet('ref.dict_municipality', 'dept_code', dictGet('ref.dict_meter', 'insee_code', meter_id)) AS dept,
    dictGet('ref.dict_department', 'name', dept) AS department,
    round(sum(value_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.load_curve_xl
GROUP BY dept
ORDER BY gwh DESC
LIMIT 10
SETTINGS use_query_cache = 1, query_cache_ttl = 300,
         query_cache_nondeterministic_function_handling = 'save';
-- Measured: 4.93 s · 1.488 B rows read (16.6 GB) · 387.7 MB memory

--  … run exactly the same query again:
SELECT
    dictGet('ref.dict_municipality', 'dept_code', dictGet('ref.dict_meter', 'insee_code', meter_id)) AS dept,
    dictGet('ref.dict_department', 'name', dept) AS department,
    round(sum(value_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.load_curve_xl
GROUP BY dept
ORDER BY gwh DESC
LIMIT 10
SETTINGS use_query_cache = 1, query_cache_ttl = 300,
         query_cache_nondeterministic_function_handling = 'save';
-- Measured: 1 ms (result served by the cache, no data read again)
-- Gain: 4.93 s → 1 ms
-- What to look for: the 2nd run answers in one millisecond and reads no rows.
-- Watch out: the cache belongs to each replica. If the console sends you to
-- another replica, the 1st call recomputes there: run it once more.
-- Watch out: the cache is NOT cleared when the table changes, only the TTL counts.
-- Keep it for tiles where a few minutes of delay are acceptable.


-- GOING FURTHER · PREWHERE is automatic
--  ClickHouse first reads the column of the most selective filter (meter_id), then
--  only the other columns of the rows it kept. EXPLAIN shows it.
EXPLAIN actions = 1
SELECT sum(value_w) FROM silver.load_curve_xl WHERE meter_id = sim_meter_id(42) AND value_w > 1000;
