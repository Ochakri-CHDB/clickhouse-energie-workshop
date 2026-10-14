-- =====================================================================
--  MODULE 3 · The daylight saving time trap (October 25, 2026)
-- =====================================================================
--  At 3am the clocks go back to 2am: the day lasts 25 hours, so 50
--  half-hours. The local timestamps 02:30 exist TWICE.
--  That is why we store in UTC and display in local time.
-- =====================================================================


-- STEP 1 · Number of points per day (Paris time), for one meter
--  What to look for: 48 points on the 24th and 26th, 50 points on the 25th.
SELECT
    day,
    count() AS n_points
FROM silver.load_curve FINAL
WHERE meter_id = sim_meter_id(7) AND quantity = 'CONS'
  AND day BETWEEN '2026-10-24' AND '2026-10-26'
GROUP BY day
ORDER BY day;
-- Measured: 127 ms · 49,152 rows read (1,008 KB)


-- STEP 2 · The night of the 25th: same local time, two different instants
--  What to look for: 02:30 appears twice in local time, with a +0200 offset
--  then +0100. In UTC, no duplicate: that is why ts is stored in UTC.
SELECT
    ts                                    AS ts_utc,
    toTimeZone(ts, 'Europe/Paris')        AS local_time,
    formatDateTime(ts, '%z', 'Europe/Paris') AS utc_offset,
    value_w
FROM silver.load_curve FINAL
WHERE meter_id = sim_meter_id(7) AND quantity = 'CONS'
  AND ts BETWEEN '2026-10-24 23:00:00' AND '2026-10-25 03:00:00'
ORDER BY ts;
-- Measured: 121 ms · 16,384 rows read (400 KB)


-- STEP 3 · The number of expected points is computed, not assumed
--  We measure the actual length of the local day in minutes, then divide by 30.
--  The completeness KPI in module 5 uses exactly this calculation.
SELECT
    day,
    dateDiff('minute', toDateTime(day, 'Europe/Paris'), toDateTime(day + 1, 'Europe/Paris')) / 30 AS expected_points
FROM (SELECT toDate('2026-10-23') + number AS day FROM numbers(5));
-- Measured: 2 ms · 5 rows read
