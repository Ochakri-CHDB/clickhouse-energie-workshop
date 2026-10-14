-- =====================================================================
--  MODULE 2 · Exploring the raw JSON, without loading it anywhere else
-- =====================================================================


-- STEP 1 · JSON functions read the text directly
--  JSONExtract* walks through the text at read time, with no preparation at all.
--  Handy for exploring, but every query re-parses the whole JSON:
--  that is why we move to silver, with typed columns.
SELECT
    file_name,
    JSONExtractString(payload, 'header', 'flowCode')        AS source_flow_code,
    JSONExtractString(payload, 'header', 'recipientId')  AS recipient,
    JSONLength(payload, 'measurements')                          AS n_measurements
FROM bronze.raw_flows
WHERE flow_code = 'CURVE'
LIMIT 5;
-- Measured: 80 ms · 64 files read (148.1 MB of JSON) · 316.2 MB of memory


-- STEP 2 · The native JSON type: ClickHouse discovers the structure on its own
--  payload::JSON converts the text to the JSON type: each path becomes
--  a typed subcolumn. Useful when the schema changes often (rule
--  schema-json-when-to-use). Here the source format is stable: we will prefer
--  regular columns in silver.
SELECT JSONAllPathsWithTypes(payload::JSON) AS detected_structure
FROM bronze.raw_flows
WHERE flow_code = 'PMAX'
LIMIT 1;
-- Measured: 215 ms · 600 files read (144.9 MB of JSON) · 406.1 MB of memory

--  You navigate with dots, like in JavaScript.
--  .:`Array(JSON)` states the expected type for an array of objects.
SELECT
    j.header.flowCode                                        AS flow_code,
    arrayJoin(j.measurements.:`Array(JSON)`).meterId                AS meter_id
FROM (SELECT payload::JSON AS j FROM bronze.raw_flows WHERE flow_code = 'PMAX' LIMIT 1)
LIMIT 5;
-- Measured: 75 ms · 600 files read (144.9 MB of JSON) · 406.2 MB of memory


-- STEP 3 · Typed extraction: the key to moving to silver
--  We describe the expected shape, ClickHouse fills it in a single pass.
--  Then two ARRAY JOINs unfold the arrays: file → measurements → quantities.
--  This is exactly the query the materialized view will run in module 3.
SELECT
    m.meterId, m.stage, g.businessQuantity, length(g.points) AS n_points
FROM
(
    SELECT JSONExtract(payload, 'measurements',
        'Array(Tuple(meterId String, stage String, quantity Array(Tuple(businessQuantity String, points Array(Tuple(d String, v String))))))') AS measurements
    FROM bronze.raw_flows
    WHERE flow_code = 'CURVE'
    LIMIT 1
)
ARRAY JOIN measurements AS m
ARRAY JOIN m.quantity AS g
LIMIT 10;
-- Measured: 21 ms · 64 files read (148.1 MB of JSON) · 305.8 MB of memory


-- STEP 4 · How much do our INSERTs cost? (the query log)
--  system.query_log keeps one row per query: duration, rows, memory.
--  In Cloud, each replica has its own log: clusterAllReplicas()
--  queries all of them.
SELECT
    event_time,
    query_duration_ms / 1000                       AS seconds,
    written_rows                                   AS files_written,
    formatReadableSize(written_bytes)              AS written_size,
    formatReadableSize(memory_usage)               AS max_memory,
    substring(query, position(query, 'FROM numbers'), 30) AS insert_range
FROM clusterAllReplicas('default', system.query_log)
WHERE type = 'QueryFinish'
  AND query_kind = 'Insert'
  AND has(tables, 'bronze.raw_flows')
  AND event_date = today()
ORDER BY event_time;
-- What to look for: the peak memory of each INSERT. It stays around
-- 2 GB because max_block_size = 2 only keeps 2 files in memory at a time.
