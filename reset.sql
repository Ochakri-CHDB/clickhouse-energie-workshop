-- =====================================================================
--  RESET · Supprime tout ce que le workshop a créé (et rien d'autre)
-- =====================================================================
-- Les row policies et le rôle du module 7 (ils survivent au DROP DATABASE)
DROP ROW POLICY IF EXISTS rp_gp_energie  ON gold.energie_commune_jour;
DROP ROW POLICY IF EXISTS rp_gp_courbe   ON gold.courbe_epci;
DROP ROW POLICY IF EXISTS rp_gp_synthese ON gold.synthese_collectivite_jour;
DROP ROW POLICY IF EXISTS rp_gp_alertes  ON gold.alertes_pmax;
DROP ROLE IF EXISTS role_grand_paris;
DROP DATABASE IF EXISTS gold SYNC;
DROP DATABASE IF EXISTS silver SYNC;
DROP DATABASE IF EXISTS bronze SYNC;
DROP DATABASE IF EXISTS simulateur SYNC;
DROP DATABASE IF EXISTS ref SYNC;
DROP USER IF EXISTS dict_reader;
DROP FUNCTION IF EXISTS sim_id_prm;
DROP FUNCTION IF EXISTS sim_destinataire;
DROP FUNCTION IF EXISTS sim_alea;
DROP FUNCTION IF EXISTS sim_heure_locale;
DROP FUNCTION IF EXISTS sim_heure_utc;
DROP FUNCTION IF EXISTS sim_conso_w;
DROP FUNCTION IF EXISTS sim_prod_w;
DROP FUNCTION IF EXISTS sim_iso;
DROP FUNCTION IF EXISTS sim_points_du_jour;
