-- =====================================================================
--  MODULE 7 · Lifecycle, targeted deletes, per-authority security
-- =====================================================================


-- STEP 1 · TTL: raw bronze is purged automatically after 90 days
--  TTL is evaluated during merges. When a whole partition has expired,
--  it is dropped in one go: that is the point of partitioning by month
--  (rule schema-partition-lifecycle).
ALTER TABLE bronze.raw_flows MODIFY TTL toDateTime(ingested_at) + INTERVAL 90 DAY;
-- Measured: 44 ms
ALTER TABLE silver.rejects  MODIFY TTL toDateTime(ingested_at) + INTERVAL 30 DAY;
-- Measured: 53 ms
SHOW CREATE TABLE bronze.raw_flows;


-- STEP 2 · Targeted delete (e.g. a GDPR request for one meter)
--  Lightweight DELETE: the rows disappear from reads immediately.
--  They are masked first, then physically erased by the next merges.
--  To delete a lot of data at once, prefer DROP PARTITION
--  (rule insert-mutation-avoid-delete).
SELECT count() AS before FROM silver.load_curve WHERE meter_id = sim_meter_id(999);
-- Measured: 8 ms · 426,534 rows read (3.3 MB)
DELETE FROM silver.load_curve WHERE meter_id = sim_meter_id(999);
-- Measured: 7.06 s
SELECT count() AS after FROM silver.load_curve WHERE meter_id = sim_meter_id(999);
-- Measured: 88 ms · 98,854 rows read (868.8 KB)


-- STEP 3 · Fixing a value, in order of preference
--   1) reinsert a new version (ReplacingMergeTree, seen in module 3)
--   2) lightweight UPDATE (patch applied during merges)
--   3) ALTER … UPDATE (mutation: rewrites the parts, rare corrections only)
--  Here, a rare correction on a small reference table: a mutation is acceptable.
--  mutations_sync = 1 waits for the rewrite to finish before returning.
--  On a curve table, we would rather reinsert a CORRECTED version (module 3).
ALTER TABLE ref.meter UPDATE tariff = 'BASE' WHERE tariff = 'TEMPO' AND power_kva < 6
SETTINGS mutations_sync = 1;
-- Measured: 1.03 s
SELECT command, is_done, parts_to_do FROM system.mutations WHERE database = 'ref' ORDER BY create_time DESC LIMIT 1;


-- STEP 4 · Each local authority sees ONLY its own territory (row policies)
--  A row policy adds an invisible filter to every query of a role.
--  Security lives in the database: the front end does not have to add a WHERE,
--  and cannot forget it.
CREATE ROLE IF NOT EXISTS role_greater_london;
GRANT SELECT ON gold.* TO role_greater_london;

CREATE ROW POLICY OR REPLACE rp_gl_energie   ON gold.ward_day_energy        USING metro_code = 'E61000001'    TO role_greater_london;
CREATE ROW POLICY OR REPLACE rp_gl_courbe    ON gold.metro_curve                 USING metro_code = 'E61000001'    TO role_greater_london;
CREATE ROW POLICY OR REPLACE rp_gl_synthese  ON gold.authority_day_summary  USING recipient_id = '488903' TO role_greater_london;
CREATE ROW POLICY OR REPLACE rp_gl_alertes   ON gold.pmax_alerts                USING metro_code = 'E61000001'    TO role_greater_london;

SELECT short_name, database, table, select_filter, apply_to_list
FROM system.row_policies
WHERE database = 'gold';
-- What to look for: 4 rp_gl_* policies, all applied to role_greater_london, filtering
-- on the Greater London Authority (metro_code E61000001, recipient 488903).
--  In production: a user (or a front-end service account) is granted this role.
--    CREATE USER front_greater_london IDENTIFIED BY '…' DEFAULT ROLE role_greater_london;
--  It queries the same tables, but only sees the Greater London Authority.
