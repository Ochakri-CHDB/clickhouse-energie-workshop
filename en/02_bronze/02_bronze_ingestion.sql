-- =====================================================================
--  MODULE 2 · Bronze: the JSON files as they arrive
-- =====================================================================
--  Golden rule of bronze: store the raw data, transform nothing.
--  One row = one received file (1000 meters, 1 day).
--  Volume: 20,000 meters × 31 days, flows CURVE (30-min curves), ENERGY (daily energy), PMAX (max power)
--  Recipients: the 6 metropolitan areas (12 batches for Grand Paris, 2 for Lyon…)
--
--  Why keep the raw data? If a parsing rule changes or a bug is
--  fixed, everything can be rebuilt from bronze (module 7), without asking
--  the distribution system operator for the files again.
-- =====================================================================


-- STEP 1 · The bronze table
CREATE OR REPLACE TABLE bronze.raw_flows
(
    file_name    String,
    flow_code    LowCardinality(String),        -- CURVE / ENERGY / PMAX
    ingested_at  DateTime64(3, 'UTC'),          -- arrival time of the file
    payload      String CODEC(ZSTD(3))          -- the raw JSON. ZSTD(3) compresses harder than the default (LZ4): ideal for rarely re-read text
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ingested_at)              -- one partition per month: few of them, easy to purge (TTL, module 7)
ORDER BY (flow_code, ingested_at, file_name);   -- bronze is re-read by flow, then by arrival date


-- STEP 2 · A single day of CURVE load curves (20 files, ~1 million points)
--  What the query does, from the inside out:
--    numbers(0, 20)   → 20 files (batches of 1000 meters)
--    dictGet          → profile, power, solar panels of each meter
--    arrayMap         → for each meter, its 48 points of the day
--    CAST + toJSONString → the final JSON file, with the field names of the source format
INSERT INTO bronze.raw_flows
WITH
    toDate('2026-10-01') + intDiv(number, 20)                                  AS day,
    number % 20                                                                 AS batch,
    -- arrival: the next day between 6am and 8am, except ~1% of late files (in the afternoon)
    toDateTime64(toDateTime(day + 1, 'Europe/Paris'), 3, 'UTC')
        + toIntervalSecond(if(sim_random(day, batch, 'retard') < 0.01, 50400, 21600 + batch * 300 + cityHash64(day, batch) % 240)) AS arrival,
    sim_day_points(day)                                                    AS timestamps,
    -- ~0.3% of meters sent nothing that day (communication failure)
    arrayFilter(n -> sim_random(n, day, 'panne') >= 0.003, range(batch * 1000, batch * 1000 + 1000)) AS ns,
    arrayMap(n -> sim_meter_id(n), ns)                                            AS ids,
    arrayMap(id -> dictGet('simulator.dict_meter', ('profile', 'power_kva', 'pv_kwp', 'dept_code'), id), ids) AS attrs
SELECT
    concat('DSO_CURVE_30MIN_PUB_', toString(100000 + number), '_', sim_recipient(batch), '_', formatDateTime(arrival, '%Y%m%d%H%i%S'), '.zip') AS file_name,
    'CURVE'   AS flow_code,
    arrival AS ingested_at,
    toJSONString(CAST((
        ('DATA PORTAL', 'LOCAL_AUTHORITY', sim_recipient(batch), 'CURVE30', toString(100000 + number), 'RECURRING', 'JSON'),
        arrayMap((id, a) -> (
            leftPad(toString(id), 14, '0'),
            'RAW',
            (toString(day), toString(day + 1)),
            'PT30M',
            arrayConcat(
                -- consumption: ~0.02% missing points, ~0.03% empty values (rejects)
                [('PA', 'CONS', 'W',
                  arrayMap(t -> (sim_iso(t), if(sim_random(id, t, 'ko') < 0.0003, '', toString(sim_cons_w(id, a.1, a.2, t)))),
                           arrayFilter(t -> sim_random(id, t, 'trou') >= 0.0002, timestamps)))],
                -- production, only for meters with solar panels
                if(a.3 > 0,
                   [('PA', 'PROD', 'W', arrayMap(t -> (sim_iso(t), toString(sim_prod_w(id, a.4, a.3, t))), timestamps))],
                   []))
        ), ids, attrs)
    ), 'Tuple(header Tuple(requester String, recipientType String, recipientId String, flowCode String, publicationId String, publicationMode String, format String),
              measurements Array(Tuple(meterId String, stage String, period Tuple(startDate String, endDate String), step String,
                                  quantity Array(Tuple(physicalQuantity String, businessQuantity String, unit String,
                                                       points Array(Tuple(d String, v String)))))))')) AS payload
FROM numbers(0, 20)
SETTINGS max_block_size = 2;   -- 2 files per block: each file weighs ~2 MB of JSON, we keep memory low
-- Measured: 697 ms · 20 JSON files generated and written (46 MB) · 208.5 MB of memory

--  What did we receive? length() gives the size of the JSON in bytes.
SELECT flow_code, count() AS files, formatReadableSize(sum(length(payload))) AS json_volume
FROM bronze.raw_flows
GROUP BY flow_code;
-- Measured: 6 ms · 20 rows read

--  A file, exactly as it was received
SELECT file_name, ingested_at, substring(payload, 1, 600) AS json_start
FROM bronze.raw_flows
LIMIT 1;
-- Measured: 13 ms · 5 rows read (11.5 MB)


-- STEP 3 · The rest of the month: days 2 to 30 (580 files, ~28 million points)
--  The query from step 2 is stored in a PARAMETERIZED VIEW (simulator.curve_files).
--  You call it like a function. Day 31 is kept for module 3.
--  A single INSERT of 580 files rather than 580 small INSERTs: each INSERT
--  creates a part, and a few large parts are cheaper to merge
--  (rule insert-batch-size).
INSERT INTO bronze.raw_flows
SELECT * FROM simulator.curve_files(start = 20, n = 580)
SETTINGS max_block_size = 2;
-- Measured: 11.32 s · 580 files generated and written (1.30 GB of JSON) · 2.2 GB of memory
-- What to look for: the duration covers generating AND writing ~1.3 GB of JSON.


-- STEP 4 · The daily flows: ENERGY (energy) and PMAX (max power)
INSERT INTO bronze.raw_flows
SELECT * FROM simulator.energy_files(start = 0, n = 600)
SETTINGS max_block_size = 4;
-- Measured: 3.51 s · 600 ENERGY files (168 MB of JSON) · 769.9 MB of memory

INSERT INTO bronze.raw_flows
SELECT * FROM simulator.pmax_files(start = 0, n = 600)
SETTINGS max_block_size = 4;
-- Measured: 5.39 s · 600 PMAX files (145 MB of JSON) · 445.6 MB of memory


-- STEP 5 · Ingestion summary
SELECT
    flow_code,
    count()                                                        AS files,
    min(ingested_at)                                               AS first_seen,
    max(ingested_at)                                               AS last_seen,
    formatReadableSize(sum(length(payload)))                       AS raw_json
FROM bronze.raw_flows
GROUP BY flow_code
ORDER BY flow_code;
-- Measured: 58 ms · 1,800 rows read (29.9 KB)

--  How much does it really weigh on disk? (ZSTD compression of the JSON)
--  What to look for: the JSON is very repetitive (same keys, same dates): it
--  compresses by a factor of 10 to 15.
SELECT
    formatReadableSize(sum(data_uncompressed_bytes))                 AS raw,
    formatReadableSize(sum(data_compressed_bytes))                   AS on_disk,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes)) AS ratio
FROM system.parts
WHERE database = 'bronze' AND table = 'raw_flows' AND active;

--  The parts created by our INSERTs
--  The name of a part (202610_0_5_1) gives the partition, the block range and the
--  merge level. Rerun the query in a minute: background merges
--  will have reduced their number.
SELECT partition, name, rows, formatReadableSize(bytes_on_disk) AS size, modification_time
FROM system.parts
WHERE database = 'bronze' AND table = 'raw_flows' AND active
ORDER BY modification_time;


-- CHECKPOINT MODULE 2
--  600 files per flow: 20 batches × 30 days (day 31 arrives in module 3).
SELECT
    if(countIf(flow_code = 'CURVE') = 600, 'OK', 'FAIL') AS curve_600_files,
    if(countIf(flow_code = 'ENERGY') = 600, 'OK', 'FAIL') AS energy_600_files,
    if(countIf(flow_code = 'PMAX') = 600, 'OK', 'FAIL') AS pmax_600_files
FROM bronze.raw_flows
SETTINGS select_sequential_consistency = 1;   -- read the latest version, whatever the replica
