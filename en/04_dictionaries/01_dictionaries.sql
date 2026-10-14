-- =====================================================================
--  MODULE 4 · Dictionaries: reference data in memory
-- =====================================================================
--  A dictionary = a key → values table loaded into RAM.
--  dictGet() replaces a join: an O(1) lookup per row.
--  Why is it better than a repeated JOIN? A JOIN rebuilds a hash table
--  on EVERY query. The dictionary builds it once, keeps it in memory
--  and reloads it according to LIFETIME (rule query-join-use-dictionaries).
--  It does not use the query's memory, which protects large scans.
-- =====================================================================


-- STEP 1 · The ward dictionary (text key: COMPLEX_KEY_HASHED)
--  SOURCE says where to read the data, LAYOUT how to store it in memory,
--  LIFETIME when to reload it. In Cloud, the CLICKHOUSE source must declare
--  a user: we use dict_reader, which is read-only (module 1).
CREATE OR REPLACE DICTIONARY ref.dict_ward
(
    ward_code   String,
    name          String,
    district_code    String,
    region_code  String,
    metro_code    String,
    population   UInt32
)
PRIMARY KEY ward_code
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'ward' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 3600 MAX 7200);          -- reloaded every 1 to 2 hours


-- STEP 2 · The meter dictionary (numeric key: HASHED, the fastest)
CREATE OR REPLACE DICTIONARY ref.dict_meter
(
    meter_id         UInt64,
    ward_code     String,
    segment        String,
    profile         String,
    power_kva  UInt16,
    tariff          String,
    pv_kwp         Float32
)
PRIMARY KEY meter_id
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'meter' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(HASHED_ARRAY())                -- a HASHED variant, leaner when there are many attributes
LIFETIME(MIN 3600 MAX 7200);


-- STEP 3 · Subscribed power "as of" a date (RANGE_HASHED)
--  For a key AND a date, it finds the row that was valid at that moment.
--  Exactly what we need to compare a PMax with the subscribed power
--  on the day of the measurement, not with the current power.
CREATE OR REPLACE DICTIONARY ref.dict_power_asof
(
    meter_id         UInt64,
    valid_from     Date,
    valid_to       Date,
    power_kva  UInt16
)
PRIMARY KEY meter_id
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'meter_history' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(RANGE_HASHED())
RANGE(MIN valid_from MAX valid_to)
LIFETIME(MIN 3600 MAX 7200);

--  Labels for metro areas (combined authorities and Greater London) and districts
CREATE OR REPLACE DICTIONARY ref.dict_metro (metro_code String, name String)
PRIMARY KEY metro_code
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'metro' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED()) LIFETIME(86400);

CREATE OR REPLACE DICTIONARY ref.dict_district (district_code String, name String, region_code String)
PRIMARY KEY district_code
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'district' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED()) LIFETIME(86400);


-- STEP 4 · Usage: one meter, its full profile, in one row
--  The dictGets chain together: meter → ward → district. No JOIN.
SELECT
    sim_meter_id(42)                                                              AS meter_id,
    dictGet('ref.dict_meter', 'segment', meter_id)                                  AS segment,
    dictGet('ref.dict_meter', 'power_kva', meter_id)                            AS kva_current,
    dictGet('ref.dict_meter', 'ward_code', meter_id)                               AS ward_code,
    dictGet('ref.dict_ward', 'name', ward_code)                              AS ward,
    dictGet('ref.dict_district', 'name', dictGet('ref.dict_ward', 'district_code', ward_code)) AS district,
    dictGet('ref.dict_metro', 'name', dictGet('ref.dict_ward', 'metro_code', ward_code))       AS metro;
-- Measured: 3 ms · 1 row read


-- STEP 5 · Power that changes over time
--  Take a meter whose power changed in October
SELECT meter_id, valid_from, valid_to, power_kva
FROM ref.meter_history
WHERE meter_id IN (SELECT meter_id FROM ref.meter_history WHERE valid_to = '2026-10-14' ORDER BY meter_id LIMIT 1)
ORDER BY valid_from;
-- Measured: 8 ms · 991,232 rows read (9.5 MB)

SELECT
    day,
    dictGet('ref.dict_power_asof', 'power_kva', p.meter_id, day) AS kva_at_date
FROM (SELECT meter_id FROM ref.meter_history WHERE valid_to = '2026-10-14' ORDER BY meter_id LIMIT 1) AS p
CROSS JOIN (SELECT toDate('2026-10-12') + number AS day FROM numbers(5)) AS j;
-- Measured: 8 ms · 983,045 rows read (9.4 MB)
-- What to look for: on the 15th, the new power applies. Essential for the
-- overrun alerts in module 5.


-- STEP 6 · Dictionary vs JOIN: same result, compare the timings
--  Energy for the month by district. sum(value_w) * 0.5: an average power
--  over a half-hour × 0.5 h = an energy in Wh.
SELECT
    dictGet('ref.dict_ward', 'district_code', dictGet('ref.dict_meter', 'ward_code', meter_id)) AS district_code,
    round(sum(value_w) * 0.5 / 1e6) AS mwh
FROM silver.load_curve
WHERE quantity = 'CONS'
GROUP BY district_code
ORDER BY mwh DESC
LIMIT 10;
-- Measured: 348 ms · 29.8 M rows read (369.6 MB) · 204.8 MB memory

SELECT
    c.district_code AS district_code,
    round(sum(s.value_w) * 0.5 / 1e6) AS mwh
FROM silver.load_curve AS s
INNER JOIN ref.meter     AS p ON p.meter_id = s.meter_id
INNER JOIN ref.ward AS c ON c.ward_code = p.ward_code
WHERE s.quantity = 'CONS'
GROUP BY district_code
ORDER BY mwh DESC
LIMIT 10;
-- Measured: 262 ms · 30.8 M rows read (388.8 MB) · 279.3 MB memory
-- What to look for: same result (Birmingham, E08000025, first with 812 MWh). Compare duration and
-- memory at the bottom of the console: the JOIN must first load ref.meter and ref.ward into memory,
-- the dictionary does not (205 MB vs 279 MB here). On this small table the timings are close.


-- STEP 7 · Quality: are there meters missing from the reference data?
--  dictHas returns 0 if the key is absent: a quality check in one line.
SELECT count() AS unknown_meter_points
FROM silver.load_curve
WHERE NOT dictHas('ref.dict_meter', meter_id);
-- Measured: 22 ms · 31 M rows read (236.8 MB)


-- STEP 8 · What it costs in memory
--  What to look for: about 100 MB for 1 million meters, 4 MB for the 7,588 wards. The "as of"
--  dictionary is bigger (about 345 MB) because it stores intervals per key.
SELECT name, status, type, element_count, formatReadableSize(bytes_allocated) AS memory, loading_duration
FROM system.dictionaries
WHERE database = 'ref';


-- GOING FURTHER · Fuzzy matching of a typed place name against the reference data
--  ngramDistance measures how similar two texts are (0 = identical):
--  it finds "Shepherd's Bush Green" despite the typo.
SELECT name, ward_code, round(ngramDistanceCaseInsensitiveUTF8(replaceAll(name, '-', ' '), 'Shepherds Bush Gren'), 3) AS distance
FROM ref.ward
ORDER BY distance ASC
LIMIT 3;
-- Measured: 4 ms · 15,176 rows read (274.2 KB)
-- What to look for: Shepherd's Bush Green (E05013748) first at 0.222, the next one above 0.67.


-- CHECKPOINT
SELECT
    if((SELECT element_count FROM system.dictionaries WHERE database = 'ref' AND name = 'dict_meter') = 1000000, 'OK', 'FAIL') AS dict_meter,
    if((SELECT status FROM system.dictionaries WHERE database = 'ref' AND name = 'dict_power_asof') = 'LOADED', 'OK', 'FAIL') AS dict_asof,
    if(dictGet('ref.dict_ward', 'name', 'E05013748') = 'Shepherd''s Bush Green', 'OK', 'FAIL') AS dict_ward
SETTINGS select_sequential_consistency = 1;   -- read the latest version, whichever replica serves it
