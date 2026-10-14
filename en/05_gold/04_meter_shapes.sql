-- =====================================================================
--  MODULE 5 · Gold (4/4): the consumption shape of each meter
-- =====================================================================
--  A "features" table for data science (module 8, agent + Run Code).
--  Each meter is summarized by its average shape: 24 values for a weekday
--  and 24 for a weekend day, divided by its average consumption
--  (1 = the meter's average). 30 M points become 20,000 rows.
--
--  Good practice: prepare the data in ClickHouse (fast, as close as possible
--  to the data), and send only the small result to the Python model.
-- =====================================================================


-- STEP 1 · The table: one row per meter, the shapes in arrays
--  Array(Float32): 24 values in a single column, read in one block.
--  ORDER BY (segment, profile, meter_id): we often sample by segment.
CREATE OR REPLACE TABLE gold.meter_profile
(
    meter_id          UInt64,
    profile          LowCardinality(String),
    segment         LowCardinality(String),
    power_kva   UInt16,
    avg_cons_w     Float64,
    weekday_shape   Array(Float32),
    weekend_shape   Array(Float32)
)
ENGINE = MergeTree
ORDER BY (segment, profile, meter_id);


-- STEP 2 · The computation, in one query
--  The subquery averages per meter, day type and local hour.
--  groupArrayIf gathers the 24 hours of a day type into an array,
--  arraySort((x, h) -> h, ...) puts them back in hour order,
--  and arrayMap divides each value by the meter's average.
INSERT INTO gold.meter_profile
SELECT
    meter_id,
    dictGet('ref.dict_meter', 'profile', meter_id),
    dictGet('ref.dict_meter', 'segment', meter_id),
    dictGet('ref.dict_meter', 'power_kva', meter_id),
    round(avg(cons_w), 1),
    arrayMap(x -> toFloat32(round(x / avg(cons_w), 3)), arraySort((x, h) -> h, groupArrayIf(cons_w, day_type = 'weekday'), groupArrayIf(hour, day_type = 'weekday'))),
    arrayMap(x -> toFloat32(round(x / avg(cons_w), 3)), arraySort((x, h) -> h, groupArrayIf(cons_w, day_type = 'weekend'), groupArrayIf(hour, day_type = 'weekend')))
FROM
(
    SELECT meter_id,
           if(toDayOfWeek(ts - 1, 0, 'Europe/Paris') >= 6, 'weekend', 'weekday') AS day_type,
           toHour(ts - 900, 'Europe/Paris') AS hour,
           avg(value_w) AS cons_w
    FROM silver.load_curve FINAL
    WHERE quantity = 'CONS'
    GROUP BY meter_id, day_type, hour
)
GROUP BY meter_id;
-- Measured: 817 ms · 30.1 M rows read (744.7 MB) · 19,999 rows written · 544.1 MB of memory


-- STEP 3 · Comments for the agent (module 8)
ALTER TABLE gold.meter_profile
    MODIFY COMMENT 'Average consumption shape of each meter in October 2026, for data science. One row per meter.';
-- Measured: 74 ms
ALTER TABLE gold.meter_profile
    COMMENT COLUMN segment       'C5 (up to 36 kVA), C4 (36 to 250 kVA), C2 (connected at medium voltage, HTA)',
    COMMENT COLUMN profile        'Declared profile: RES (residential), PRO (professional), ENT (business, industry)',
    COMMENT COLUMN avg_cons_w   'Average power of the meter over the month, in W',
    COMMENT COLUMN weekday_shape '24 values, from 0h to 23h (Paris time), weekday, divided by avg_cons_w',
    COMMENT COLUMN weekend_shape '24 values, from 0h to 23h (Paris time), weekend day, divided by avg_cons_w';
-- Measured: 79 ms


-- STEP 4 · The average shapes by profile
SELECT profile, count() AS meters, arrayMap(x -> round(x, 1), any(weekday_shape)) AS weekday_example
FROM gold.meter_profile
GROUP BY profile;
-- Measured: 8 ms · 19,999 rows read (2 MB)
-- What to look for: the evening peak of households (RES), the 8am-7pm plateau of
-- professionals (PRO), the high base load of industry (ENT).

--  The sample the agent will use: 30 meters per segment, in one query
SELECT segment, profile, count() AS meters
FROM (SELECT segment, profile FROM gold.meter_profile ORDER BY cityHash64(meter_id) LIMIT 30 BY segment)
GROUP BY segment, profile
ORDER BY segment, profile;
-- Measured: 4 ms · 19,999 rows read (195.4 KB)
-- What to look for: LIMIT 30 BY segment keeps 30 rows per segment value.
-- The C5 segment mixes households and small professionals.


-- CHECKPOINT MODULE 5 (4/4)
--  One row per meter from the JSON files (20,000, or 19,999 if module 7 has already
--  deleted a meter), with 24 values per shape.
SELECT
    if((SELECT count() FROM gold.meter_profile) >= 19999, 'OK', 'FAIL') AS shapes,
    if((SELECT min(length(weekday_shape)) FROM gold.meter_profile) = 24, 'OK', 'FAIL') AS length_24
SETTINGS select_sequential_consistency = 1;
