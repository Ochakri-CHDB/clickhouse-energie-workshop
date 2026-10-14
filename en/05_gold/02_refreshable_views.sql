-- =====================================================================
--  MODULE 5 · Gold (2/4): consolidated KPIs, refreshed on a schedule
-- =====================================================================
--  A REFRESHABLE materialized view recomputes its query on a schedule
--  and atomically replaces the result. It reads silver FINAL, so
--  duplicates and corrections are always taken into account.
--
--     silver FINAL ──(every 10 min)──► gold.ward_day_energy
--                                              │ DEPENDS ON
--                                              ▼
--                                    gold.authority_day_summary
--
--  Incremental or refreshable MV?
--    · incremental: real time, but only sees the INSERTs (the sum trap)
--    · refreshable: recomputes everything, correct with FINAL and joins,
--      at the cost of a small delay (rule query-mv-refreshable).
-- =====================================================================


-- STEP 1 · Energy by ward, by day, by segment
--  The target table is sorted the way the dashboard filters it: by metro area, then ward.
CREATE OR REPLACE TABLE gold.ward_day_energy
(
    day          Date,
    ward_code    String,
    metro_code     LowCardinality(String),
    district_code     LowCardinality(String),
    segment       LowCardinality(String),
    quantity      LowCardinality(String),
    energy_kwh   Float64,
    n_meters        UInt32,
    max_power_w UInt32
)
ENGINE = MergeTree
ORDER BY (metro_code, ward_code, quantity, day);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_ward_day_energy
REFRESH EVERY 10 MINUTE
TO gold.ward_day_energy
AS
SELECT
    day,
    dictGet('ref.dict_meter', 'ward_code', meter_id)                         AS ward_code,
    dictGet('ref.dict_ward', 'metro_code', ward_code)                  AS metro_code,
    dictGet('ref.dict_ward', 'district_code', ward_code)                  AS district_code,
    dictGet('ref.dict_meter', 'segment', meter_id)                            AS segment,
    quantity,
    sum(value_w * step_min / 60 / 1000)                                   AS energy_kwh,
    uniqExact(meter_id)                                                     AS n_meters,
    max(value_w)                                                         AS max_power_w
FROM silver.load_curve FINAL
GROUP BY day, ward_code, metro_code, district_code, segment, quantity;

--  The first refresh starts right away. Follow it in
--  system.view_refreshes (status, duration, rows written, next run):
SELECT view, status, last_success_time, last_refresh_time, next_refresh_time, read_rows, written_rows
FROM system.view_refreshes
WHERE database = 'gold';

--  We wait for this 1st computation to finish before attaching other views to the table.
--  Watch out: without this wait, on a service with several replicas, step 3
--  fails with "has been changed by another replica".
SYSTEM WAIT VIEW gold.rmv_ward_day_energy;
-- Measured: 487 ms


-- STEP 2 · The load curve aggregated by metro area (for the dashboard)
--  30 million silver points become about 18,000 rows: one curve per metro area
--  (combined authority or Greater London, '' for the wards outside) and per quantity.
CREATE OR REPLACE TABLE gold.metro_curve
(
    metro_code     LowCardinality(String),
    quantity      LowCardinality(String),
    ts            DateTime('UTC'),
    power_kw  Float64,
    n_meters        UInt32
)
ENGINE = MergeTree
ORDER BY (metro_code, quantity, ts);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_metro_curve
REFRESH EVERY 10 MINUTE
TO gold.metro_curve
AS
SELECT
    dictGet('ref.dict_ward', 'metro_code', dictGet('ref.dict_meter', 'ward_code', meter_id)) AS metro_code,
    quantity,
    ts,
    sum(value_w) / 1000                                                                    AS power_kw,
    count()                                                                                 AS n_meters
FROM silver.load_curve FINAL
GROUP BY metro_code, quantity, ts;


-- STEP 3 · A view that DEPENDS on another one: the summary per local authority
--  DEPENDS ON: it waits until the energy by ward has been refreshed.
CREATE OR REPLACE TABLE gold.authority_day_summary
(
    recipient_id  String,
    authority     String,
    day             Date,
    cons_kwh        Float64,
    prod_kwh         Float64,
    coverage_rate  Float64,         -- production / consumption
    n_meters           UInt32
)
ENGINE = MergeTree
ORDER BY (recipient_id, day);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_authority_summary
REFRESH EVERY 10 MINUTE
DEPENDS ON gold.rmv_ward_day_energy
TO gold.authority_day_summary
AS
SELECT
    d.recipient_id,
    d.name                                                 AS authority,
    e.day,
    sumIf(e.energy_kwh, e.quantity = 'CONS')             AS cons_kwh,
    sumIf(e.energy_kwh, e.quantity = 'PROD')             AS prod_kwh,
    round(prod_kwh / cons_kwh, 4)                        AS coverage_rate,
    sumIf(e.n_meters, e.quantity = 'CONS')                  AS n_meters
FROM gold.ward_day_energy AS e
INNER JOIN ref.recipient AS d ON d.metro_code = e.metro_code
GROUP BY d.recipient_id, d.name, e.day;


-- STEP 4 · Forcing a refresh (instead of waiting 10 min)
--  SYSTEM REFRESH starts the computation, SYSTEM WAIT waits until it is done.
--  The result replaces the old one in one go: a dashboard never sees a partial state.
SYSTEM REFRESH VIEW gold.rmv_ward_day_energy;
SYSTEM WAIT VIEW gold.rmv_ward_day_energy;
-- Measured: 708 ms
SYSTEM REFRESH VIEW gold.rmv_authority_summary;
SYSTEM WAIT VIEW gold.rmv_authority_summary;
-- Measured: 269 ms
SYSTEM REFRESH VIEW gold.rmv_metro_curve;
SYSTEM WAIT VIEW gold.rmv_metro_curve;
-- Measured: 557 ms

SELECT view, status, last_success_time, round(last_success_duration_ms / 1000, 2) AS duration_s, written_rows
FROM system.view_refreshes
WHERE database = 'gold';

SELECT authority, round(sum(cons_kwh) / 1000) AS cons_mwh, round(sum(prod_kwh) / 1000) AS prod_mwh,
       round(100 * sum(prod_kwh) / sum(cons_kwh), 1) AS coverage_pct, max(n_meters) AS n_meters
FROM gold.authority_day_summary
GROUP BY authority
ORDER BY cons_mwh DESC;
-- Measured: 15 ms · 186 rows read (9.9 KB)
-- What to look for: 6 local authorities. The Greater London Authority comes first
--    (10,846 MWh consumed, 458 MWh produced, 4.2 % coverage, 11,973 meters),
--    then the West Midlands (2,140 MWh, 1,997 meters).
