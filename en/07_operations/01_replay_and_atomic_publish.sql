-- =====================================================================
--  MODULE 7 · Replay a month without disturbing the flow, then publish in one go
-- =====================================================================
--  A real case: a rule changes, a parsing bug gets fixed, and we have to
--  rebuild silver for October. Meanwhile, the daily flow keeps running
--  and the dashboards still read the old version.
--
--     bronze ──(isolated rebuild)──► silver.load_curve__build
--                                         │ checks
--                                         ▼
--             REPLACE PARTITION: atomic switch to silver.load_curve
-- =====================================================================


-- STEP 1 · A build table, a clone of the production table
--  CREATE TABLE … AS copies the structure (columns, engine, key), not the data.
CREATE OR REPLACE TABLE silver.load_curve__build AS silver.load_curve;


-- STEP 2 · The rebuild: we keep ONLY the latest version of each point
--  (argMax per point), straight from bronze. No MV fires, because we write
--  into __build and not into bronze. Production is not touched.
--  Watch out: this GROUP BY covers ~32 M keys and needs a lot of memory.
--  In Cloud, beyond half the RAM, ClickHouse spills to disk instead of
--  failing: slower, but no error.
INSERT INTO silver.load_curve__build
SELECT
    meter_id, quantity, ts,
    argMax(value_w, version), argMax(step_min, version), argMax(stage, version), max(version)
FROM
(
    SELECT
        toUInt64(m.meterId) AS meter_id, g.businessQuantity AS quantity, parseDateTimeBestEffort(p.d, 'UTC') AS ts,
        toUInt32(p.v) AS value_w, toUInt8(extract(m.step, '\\d+')) AS step_min, m.stage AS stage,
        ingested_at AS version
    FROM bronze.raw_flows
    ARRAY JOIN JSONExtract(payload, 'measurements',
        'Array(Tuple(meterId String, stage String, step String, quantity Array(Tuple(businessQuantity String, points Array(Tuple(d String, v String))))))') AS m
    ARRAY JOIN m.quantity AS g
    ARRAY JOIN g.points   AS p
    WHERE flow_code = 'CURVE' AND toUInt32OrNull(p.v) IS NOT NULL
)
WHERE toYYYYMM(ts) = 202610
GROUP BY meter_id, quantity, ts;
-- Measured: 8.16 s · 623 files read (1.4 GB of JSON) · 30.9 M rows written · 12.5 GB of memory


-- STEP 3 · Checks before publishing
--  We compare the rebuild with deduplicated production (FINAL). We only publish if
--  both counts match. The 3rd column shows the physical duplicates in prod.
SELECT
    (SELECT count() FROM silver.load_curve FINAL WHERE toYYYYMM(ts) = 202610)  AS prod_deduplicated,
    (SELECT count() FROM silver.load_curve__build)                              AS rebuild,
    (SELECT count() FROM silver.load_curve WHERE toYYYYMM(ts) = 202610)        AS prod_before_merges,
    if(prod_deduplicated = rebuild, 'OK, ready to publish', 'FAIL, mismatch: do not publish') AS verdict
SETTINGS select_sequential_consistency = 1;
-- Measured: 218 ms · 62.8 M rows read (754.7 MB) · 236 MB memory


-- STEP 4 · Atomic publish: the prod partition is replaced in one go
--  Readers see the old version, then the new one. Never a mix.
--  REPLACE PARTITION does not copy data: it attaches the parts of __build
--  to the production table. That is why it takes less than a second.
--  Both tables must have exactly the same structure.
ALTER TABLE silver.load_curve REPLACE PARTITION 202610 FROM silver.load_curve__build;
-- Measured: 215 ms

SELECT count() AS prod_rows_after_publish
FROM silver.load_curve
WHERE toYYYYMM(ts) = 202610
SETTINGS select_sequential_consistency = 1;
-- Measured: 147 ms · 30.9 M rows read (117.9 MB)
-- What to look for: the count equals the rebuild. The table is compact, no more physical
-- duplicates, and all that without OPTIMIZE TABLE … FINAL.

DROP TABLE silver.load_curve__build;


-- STEP 5 · Recompute gold: a simple refresh
--  Thanks to DEPENDS ON (module 5), the per-authority summary follows automatically.
SYSTEM REFRESH VIEW gold.rmv_ward_day_energy;
SYSTEM WAIT VIEW gold.rmv_ward_day_energy;
-- Measured: 1.3 s


-- STEP 6 · Swap two tables in one go: EXCHANGE TABLES
--  Example: a new version of a gold table, built alongside the old one.
--  EXCHANGE TABLES swaps the names of the two tables in a single atomic operation:
--  no reader ever sees an empty or half-filled table.
CREATE OR REPLACE TABLE gold.ward_day_energy__v2 AS gold.ward_day_energy;
INSERT INTO gold.ward_day_energy__v2 SELECT * FROM gold.ward_day_energy;
-- Measured: 132 ms · 76,177 rows read (2.5 MB) · 76,177 rows written
EXCHANGE TABLES gold.ward_day_energy AND gold.ward_day_energy__v2;
-- Measured: 7 ms
DROP TABLE gold.ward_day_energy__v2;


-- STEP 7 · Pause a view during a heavy operation
--  SYSTEM STOP VIEW suspends scheduled refreshes, SYSTEM START resumes them.
--  What to look for: the status switches to Disabled, then comes back.
SYSTEM STOP VIEW gold.rmv_pmax_alerts;
SELECT view, status FROM system.view_refreshes WHERE view = 'rmv_pmax_alerts';
SYSTEM START VIEW gold.rmv_pmax_alerts;
