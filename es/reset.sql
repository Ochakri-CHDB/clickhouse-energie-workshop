-- =====================================================================
--  RESET · Borra todo lo que ha creado el workshop (y nada más)
-- =====================================================================
-- Las row policies y el rol del módulo 7 (sobreviven al DROP DATABASE)
DROP ROW POLICY IF EXISTS rp_gp_energie  ON gold.energia_municipio_dia;
DROP ROW POLICY IF EXISTS rp_gp_courbe   ON gold.curva_epci;
DROP ROW POLICY IF EXISTS rp_gp_synthese ON gold.resumen_entidad_dia;
DROP ROW POLICY IF EXISTS rp_gp_alertes  ON gold.alertas_pmax;
DROP ROLE IF EXISTS role_grand_paris;
DROP DATABASE IF EXISTS gold SYNC;
DROP DATABASE IF EXISTS silver SYNC;
DROP DATABASE IF EXISTS bronze SYNC;
DROP DATABASE IF EXISTS simulador SYNC;
-- Versiones francesa e inglesa del workshop, si se han ejecutado en este servicio
DROP DATABASE IF EXISTS simulateur SYNC;
DROP DATABASE IF EXISTS simulator SYNC;
DROP DATABASE IF EXISTS ref SYNC;
DROP USER IF EXISTS dict_reader;
DROP FUNCTION IF EXISTS sim_id_contador;
DROP FUNCTION IF EXISTS sim_destinatario;
DROP FUNCTION IF EXISTS sim_aleatorio;
DROP FUNCTION IF EXISTS sim_hora_local;
DROP FUNCTION IF EXISTS sim_hora_utc;
DROP FUNCTION IF EXISTS sim_consumo_w;
DROP FUNCTION IF EXISTS sim_prod_w;
DROP FUNCTION IF EXISTS sim_iso;
DROP FUNCTION IF EXISTS sim_puntos_dia;
