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


-- STEP 1 · The municipality dictionary (text key: COMPLEX_KEY_HASHED)
--  SOURCE says where to read the data, LAYOUT how to store it in memory,
--  LIFETIME when to reload it. In Cloud, the CLICKHOUSE source must declare
--  a user: we use dict_reader, which is read-only (module 1).
CREATE OR REPLACE DICTIONARY ref.dict_municipality
(
    insee_code   String,
    name          String,
    dept_code    String,
    region_code  String,
    epci_code    String,
    population   UInt32
)
PRIMARY KEY insee_code
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'municipality' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 3600 MAX 7200);          -- reloaded every 1 to 2 hours


-- STEP 2 · The meter dictionary (numeric key: HASHED, the fastest)
CREATE OR REPLACE DICTIONARY ref.dict_meter
(
    meter_id         UInt64,
    insee_code     String,
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

--  EPCI and department labels
CREATE OR REPLACE DICTIONARY ref.dict_epci (epci_code String, name String)
PRIMARY KEY epci_code
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'epci' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED()) LIFETIME(86400);

CREATE OR REPLACE DICTIONARY ref.dict_department (dept_code String, name String, region_code String)
PRIMARY KEY dept_code
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'department' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED()) LIFETIME(86400);


-- STEP 4 · Usage: one meter, its full profile, in one row
--  The dictGets chain together: meter → municipality → department. No JOIN.
SELECT
    sim_meter_id(42)                                                              AS meter_id,
    dictGet('ref.dict_meter', 'segment', meter_id)                                  AS segment,
    dictGet('ref.dict_meter', 'power_kva', meter_id)                            AS kva_current,
    dictGet('ref.dict_meter', 'insee_code', meter_id)                               AS insee_code,
    dictGet('ref.dict_municipality', 'name', insee_code)                              AS municipality,
    dictGet('ref.dict_department', 'name', dictGet('ref.dict_municipality', 'dept_code', insee_code)) AS department,
    dictGet('ref.dict_epci', 'name', dictGet('ref.dict_municipality', 'epci_code', insee_code))       AS epci;
-- Measured: 3 ms · 1 row read


-- STEP 5 · Power that changes over time
--  Take a meter whose power changed in October
SELECT meter_id, valid_from, valid_to, power_kva
FROM ref.meter_history
WHERE meter_id IN (SELECT meter_id FROM ref.meter_history WHERE valid_to = '2026-10-14' LIMIT 1)
ORDER BY valid_from;
-- Measured: 9 ms · 991,232 rows read (9.5 MB)

SELECT
    day,
    dictGet('ref.dict_power_asof', 'power_kva', p.meter_id, day) AS kva_at_date
FROM (SELECT meter_id FROM ref.meter_history WHERE valid_to = '2026-10-14' LIMIT 1) AS p
CROSS JOIN (SELECT toDate('2026-10-12') + number AS day FROM numbers(5)) AS j;
-- Measured: 8 ms · 983,045 rows read (9.4 MB)
-- What to look for: on the 15th, the new power applies. Essential for the
-- overrun alerts in module 5.


-- STEP 6 · Dictionary vs JOIN: same result, compare the timings
--  Energy for the month by department. sum(value_w) * 0.5: an average power
--  over a half-hour × 0.5 h = an energy in Wh.
SELECT
    dictGet('ref.dict_municipality', 'dept_code', dictGet('ref.dict_meter', 'insee_code', meter_id)) AS dept,
    round(sum(value_w) * 0.5 / 1e6) AS mwh
FROM silver.load_curve
WHERE quantity = 'CONS'
GROUP BY dept
ORDER BY mwh DESC
LIMIT 10;
-- Measured: 271 ms · 29.8 M rows read (369.5 MB) · 174.9 MB of memory

SELECT
    c.dept_code AS dept,
    round(sum(s.value_w) * 0.5 / 1e6) AS mwh
FROM silver.load_curve AS s
INNER JOIN ref.meter     AS p ON p.meter_id = s.meter_id
INNER JOIN ref.municipality AS c ON c.insee_code = p.insee_code
WHERE s.quantity = 'CONS'
GROUP BY dept
ORDER BY mwh DESC
LIMIT 10;
-- Measured: 282 ms · 30.8 M rows read (385.1 MB) · 282.1 MB of memory
-- What to look for: same result. Compare duration and memory at the bottom of the console:
-- the JOIN must first load ref.meter and ref.municipality into memory, the dictionary does not.


-- STEP 7 · Quality: are there meters missing from the reference data?
--  dictHas returns 0 if the key is absent: a quality check in one line.
SELECT count() AS unknown_meter_points
FROM silver.load_curve
WHERE NOT dictHas('ref.dict_meter', meter_id);
-- Measured: 22 ms · 31 M rows read (236.8 MB)


-- STEP 8 · What it costs in memory
--  What to look for: a few tens of MB for 1 million meters. The "as of"
--  dictionary is bigger because it stores intervals per key.
SELECT name, status, type, element_count, formatReadableSize(bytes_allocated) AS memory, loading_duration
FROM system.dictionaries
WHERE database = 'ref';


-- GOING FURTHER · Fuzzy address matching (the BAN national address database case)
--  ngramDistance measures how similar two texts are (0 = identical):
--  it finds "Rueil-Malmaison" despite the typo.
SELECT name, insee_code, round(ngramDistanceCaseInsensitiveUTF8(replaceAll(name, '-', ' '), 'Rueil Malmaizon'), 3) AS distance
FROM ref.municipality
ORDER BY distance ASC
LIMIT 3;
-- Measured: 9 ms · 61,746 rows read (995.3 KB)


-- CHECKPOINT
SELECT
    if((SELECT element_count FROM system.dictionaries WHERE database = 'ref' AND name = 'dict_meter') = 1000000, 'OK', 'FAIL') AS dict_meter,
    if((SELECT status FROM system.dictionaries WHERE database = 'ref' AND name = 'dict_power_asof') = 'LOADED', 'OK', 'FAIL') AS dict_asof,
    if(dictGet('ref.dict_municipality', 'name', '92063') = 'Rueil-Malmaison', 'OK', 'FAIL') AS dict_municipality
SETTINGS select_sequential_consistency = 1;   -- read the latest version, whichever replica serves it
