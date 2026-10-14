-- =====================================================================
--  RESET · Drops everything the workshop created (and nothing else)
-- =====================================================================
-- The row policies and the role from module 7 (they survive DROP DATABASE)
DROP ROW POLICY IF EXISTS rp_gl_energie  ON gold.ward_day_energy;
DROP ROW POLICY IF EXISTS rp_gl_courbe   ON gold.metro_curve;
DROP ROW POLICY IF EXISTS rp_gl_synthese ON gold.authority_day_summary;
DROP ROW POLICY IF EXISTS rp_gl_alertes  ON gold.pmax_alerts;
DROP ROLE IF EXISTS role_greater_london;
DROP DATABASE IF EXISTS gold SYNC;
DROP DATABASE IF EXISTS silver SYNC;
DROP DATABASE IF EXISTS bronze SYNC;
DROP DATABASE IF EXISTS simulator SYNC;
-- French and Spanish versions of the workshop, if they ran on this service
DROP DATABASE IF EXISTS simulateur SYNC;
DROP DATABASE IF EXISTS simulador SYNC;
DROP DATABASE IF EXISTS ref SYNC;
DROP USER IF EXISTS dict_reader;
DROP FUNCTION IF EXISTS sim_meter_id;
DROP FUNCTION IF EXISTS sim_recipient;
DROP FUNCTION IF EXISTS sim_random;
DROP FUNCTION IF EXISTS sim_local_hour;
DROP FUNCTION IF EXISTS sim_utc_hour;
DROP FUNCTION IF EXISTS sim_cons_w;
DROP FUNCTION IF EXISTS sim_prod_w;
DROP FUNCTION IF EXISTS sim_iso;
DROP FUNCTION IF EXISTS sim_day_points;
