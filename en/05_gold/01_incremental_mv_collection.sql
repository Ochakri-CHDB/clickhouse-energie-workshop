-- =====================================================================
--  MODULE 5 · Gold (1/4): collection tracking, in real time
-- =====================================================================
--  bronze ──MV──► silver ──MV──► gold      (CASCADING MVs)
--  For each meter and each day, we count the points received, and those
--  received BEFORE 9am. Aggregation at insert time: AggregatingMergeTree.
--  Gold receives ready-made aggregates: the KPI is read from a small table
--  instead of recounting millions of points (rule query-mv-incremental).
-- =====================================================================


-- STEP 1 · An aggregate table: it stores STATES, not values
--  A state is an "in-progress" calculation (for example the set of timestamps seen).
--  Two states merge without losing anything: that is what the merges do.
--  SimpleAggregateFunction is enough for min and max, which merge trivially.
CREATE OR REPLACE TABLE gold.meter_day_collection
(
    day               Date,
    meter_id             UInt64,
    points_received       AggregateFunction(uniqExact, DateTime('UTC')),
    points_before_9am    AggregateFunction(uniqExactIf, DateTime('UTC'), UInt8),
    first_arrival   SimpleAggregateFunction(min, DateTime64(3, 'UTC')),
    last_arrival   SimpleAggregateFunction(max, DateTime64(3, 'UTC'))
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(day)
ORDER BY (day, meter_id);


-- STEP 2 · The MV attached to silver (triggered by the bronze → silver MV)
--  uniqExact is IDEMPOTENT: a resent file is not counted twice.
--  The -State suffix produces the state instead of the final result.
CREATE OR REPLACE MATERIALIZED VIEW gold.mv_collection TO gold.meter_day_collection AS
SELECT
    day,
    meter_id,
    uniqExactState(ts)                                                                  AS points_received,
    uniqExactIfState(ts, toUInt8(version < toDateTime(day + 1, 'Europe/London') + INTERVAL 9 HOUR)) AS points_before_9am,
    min(version)                                                                        AS first_arrival,
    max(version)                                                                        AS last_arrival
FROM silver.load_curve
WHERE quantity = 'CONS'
GROUP BY day, meter_id;


-- STEP 3 · Backfill from silver (the MV only sees the future, remember)
INSERT INTO gold.meter_day_collection
SELECT
    day, meter_id,
    uniqExactState(ts),
    uniqExactIfState(ts, toUInt8(version < toDateTime(day + 1, 'Europe/London') + INTERVAL 9 HOUR)),
    min(version), max(version)
FROM silver.load_curve
WHERE quantity = 'CONS'
GROUP BY day, meter_id;
-- Measured: 5.3 s · 29.8 M rows read (653.9 MB) · 618,163 rows written · 3.2 GB memory


-- STEP 4 · Reading states: the -Merge suffix
--  uniqExactMerge merges the states from all parts and returns the final count.
--  Always with a GROUP BY: several rows can exist for the same meter-day.
SELECT
    day,
    uniqExactMerge(points_received)     AS points,
    uniqExactIfMerge(points_before_9am) AS points_before_9am,
    min(first_arrival)            AS first_arrival
FROM gold.meter_day_collection
WHERE meter_id = sim_meter_id(42)
GROUP BY day
ORDER BY day
LIMIT 10;
-- Measured: 39 ms · 253,952 rows read (62.5 MB) · 269.1 MB memory


-- STEP 5 · The duplicate experiment: is a SUM in an MV safe?
--  We create an MV that sums energy per day, then resend a file.
CREATE OR REPLACE TABLE gold.naive_energy
(
    day        Date,
    energy_kwh SimpleAggregateFunction(sum, Float64)
)
ENGINE = AggregatingMergeTree
ORDER BY day;

CREATE OR REPLACE MATERIALIZED VIEW gold.mv_naive_energy TO gold.naive_energy AS
SELECT day, sum(value_w * step_min / 60 / 1000) AS energy_kwh
FROM silver.load_curve
WHERE quantity = 'CONS'
GROUP BY day;

INSERT INTO gold.naive_energy
SELECT day, sum(value_w * step_min / 60 / 1000) FROM silver.load_curve FINAL WHERE quantity = 'CONS' GROUP BY day;
-- Measured: 301 ms · 30.4 M rows read (810.6 MB) · 31 rows written · 359.6 MB memory

--  We resend a file that was already received (batch 3 of October 20)
INSERT INTO bronze.raw_flows
SELECT replaceOne(file_name, '_488903_', '_488903_RESEND_'), flow_code, ingested_at + INTERVAL 1 DAY, payload
FROM bronze.raw_flows
WHERE file_name LIKE 'DSO_CURVE_30MIN_PUB_100383_488903_2%';
-- Measured: 457 ms · 102,104 rows read (20 MB) · 51,148 rows written · 96.5 MB memory

SELECT
    (SELECT round(sum(energy_kwh)) FROM gold.naive_energy WHERE day = '2026-10-20')                         AS sum_by_mv,
    (SELECT round(sum(value_w * step_min / 60 / 1000)) FROM silver.load_curve FINAL WHERE quantity = 'CONS' AND day = '2026-10-20') AS actual_sum,
    (SELECT sum(n) FROM (SELECT uniqExactMerge(points_received) AS n FROM gold.meter_day_collection WHERE day = '2026-10-20' GROUP BY meter_id)) AS points_mv_uniq,
    (SELECT count() FROM silver.load_curve FINAL WHERE quantity = 'CONS' AND day = '2026-10-20')           AS actual_points;
-- Measured: 379 ms · 61.1 M rows read (1.5 GB) · 357.3 MB memory
-- What to look for: the sum is off by about 6% (the resent file is counted
--    twice), uniqExact stays correct.
--    Rule: sum in an incremental MV only if the source never has duplicates.
--    Otherwise: a REFRESHABLE materialized view on silver FINAL (next file).

--  We drop the experiment: it is no longer needed.
DROP VIEW gold.mv_naive_energy;
DROP TABLE gold.naive_energy;
