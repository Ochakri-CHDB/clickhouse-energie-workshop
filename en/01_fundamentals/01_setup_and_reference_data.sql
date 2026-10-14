-- =====================================================================
--  MODULE 1 · Fundamentals: databases, MergeTree and reference data
-- =====================================================================
--  We create the 4 layers of the pipeline and the reference data:
--    ref     → wards (real ONS data, England and Wales), meters, local authorities
--    bronze  → raw JSON files, as received
--    silver  → typed, cleaned, deduplicated measurements
--    gold    → KPIs ready for the dashboards
--
--  A ClickHouse "database" is just a namespace: it costs nothing
--  and is used to organize tables and to grant rights per layer.
-- =====================================================================


-- STEP 1 · The databases (one per layer)
CREATE DATABASE IF NOT EXISTS ref;
CREATE DATABASE IF NOT EXISTS bronze;
CREATE DATABASE IF NOT EXISTS silver;
CREATE DATABASE IF NOT EXISTS gold;
CREATE DATABASE IF NOT EXISTS simulator;   -- the workshop's data generator


-- STEP 2 · A technical user for the dictionaries (module 4)
--  In the Cloud console, a dictionary that reads a local table
--  must declare a user and a password. We keep it limited:
--  local connection only, read-only on the reference data.
CREATE USER IF NOT EXISTS dict_reader IDENTIFIED BY 'Dict_Workshop_2026!' HOST LOCAL;
GRANT SELECT ON ref.* TO dict_reader;
GRANT SELECT ON simulator.* TO dict_reader;


-- STEP 3 · Wards of England and Wales, read LIVE from official open data
--  url() reads an HTTP resource as a table. The CSVWithNames format tells
--  ClickHouse how to split the response: one line = one row, the header gives the columns.
--  The database reads the resource itself, inside the query. Three public sources, no key:
--    · ONS Open Geography Portal: the ward → district → region hierarchy (May 2025)
--      and the centroid of each ward (longitude, latitude)
--    · Nomis (ONS): the population of each ward, mid-2024 estimate
--    · ONS combined authority lookup: which district belongs to which combined authority
--  Three levels of geography:
--    · ward: the smallest electoral area (about 8,000 residents), with a real name and a population;
--    · district: the local authority (council) that groups wards, 318 in England and Wales;
--    · combined authority: several districts pooling transport and energy policy
--      (Greater Manchester, West Midlands...). London has its own equivalent, the GLA.
SELECT *
FROM url('https://hub.arcgis.com/api/v3/datasets/7315ebba66154363806867bcfd52417a_0/downloads/data?format=csv&spatialRefId=4326&where=1%3D1', CSVWithNames)
LIMIT 5;
-- Measured: 2.86 s · 9 rows read (1.2 KB)


-- STEP 4 · Our first MergeTree table
--  MergeTree is the core ClickHouse engine. Two things to remember:
--    · ORDER BY sets the physical order of rows on disk AND the primary
--      index. It cannot be changed later: choose it from the most
--      frequent filters (rule schema-pk-plan-before-creation).
--    · each column is stored and compressed separately (columnar storage):
--      a query only reads the columns it uses.
CREATE OR REPLACE TABLE ref.ward
(
    ward_code      String,                   -- ONS code, e.g. E05013748
    name           String,
    district_code  LowCardinality(String),   -- ~300 distinct values: stored once, then as numbers (rule: fewer than 10,000 values)
    region_code    LowCardinality(String),
    metro_code     String,                   -- combined authority, '' outside (rule schema-types-avoid-nullable)
    population     UInt32,                   -- the smallest integer type that fits
    lon            Float32,
    lat            Float32
)
ENGINE = MergeTree
ORDER BY ward_code;

--  The structure of each source is declared: only the useful columns are read.
--  Wales has no region in the ONS hierarchy: the country code takes its place.
--  London is not a combined authority: its 33 boroughs form the Greater London
--  Authority (code E61000001), which plays the same role here.
INSERT INTO ref.ward
WITH
    hierarchy AS
    (
        SELECT WD25CD, WD25NM, LAD25CD, if(RGN25CD = '', CTRY25CD, RGN25CD) AS rgn
        FROM url('https://hub.arcgis.com/api/v3/datasets/7315ebba66154363806867bcfd52417a_0/downloads/data?format=csv&spatialRefId=4326&where=1%3D1',
                 CSVWithNames, 'WD25CD String, WD25NM String, LAD25CD String, RGN25CD String, CTRY25CD String')
        WHERE CTRY25CD IN ('E92000001', 'W92000004')   -- England and Wales
    ),
    centroid AS
    (
        SELECT WD25CD, LONG, LAT
        FROM url('https://hub.arcgis.com/api/v3/datasets/6ba7cf950a504d82809131c945fe70f1_0/downloads/data?format=csv&spatialRefId=4326&where=1%3D1',
                 CSVWithNames, 'WD25CD String, LONG Float64, LAT Float64')
    ),
    pop AS
    (
        SELECT GEOGRAPHY_CODE, OBS_VALUE
        FROM url('https://www.nomisweb.co.uk/api/v01/dataset/NM_2014_1.data.csv?date=latest&geography=TYPE182&gender=0&c_age=200&measures=20100&select=geography_code,obs_value',
                 CSVWithNames, 'GEOGRAPHY_CODE String, OBS_VALUE UInt32')
    ),
    metro AS
    (
        SELECT LAD25CD, CAUTH25CD
        FROM url('https://hub.arcgis.com/api/v3/datasets/ba77701e67bd4f3e80a97fb9a5fd4885_0/downloads/data?format=csv&spatialRefId=4326&where=1%3D1',
                 CSVWithNames, 'LAD25CD String, CAUTH25CD String')
    )
SELECT h.WD25CD, h.WD25NM, h.LAD25CD, h.rgn,
       if(h.rgn = 'E12000007', 'E61000001', m.CAUTH25CD),
       p.OBS_VALUE, c.LONG, c.LAT
FROM hierarchy AS h
LEFT JOIN centroid AS c ON c.WD25CD = h.WD25CD
LEFT JOIN pop      AS p ON p.GEOGRAPHY_CODE = h.WD25CD
LEFT JOIN metro    AS m ON m.LAD25CD = h.LAD25CD
SETTINGS join_use_nulls = 0;   -- a missing match gives '' or 0, not NULL
-- Measured: 5.53 s · 24,488 rows read (2.6 MB) · 7,588 rows written
--  Plan B if a source does not answer: the same table is in the repo
--  INSERT INTO ref.ward SELECT * FROM url('https://raw.githubusercontent.com/Ochakri-CHDB/clickhouse-energie-workshop/main/data/uk/wards.csv', CSVWithNames);

CREATE OR REPLACE TABLE ref.district (district_code String, name String, region_code String) ENGINE = MergeTree ORDER BY district_code;
INSERT INTO ref.district SELECT DISTINCT LAD25CD, LAD25NM, if(RGN25CD = '', CTRY25CD, RGN25CD)
FROM url('https://hub.arcgis.com/api/v3/datasets/7315ebba66154363806867bcfd52417a_0/downloads/data?format=csv&spatialRefId=4326&where=1%3D1',
         CSVWithNames, 'LAD25CD String, LAD25NM String, RGN25CD String, CTRY25CD String')
WHERE CTRY25CD IN ('E92000001', 'W92000004');
-- Measured: 611 ms · 8,405 rows read (1 MB) · 318 rows written

CREATE OR REPLACE TABLE ref.region (region_code String, name String) ENGINE = MergeTree ORDER BY region_code;
INSERT INTO ref.region SELECT DISTINCT if(RGN25CD = '', CTRY25CD, RGN25CD), if(RGN25CD = '', CTRY25NM, RGN25NM)
FROM url('https://hub.arcgis.com/api/v3/datasets/7315ebba66154363806867bcfd52417a_0/downloads/data?format=csv&spatialRefId=4326&where=1%3D1',
         CSVWithNames, 'RGN25CD String, RGN25NM String, CTRY25CD String, CTRY25NM String')
WHERE CTRY25CD IN ('E92000001', 'W92000004');
-- Measured: 573 ms · 8,405 rows read (1 MB) · 10 rows written

CREATE OR REPLACE TABLE ref.metro (metro_code String, name String) ENGINE = MergeTree ORDER BY metro_code;
INSERT INTO ref.metro
SELECT CAUTH25CD, CAUTH25NM
FROM url('https://hub.arcgis.com/api/v3/datasets/6b0ebe015596484ebd81e372da32db46_0/downloads/data?format=csv&spatialRefId=4326&where=1%3D1',
         CSVWithNames, 'CAUTH25CD String, CAUTH25NM String')
UNION ALL
SELECT 'E61000001', 'Greater London Authority';
-- Measured: 900 ms · 16 rows read · 16 rows written

SELECT count() AS n_wards, sum(population) AS total_population FROM ref.ward;
-- Measured: 3 ms · 7,588 rows read (29.6 KB)
-- What to look for: 7,588 wards and 61.8 million inhabitants (England and Wales only:
-- Scotland and Northern Ireland are not in the Nomis estimates). 16 wards have 0 inhabitants:
-- the City of London wards, merged into one area in the estimates.


-- STEP 5 · The local authorities that receive the flows
--  Each file from the distribution system operator is addressed to a recipient (recipientId).
--  We link each one to its combined authority (or the GLA for London), so we can filter by territory.
CREATE OR REPLACE TABLE ref.recipient
(
    recipient_id String,
    name             String,
    metro_code       String
)
ENGINE = MergeTree
ORDER BY recipient_id;

INSERT INTO ref.recipient VALUES
    ('488903', 'Greater London Authority',                 'E61000001'),
    ('488904', 'West Midlands Combined Authority',         'E47000007'),
    ('488905', 'Greater Manchester Combined Authority',    'E47000001'),
    ('488906', 'West Yorkshire Combined Authority',        'E47000003'),
    ('488907', 'Liverpool City Region Combined Authority', 'E47000004'),
    ('488908', 'North East Combined Authority',            'E47000014');

--  The 20 files of a day (batches of 1000 meters) are split between the
--  6 metropolitan areas, Greater London taking the largest share (12 of 20). A local authority
--  receives ONLY the meters of its territory: we take this into account in the draw.
--  CREATE FUNCTION creates a SQL function (UDF): a named expression,
--  reusable in every query. Here: batch number → recipient.
CREATE OR REPLACE FUNCTION sim_recipient AS (batch) ->
    ['488903', '488903', '488903', '488903', '488903', '488903', '488903', '488903', '488903', '488903',
     '488903', '488903', '488904', '488904', '488905', '488905', '488906', '488906', '488907', '488908'][batch + 1];

SELECT sim_recipient(batch) AS recipient_id, count() AS batches, count() * 1000 AS meter
FROM (SELECT number AS batch FROM numbers(20))
GROUP BY recipient_id
ORDER BY recipient_id;
-- Measured: 3 ms · 20 rows read


-- STEP 6 · The meter fleet: 1 million generated meters
--  Each meter is linked to a ward, drawn at random in proportion to
--  its population. Trick: an ASOF JOIN on the cumulative population.
--    · the first 20,000 meters (the ones in the JSON files of module 2) are drawn
--      in the territory of their recipient metropolitan area;
--    · the other 980,000 across all of England and Wales (the scale-up of module 6).
--  The fleet itself is simulated (segments and tariff codes come from a typical distribution
--  fleet): ~98.7% C5 (≤ 36 kVA), ~1.1% C4 (36 to 250 kVA), ~0.2% C2 (HTA, medium voltage).
--  Households are mostly 6 and 9 kVA.
--
--  How the population-weighted draw works:
--    1. sort the wards and accumulate their population (window function);
--    2. each meter draws a "ticket" between 0 and the total population;
--    3. ASOF JOIN finds the FIRST ward whose cumulative value exceeds the ticket.
--  A populous ward covers a large cumulative interval: it gets drawn more often.
CREATE OR REPLACE TABLE ref.meter
(
    meter_id             UInt64,                  -- 14 digits fit in 8 bytes
    ward_code         String,
    segment            LowCardinality(String),  -- C5 / C4 / C2
    profile             LowCardinality(String),  -- RES (residential) / PRO (professional) / ENT (business)
    power_kva      UInt16,
    tariff              LowCardinality(String),
    pv_kwp             Float32,                 -- installed solar power (0 = no production)
    commissioning_date  Date
)
ENGINE = MergeTree
ORDER BY meter_id
SETTINGS min_bytes_for_wide_part = 0;   -- one column = one file, to read compression column by column (step 8)

INSERT INTO ref.meter
WITH
    zones AS
    (
        -- 'EW' = all of England and Wales, otherwise the metro_code of a recipient metropolitan area
        SELECT 'EW' AS zone, ward_code, population FROM ref.ward WHERE population > 0
        UNION ALL
        SELECT metro_code, ward_code, population FROM ref.ward
        WHERE population > 0 AND metro_code IN (SELECT metro_code FROM ref.recipient)
    ),
    cumulative AS
    (
        SELECT zone, ward_code,
               sum(population) OVER (PARTITION BY zone ORDER BY ward_code ROWS UNBOUNDED PRECEDING) AS cumulative_pop
        FROM zones
    ),
    zone_pop AS (SELECT zone, sum(population) AS pop FROM zones GROUP BY zone),
    draw AS
    (
        SELECT
            z.zone                                                    AS zone,
            n.number                                                  AS n,
            10000000000000 + n.number * 4093 + cityHash64(n.number) % 4093 AS meter_id,
            cityHash64(n.number, 'commune') % z.pop                    AS ticket,
            cityHash64(n.number, 'segment') % 1000                     AS r_seg,
            cityHash64(n.number, 'detail')  % 1000                     AS r_det,
            cityHash64(n.number, 'pv')      % 1000                     AS r_pv
        FROM numbers(1000000) AS n
        LEFT JOIN ref.recipient AS d ON d.recipient_id = if(n.number < 20000, sim_recipient(intDiv(n.number, 1000)), '')
        INNER JOIN zone_pop AS z ON z.zone = if(n.number < 20000, d.metro_code, 'EW')
    )
SELECT
    t.meter_id,
    c.ward_code,
    multiIf(t.r_seg < 987, 'C5', t.r_seg < 998, 'C4', 'C2')                         AS segment,
    multiIf(segment = 'C5' AND t.r_det < 880, 'RES', segment = 'C2', 'ENT', 'PRO')  AS profile,
    multiIf(profile = 'RES', multiIf(t.r_det % 100 < 4, 3, t.r_det % 100 < 44, 6, t.r_det % 100 < 77, 9,
                                    t.r_det % 100 < 90, 12, t.r_det % 100 < 95, 15, t.r_det % 100 < 98, 18,
                                    t.r_det % 100 < 99, 24, 36),                       -- 40% at 6 kVA, 33% at 9 kVA
            segment = 'C5', [9, 12, 18, 24, 36][1 + t.r_det % 5],
            segment = 'C4', 37 + t.r_det % 214,
            250 + t.r_det)                                                             AS power_kva,
    multiIf(segment = 'C5', ['BASE', 'BASE', 'BASE', 'HPHC', 'HPHC', 'TEMPO'][1 + t.r_det % 6],
            segment = 'C4', ['CU4', 'MU4'][1 + t.r_det % 2],
            'HTA5')                                                                     AS tariff,
    multiIf(profile = 'RES' AND t.r_pv < 40, toFloat32([3, 4.5, 6, 9][1 + t.r_pv % 4]),   -- ~4% of households have solar
            profile = 'PRO' AND t.r_pv < 50, toFloat32(9 + t.r_pv % 27),
            profile = 'ENT' AND t.r_pv < 30, toFloat32(100 + t.r_pv * 3),
            toFloat32(0))                                                               AS pv_kwp,
    toDate('1995-01-01') + cityHash64(t.n, 'date') % 11000                             AS commissioning_date
FROM draw AS t
ASOF JOIN cumulative AS c ON t.zone = c.zone AND t.ticket < c.cumulative_pop;   -- the 1st ward of the zone whose cumulative value exceeds the ticket
-- Measured: 535 ms · 1 M rows read (8 MB) · 1 M rows written · 140.3 MB memory

SELECT segment, profile, count() AS n_meters, round(avg(power_kva), 1) AS avg_kva, countIf(pv_kwp > 0) AS n_with_pv
FROM ref.meter
GROUP BY segment, profile
ORDER BY n_meters DESC;
-- Measured: 17 ms · 1 M rows read (4.1 MB) · 163.6 MB memory
-- What to look for: a million rows generated and joined in under a second.
-- countIf only counts the rows that match the condition: no need for CASE WHEN.

--  The 20,000 meters of the JSON files are indeed at their recipient:
SELECT d.name AS recipient, count() AS meter
FROM ref.meter AS p
INNER JOIN ref.ward     AS c ON c.ward_code = p.ward_code
INNER JOIN ref.recipient AS d ON d.metro_code = c.metro_code
WHERE p.meter_id < 10000000000000 + 20000 * 4093
GROUP BY recipient
ORDER BY meter DESC;
-- Measured: 7 ms · 32,170 rows read (619.4 KB)
-- What to look for: 12,000 meters in Greater London, 2,000 each in Greater Manchester,
-- West Midlands and West Yorkshire, 1,000 in Liverpool City Region and North East.


-- STEP 7 · The subscribed power history (for module 4)
--  ~3% of meters increased their power during October.
--  One row per validity period [valid_from, valid_to].
--  ARRAY JOIN "unfolds" an array: one row with a 2-element array
--  becomes 2 rows. It is the central tool for reading metering JSON (module 3).
CREATE OR REPLACE TABLE ref.meter_history
(
    meter_id         UInt64,
    valid_from     Date,
    valid_to       Date,
    power_kva  UInt16
)
ENGINE = MergeTree
ORDER BY (meter_id, valid_from);

INSERT INTO ref.meter_history
SELECT meter_id, valid_from, valid_to, power_kva
FROM
(
    SELECT
        meter_id,
        power_kva,
        commissioning_date,
        cityHash64(meter_id, 'chgt') % 100 < 3 AND power_kva >= 6 AS changed,   -- the customer increased their power
        toDate('2026-10-05') + cityHash64(meter_id, 'j') % 20 AS change_date
    FROM ref.meter
)
ARRAY JOIN
    if(changed, [commissioning_date, change_date], [commissioning_date])                         AS valid_from,
    if(changed, [change_date - 1, toDate('2099-12-31')], [toDate('2099-12-31')])              AS valid_to,
    if(changed, [toUInt16(if(power_kva <= 36, power_kva - 3, intDiv(power_kva * 2, 3))), power_kva], [power_kva]) AS power_kva;
-- Measured: 258 ms · 1 M rows read (11.4 MB) · 1 M rows written · 97.6 MB memory

SELECT count() AS row_count, uniqExact(meter_id) AS meter, countIf(valid_to < '2099-01-01') AS changes
FROM ref.meter_history;
-- Measured: 16 ms · 1 M rows read (9.8 MB) · 93.7 MB memory


-- STEP 8 · Under the hood: parts, compression, index
--  Each INSERT writes a "part": a small, immutable, already sorted set of files.
--  In the background, ClickHouse merges the parts together, hence the name
--  MergeTree. system.parts shows the actual state of the storage.
SELECT table, count() AS n_parts, sum(rows) AS row_count,
       formatReadableSize(sum(data_uncompressed_bytes)) AS raw,
       formatReadableSize(sum(data_compressed_bytes))   AS compressed,
       round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio
FROM system.parts
WHERE database = 'ref' AND active
GROUP BY table
ORDER BY row_count DESC;
-- Measured: 4 ms · 7 rows read

--  Compression column by column
--  Watch out: in Cloud, a part under 1 GB is "compact" (all the
--  columns in a single file) and its per-column sizes show as 0.
--  ref.meter is created with min_bytes_for_wide_part = 0 so we can read them here.
--  What to look for: the LowCardinality columns (segment, profile) compress
--  much better than free-text columns.
SELECT name, type,
       formatReadableSize(data_compressed_bytes)   AS compressed,
       formatReadableSize(data_uncompressed_bytes) AS raw,
       round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio
FROM system.columns
WHERE database = 'ref' AND table = 'meter'
ORDER BY data_compressed_bytes DESC;
-- Measured: 2 ms · 8 rows read

--  The sparse index: ClickHouse does not index every row, but one row out of
--  8192 (a "granule"). So the index fits in memory, even for billions
--  of rows. For a lookup, it finds the relevant granules and reads only those.
EXPLAIN indexes = 1
SELECT * FROM ref.meter WHERE meter_id = 10000000006899;
-- Measured: 1 ms · 12 rows read

--  Compare: filter on the key (fast) vs off the key (full scan)
SELECT * FROM ref.meter WHERE meter_id = 10000000006899;     -- filter on the key: 1 granule read
-- Measured: 4 ms · 8,192 rows read (64 KB)
SELECT count() FROM ref.meter WHERE ward_code = 'E05013748';  -- Shepherd's Bush Green, off the key: the whole table is read
-- Measured: 7 ms · 1 M rows read (11.4 MB)
-- What to look for: "rows read" at the bottom of the console. 8,192 rows read for the first one,
-- 1,000,000 for the second. On 1 B rows, the gap would be the same in proportion.


-- CHECKPOINT MODULE 1
--  Every column must show OK. A FAIL: rerun the file (it is idempotent).
SELECT
    if((SELECT count() FROM ref.ward) > 7000, 'OK', 'FAIL') AS wards,
    if((SELECT count() FROM ref.meter) = 1000000,   'OK', 'FAIL') AS meter,
    if((SELECT count() FROM ref.meter_history) > 1000000, 'OK', 'FAIL') AS history,
    if((SELECT count() FROM ref.recipient) = 6, 'OK', 'FAIL') AS recipients,
    if((SELECT count() FROM ref.meter AS p INNER JOIN ref.ward AS c ON c.ward_code = p.ward_code
        WHERE p.meter_id < 10000000000000 + 20000 * 4093
          AND c.metro_code IN (SELECT metro_code FROM ref.recipient)) = 20000, 'OK', 'FAIL') AS meters_at_recipient
SETTINGS select_sequential_consistency = 1;   -- read the latest version, whatever the replica
-- Measured: 76 ms · 32,175 rows read (619.3 KB)
