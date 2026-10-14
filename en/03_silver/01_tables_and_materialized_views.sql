-- =====================================================================
--  MODULE 3 · Silver: typed, clean, deduplicated measurements
-- =====================================================================
--  Bronze (1 row = 1 file)  ──MV──►  Silver (1 row = 1 point)
--  A materialized view (MV) is an INSERT TRIGGER: every block inserted
--  into bronze is transformed and written to silver, on the fly.
--  It never recomputes existing data: it only processes the new rows,
--  at INSERT time. You pay the cost once, at write time.
-- =====================================================================


-- STEP 1 · The load curve table
--  ReplacingMergeTree: for a given key (meter_id, quantity, ts), the row with
--  the most recent version wins. Perfect for resends and corrections.
--  The replacement happens during background merges, not at INSERT time:
--  in the meantime, both versions coexist on disk (we will see this in 03).
CREATE OR REPLACE TABLE silver.load_curve
(
    meter_id        UInt64,
    quantity      LowCardinality(String),                        -- CONS / PROD
    ts            DateTime('UTC')      CODEC(Delta, ZSTD(1)),    -- end of interval, in UTC. Delta stores the gap with the previous row (1800 s): almost nothing
    value_w      UInt32               CODEC(T64, ZSTD(1)),      -- average power in W. T64 strips the unused high-order bits
    step_min       UInt8,
    stage  LowCardinality(String),                        -- RAW / CORRECTED
    version       DateTime64(3, 'UTC') CODEC(Delta, ZSTD(1)),    -- file arrival: the most recent wins
    day          Date MATERIALIZED toDate(ts - 1, 'Europe/Paris') -- computed at insert: the local day (ts - 1 because 00:00 closes the previous day)
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(ts)                -- one partition per month: few of them, bounded
ORDER BY (quantity, meter_id, ts)          -- lowest to highest cardinality: 2 values, then the meter, then time
SETTINGS min_bytes_for_wide_part = 0;    -- one column = one file: we can read the compression per column


-- STEP 2 · The daily flows
--  Same principle: ReplacingMergeTree with the arrival date as the version.
CREATE OR REPLACE TABLE silver.daily_energy
(
    meter_id        UInt64,
    quantity      LowCardinality(String),
    day          Date,
    energy_wh    Decimal(18, 2),                                -- Decimal: no rounding error on sums
    stage  LowCardinality(String),
    version       DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(day)
ORDER BY (meter_id, quantity, day);

CREATE OR REPLACE TABLE silver.daily_pmax
(
    meter_id        UInt64,
    day          Date,
    pmax_va       UInt32,
    ts_pmax       DateTime('UTC'),
    version       DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(day)
ORDER BY (meter_id, day);

--  Rejects: nothing is lost, nothing is blocked
--  An unreadable value does not stop the load: it goes into this table,
--  with its source file, for analysis.
CREATE OR REPLACE TABLE silver.rejects
(
    ingested_at   DateTime64(3, 'UTC'),
    file_name     String,
    flow_code     LowCardinality(String),
    meter_id        String,
    ts_text    String,
    raw_value        String,
    reason         LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY (flow_code, ingested_at);


-- STEP 3 · The bronze → silver MV for curves (CURVE)
--  3 chained ARRAY JOINs: file → measurements → quantities → points.
--  A file of 1000 meters × 48 points thus produces ~48,000 silver rows.
--  "TO silver.load_curve": the MV writes into a table we created ourselves
--  (we keep control over the engine, the key and the codecs).
CREATE OR REPLACE MATERIALIZED VIEW silver.mv_curve TO silver.load_curve AS
SELECT
    toUInt64(m.meterId)                         AS meter_id,
    g.businessQuantity                          AS quantity,
    parseDateTimeBestEffort(p.d, 'UTC')       AS ts,                -- "+01:00" / "+02:00" → UTC
    toUInt32(p.v)                             AS value_w,
    toUInt8(extract(m.step, '\\d+'))           AS step_min,           -- 'PT30M' → 30
    m.stage                             AS stage,
    ingested_at                               AS version
FROM bronze.raw_flows
ARRAY JOIN JSONExtract(payload, 'measurements',
    'Array(Tuple(meterId String, stage String, step String, quantity Array(Tuple(businessQuantity String, points Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.quantity AS g
ARRAY JOIN g.points   AS p
WHERE flow_code = 'CURVE'
  AND toUInt32OrNull(p.v) IS NOT NULL;   -- toUInt32OrNull returns NULL instead of an error when the value is unreadable

--  A 2nd MV on the same source: it captures what the 1st one discards.
--  Several MVs can read the same table: each INSERT into bronze triggers all of them.
CREATE OR REPLACE MATERIALIZED VIEW silver.mv_curve_rejects TO silver.rejects AS
SELECT
    ingested_at, file_name, flow_code,
    m.meterId AS meter_id, p.d AS ts_text, p.v AS raw_value,
    'non-numeric value' AS reason
FROM bronze.raw_flows
ARRAY JOIN JSONExtract(payload, 'measurements',
    'Array(Tuple(meterId String, quantity Array(Tuple(points Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.quantity AS g
ARRAY JOIN g.points   AS p
WHERE flow_code = 'CURVE'
  AND toUInt32OrNull(p.v) IS NULL;


-- STEP 4 · The MVs for the daily flows (ENERGY, PMAX)
CREATE OR REPLACE MATERIALIZED VIEW silver.mv_daily_energy TO silver.daily_energy AS
SELECT
    toUInt64(m.meterId)                         AS meter_id,
    g.businessQuantity                          AS quantity,
    toDate(p.d)                               AS day,
    toDecimal64(p.v, 2)                       AS energy_wh,
    m.stage                             AS stage,
    ingested_at                               AS version
FROM bronze.raw_flows
ARRAY JOIN JSONExtract(payload, 'measurements',
    'Array(Tuple(meterId String, stage String, quantity Array(Tuple(businessQuantity String, points Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.quantity AS g
ARRAY JOIN g.points   AS p
WHERE flow_code = 'ENERGY';

CREATE OR REPLACE MATERIALIZED VIEW silver.mv_daily_pmax TO silver.daily_pmax AS
SELECT
    toUInt64(m.meterId)                         AS meter_id,
    toDate(m.period.startDate)               AS day,
    toUInt32(p.v)                             AS pmax_va,
    parseDateTimeBestEffort(p.d, 'UTC')       AS ts_pmax,
    ingested_at                               AS version
FROM bronze.raw_flows
ARRAY JOIN JSONExtract(payload, 'measurements',
    'Array(Tuple(meterId String, period Tuple(startDate String), quantity Array(Tuple(points Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.quantity AS g
ARRAY JOIN g.points   AS p
WHERE flow_code = 'PMAX';


-- STEP 5 · Surprise: silver is empty!
SELECT
    (SELECT count() FROM silver.load_curve) AS curve_points,
    (SELECT count() FROM silver.daily_energy)  AS energy_rows,
    (SELECT count() FROM silver.daily_pmax)     AS pmax_rows;
-- Measured: 3 ms · 4 rows read
-- What to look for: an MV only sees the INSERTs that arrive AFTER it was created.
--    Files already in bronze must be "replayed": that is the backfill.
--    This is by design: creating an MV on a 1 TB table blocks nothing.
