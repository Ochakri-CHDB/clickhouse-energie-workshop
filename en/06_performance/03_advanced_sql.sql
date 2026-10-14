-- =====================================================================
--  MODULE 6 · Advanced SQL on load curves
-- =====================================================================
--  Seven SQL tools that come up all the time with time series.
--  They run on silver.load_curve (the 20,000 meters of the JSON files).
-- =====================================================================


-- 1 · 2-hour moving average (window function)
--  OVER (ORDER BY ts ROWS BETWEEN 3 PRECEDING AND CURRENT ROW): for each
--  row, the average of the row and the 3 before it, i.e. 4 half-hours = 2 h.
--  The window smooths the noise without grouping the rows.
SELECT
    toTimeZone(ts, 'Europe/Paris')                                         AS hour,
    value_w,
    round(avg(value_w) OVER (ORDER BY ts ROWS BETWEEN 3 PRECEDING AND CURRENT ROW)) AS avg_2h
FROM silver.load_curve FINAL
WHERE meter_id = sim_meter_id(7) AND quantity = 'CONS' AND day = '2026-10-15'
ORDER BY ts;
-- Measured: 12 ms · 49,152 rows read (1.3 MB)


-- 2 · Make the GAPS visible: WITH FILL
--  Take an incomplete meter-day spotted by the collection tracking.
--  ORDER BY … WITH FILL adds the missing rows of the series, from FROM to TO,
--  in steps of STEP (1800 s). The columns of the added rows get their
--  default value (0): the received column tells us where the gaps are.
WITH (
    SELECT (meter_id, day) FROM gold.meter_day_collection
    GROUP BY meter_id, day
    HAVING uniqExactMerge(points_received) BETWEEN 40 AND 47
    ORDER BY day, meter_id LIMIT 1
) AS target
SELECT toTimeZone(ts, 'Europe/Paris') AS hour, value_w, if(received = 0, 'missing', '') AS flag
FROM
(
    SELECT ts, value_w, 1 AS received                    -- the rows added by WITH FILL will have received = 0
    FROM silver.load_curve FINAL
    WHERE meter_id = target.1 AND quantity = 'CONS' AND day = target.2
    ORDER BY ts WITH FILL
        FROM toDateTime(assumeNotNull(target.2), 'Europe/Paris') + 1800     -- assumeNotNull: WITH FILL wants
        TO   toDateTime(assumeNotNull(target.2) + 1, 'Europe/Paris') + 1    -- a non-Nullable constant
        STEP 1800
);
-- Measured: 112 ms · 668,312 rows read (78 MB) · 896.9 MB memory
-- What to look for: the missing half-hour shows up with value_w = 0 and the flag "missing".


-- 3 · Each meter's peak hour (argMax), in a single pass
--  argMax(ts, value_w) returns the ts of the row where value_w is highest:
--  no subquery or join needed to find "the time of the max".
SELECT
    dictGet('ref.dict_meter', 'profile', meter_id)                AS profile,
    toHour(argMax(ts, value_w), 'Europe/Paris')             AS peak_hour,
    count()                                                  AS n_meters
FROM silver.load_curve FINAL
WHERE quantity = 'CONS' AND day = '2026-10-15'
GROUP BY meter_id
ORDER BY profile, peak_hour;   -- group them by eye: RES in the evening, PRO during the day
-- Measured: 183 ms · 30.5 M rows read (785.6 MB) · 347.5 MB memory


-- 4 · Typical profile: weekday vs weekend, by local hour
--  avgIf(value, condition): a filtered average. Two columns in a single scan.
SELECT
    toHour(ts - 900, 'Europe/Paris')                                        AS hour,
    round(avgIf(value_w, toDayOfWeek(ts, 0, 'Europe/Paris') <= 5))         AS weekday_w,
    round(avgIf(value_w, toDayOfWeek(ts, 0, 'Europe/Paris') >= 6))         AS weekend_w,
    bar(weekday_w, 0, 3000, 25)                                             AS weekday_chart
FROM silver.load_curve FINAL
WHERE quantity = 'CONS' AND dictGet('ref.dict_meter', 'profile', meter_id) = 'PRO'
GROUP BY hour
ORDER BY hour;
-- Measured: 188 ms · 23.4 M rows read (552.3 MB) · 322.9 MB memory


-- 5 · Distribution by segment: quantiles and load factor
--  quantiles(0.5, 0.9, 0.99) computes several percentiles in one pass.
--  The load factor (average / max) tells whether a site consumes steadily.
SELECT
    dictGet('ref.dict_meter', 'segment', meter_id)       AS segment,
    quantiles(0.5, 0.9, 0.99)(value_w)               AS p50_p90_p99_w,
    round(avg(value_w) / max(value_w), 3)           AS load_factor
FROM silver.load_curve FINAL
WHERE quantity = 'CONS'
GROUP BY segment
ORDER BY segment;
-- Measured: 234 ms · 30.5 M rows read (727.1 MB) · 402.8 MB memory


-- 6 · ASOF JOIN: subscribed power "at date", without a dictionary
--  For each PMax, ASOF JOIN takes the most recent history row whose
--  valid_from is on or before the day. Same result as the RANGE_HASHED
--  dictionary of module 4, written as a join.
SELECT
    p.meter_id, p.day, p.pmax_va, h.power_kva AS kva_at_date,
    p.pmax_va > h.power_kva * 1000 AS overrun
FROM silver.daily_pmax AS p FINAL
ASOF JOIN ref.meter_history AS h ON p.meter_id = h.meter_id AND p.day >= h.valid_from
WHERE p.meter_id IN (SELECT meter_id FROM ref.meter_history WHERE valid_to BETWEEN '2026-10-01' AND '2026-10-30' LIMIT 3)
ORDER BY p.meter_id, p.day
LIMIT 20;
-- Measured: 58 ms · 2.1 M rows read (22.6 MB) · 262.8 MB memory


-- 7 · Self-consumption: at what time does production cover consumption?
--  sumIf separates CONS and PROD in the same query. We reuse the aliases
--  prod_kw and cons_kw in the next calculation: ClickHouse allows it.
SELECT
    toHour(ts - 900, 'Europe/Paris')                             AS hour,
    round(sumIf(value_w, quantity = 'PROD') / 1000)             AS prod_kw,
    round(sumIf(value_w, quantity = 'CONS') / 1000)             AS cons_kw,
    round(100 * prod_kw / cons_kw, 1)                           AS coverage_pct
FROM silver.load_curve FINAL
WHERE meter_id IN (SELECT meter_id FROM ref.meter WHERE pv_kwp > 0)
  AND day = '2026-10-15'
GROUP BY hour
ORDER BY hour;
-- Measured: 136 ms · 13.6 M rows read (331 MB) · 365.2 MB memory
