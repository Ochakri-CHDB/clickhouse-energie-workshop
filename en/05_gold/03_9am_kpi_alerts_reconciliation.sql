-- =====================================================================
--  MODULE 5 · Gold (3/4): completeness at 9am, alerts, reconciliation
-- =====================================================================


-- STEP 1 · KPI "99% of the data received by 9am"
--  Two readings of the same collection tracking:
--    · data_by_9am_pct: points received before 9am / points expected across the whole fleet
--      (this is the contractual target: 99%)
--    · complete_meters_9am_pct: meters whose day is COMPLETE at 9am, stricter
--      (a single missing point and the meter does not count)
--  In production: REFRESH EVERY 1 DAY OFFSET 9 HOUR (every day at 9am).
--  The view reads gold.meter_day_collection (small), not silver: the computation is instant.
CREATE OR REPLACE TABLE gold.daily_completeness_kpi
(
    day                      Date,
    meter_fleet                  UInt32,
    meters_received                 UInt32,
    expected_points           UInt64,
    points_received_9am           UInt64,
    data_by_9am_pct       Float64,
    complete_meters_9am         UInt32,
    complete_meters_9am_pct  Float64
)
ENGINE = MergeTree
ORDER BY day;

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_completeness_kpi
REFRESH EVERY 1 DAY OFFSET 9 HOUR
TO gold.daily_completeness_kpi
AS
WITH
    (SELECT uniqExact(meter_id) FROM gold.meter_day_collection) AS fleet,
    per_meter AS
    (
        SELECT
            day,
            meter_id,
            uniqExactMerge(points_received)                                                                      AS received_n,
            uniqExactIfMerge(points_before_9am)                                                                 AS before_9am,
            dateDiff('minute', toDateTime(day, 'Europe/London'), toDateTime(day + 1, 'Europe/London')) / 30   AS expected
        FROM gold.meter_day_collection
        GROUP BY day, meter_id
    )
SELECT
    day,
    fleet                                                     AS meter_fleet,
    count()                                                  AS meters_received,
    toUInt64(fleet * any(expected))                           AS expected_points,   -- a silent meter counts too
    sum(before_9am)                                            AS points_received_9am,
    round(100 * points_received_9am / expected_points, 2)        AS data_by_9am_pct,
    countIf(before_9am = expected)                             AS complete_meters_9am,
    round(100 * complete_meters_9am / fleet, 2)                 AS complete_meters_9am_pct
FROM per_meter
GROUP BY day;

SYSTEM REFRESH VIEW gold.rmv_completeness_kpi;
SYSTEM WAIT VIEW gold.rmv_completeness_kpi;
-- Measured: 659 ms

SELECT day, data_by_9am_pct, complete_meters_9am_pct,
       if(data_by_9am_pct >= 99, 'OK', 'below target') AS target_99
FROM gold.daily_completeness_kpi
ORDER BY day;
-- Measured: 33 ms · 31 rows read
-- What to look for: most days meet the target. The ones below: one or more files
--    arrived in the afternoon (one batch = 1000 meters, i.e. 5% of the fleet at once).

--  Which ones? The CURVE files that arrived after 9am, London time
SELECT toDate(ingested_at, 'Europe/London') - 1 AS day, file_name, toTimeZone(ingested_at, 'Europe/London') AS arrival
FROM bronze.raw_flows
WHERE flow_code = 'CURVE' AND toHour(ingested_at, 'Europe/London') >= 9
  AND file_name NOT LIKE '%RESEND%' AND file_name NOT LIKE '%CORRECTION%'
ORDER BY ingested_at
LIMIT 10;
-- Measured: 5 ms · 116 rows read (7 KB)


-- STEP 2 · Subscribed power overrun alerts
--  The reference power is the one IN FORCE on the day of the overrun:
--  dictGet on the "as of" dictionary from module 4, with the day as the 2nd key.
CREATE OR REPLACE TABLE gold.pmax_alerts
(
    day             Date,
    meter_id           UInt64,
    ward          String,
    metro_code        LowCardinality(String),
    segment          LowCardinality(String),
    subscribed_kva     UInt16,
    pmax_va          UInt32,
    overrun_pct  Float64,
    peak_time     DateTime('Europe/London')
)
ENGINE = MergeTree
ORDER BY (day, meter_id);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_pmax_alerts
REFRESH EVERY 10 MINUTE
TO gold.pmax_alerts
AS
SELECT
    day,
    meter_id,
    dictGet('ref.dict_ward', 'name', dictGet('ref.dict_meter', 'ward_code', meter_id))       AS ward,
    dictGet('ref.dict_ward', 'metro_code', dictGet('ref.dict_meter', 'ward_code', meter_id)) AS metro_code,
    dictGet('ref.dict_meter', 'segment', meter_id)                                               AS segment,
    dictGet('ref.dict_power_asof', 'power_kva', meter_id, day)                        AS subscribed_kva,
    pmax_va,
    round(100 * (pmax_va / (subscribed_kva * 1000) - 1), 1)                                    AS overrun_pct,
    ts_pmax                                                                                  AS peak_time
FROM silver.daily_pmax FINAL
WHERE pmax_va > dictGet('ref.dict_power_asof', 'power_kva', meter_id, day) * 1000;

SYSTEM REFRESH VIEW gold.rmv_pmax_alerts;
SYSTEM WAIT VIEW gold.rmv_pmax_alerts;
-- Measured: 416 ms

SELECT day, count() AS n_alerts, round(avg(overrun_pct), 1) AS avg_overrun_pct
FROM gold.pmax_alerts
GROUP BY day
ORDER BY day;
-- Measured: 36 ms · 257 rows read (2.5 KB)

--  By segment: in C5, the meter's circuit breaker trips before any overrun.
--  So the alerts only concern C4 and C2 (where overruns are billed).
SELECT segment, count() AS alerts, uniqExact(meter_id) AS meter, round(avg(overrun_pct), 1) AS avg_overrun_pct
FROM gold.pmax_alerts
GROUP BY segment;
-- Measured: 3 ms · 257 rows read (4.3 KB)

--  Meters that increased their power in October: fewer alerts afterwards?
SELECT
    countIf(a.day <= h.valid_to)  AS alerts_before_change,
    countIf(a.day >  h.valid_to)  AS alerts_after_change,
    uniqExact(a.meter_id)            AS meter
FROM gold.pmax_alerts AS a
INNER JOIN (SELECT meter_id, valid_to FROM ref.meter_history WHERE valid_to BETWEEN '2026-10-01' AND '2026-10-30') AS h
    ON h.meter_id = a.meter_id;
-- Measured: 12 ms · 1 M rows read (9.8 MB) · 63.7 MB memory
-- What to look for: the customer was overrunning, increased their power, the alerts drop.
--    dict_power_asof is what makes this correct: we compare with the power OF THAT DAY.


-- STEP 3 · Reconciliation: daily energy (meter index) vs integral of the CURVE load curve
--  A gap reveals an incomplete curve: we know WHERE and HOW MUCH is missing.
--  Daily energy comes from the meter's index readings, so it is complete even if the curve has gaps.
--  A plain view (CREATE VIEW) stores nothing: the query runs on every read.
CREATE OR REPLACE VIEW gold.v_reconciliation AS
SELECT
    e.day,
    e.meter_id,
    e.energy_wh / 1000                                          AS daily_energy_kwh,
    c.curve_energy_kwh,
    c.n_points,
    round(100 * (1 - c.curve_energy_kwh / (e.energy_wh / 1000)), 2) AS gap_pct
FROM silver.daily_energy AS e FINAL
INNER JOIN
(
    SELECT day, meter_id, sum(value_w * step_min / 60) / 1000 AS curve_energy_kwh, count() AS n_points
    FROM silver.load_curve FINAL
    WHERE quantity = 'CONS'
    GROUP BY day, meter_id
) AS c ON c.day = e.day AND c.meter_id = e.meter_id
WHERE e.quantity = 'CONS';

SELECT
    multiIf(abs(gap_pct) < 0.5, '1. < 0.5% (normal)', abs(gap_pct) < 3, '2. 0.5 to 3% (1 missing point)', '3. > 3% (several gaps)') AS gap_class,
    count()                    AS meter_days,
    round(avg(n_points), 1)   AS avg_points
FROM gold.v_reconciliation
GROUP BY gap_class
ORDER BY gap_class;
-- Measured: 240 ms · 31.2 M rows read (826.1 MB) · 432.1 MB memory
-- What to look for: more than 97% of meter-days match within 0.5%. The others have
-- 1 or 2 missing points (47 or 46 points instead of 48): the curve needs to be completed.


-- CHECKPOINT MODULE 5
--  31 days of KPI, and at least one alert and one row in each gold table.
SELECT
    if((SELECT count() FROM gold.meter_day_collection) > 500000, 'OK', 'FAIL')          AS collection,
    if((SELECT count() FROM gold.ward_day_energy) > 0, 'OK', 'FAIL')            AS energy,
    if((SELECT count() FROM gold.authority_day_summary) > 0, 'OK', 'FAIL')      AS summary,
    if((SELECT count() FROM gold.daily_completeness_kpi) = 31, 'OK', 'FAIL')            AS kpi_9h,
    if((SELECT count() FROM gold.pmax_alerts) > 0, 'OK', 'FAIL')                    AS alerts
SETTINGS select_sequential_consistency = 1;   -- read the latest version, whichever replica serves it
