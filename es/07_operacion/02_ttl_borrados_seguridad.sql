-- =====================================================================
--  MÓDULO 7 · Ciclo de vida, borrados selectivos, seguridad por territorio
-- =====================================================================


-- PASO 1 · TTL: el bronze en bruto se purga automáticamente a los 90 días
--  El TTL se evalúa durante los merges. Cuando una partición entera ha caducado,
--  se elimina de golpe: esa es la ventaja de particionar por mes
--  (regla schema-partition-lifecycle).
ALTER TABLE bronze.flujos_brutos MODIFY TTL toDateTime(ingested_at) + INTERVAL 90 DAY;
-- Medido: 30 ms
ALTER TABLE silver.rechazos  MODIFY TTL toDateTime(ingested_at) + INTERVAL 30 DAY;
-- Medido: 51 ms
SHOW CREATE TABLE bronze.flujos_brutos;


-- PASO 2 · Borrado selectivo (p. ej. una solicitud RGPD para un contador)
--  DELETE ligero: las filas desaparecen de inmediato de las lecturas.
--  Primero se ocultan y luego se borran físicamente en los merges siguientes.
--  Para borrar muchos datos de golpe, mejor DROP PARTITION
--  (regla insert-mutation-avoid-delete).
SELECT count() AS antes FROM silver.curva_carga WHERE id_contador = sim_id_contador(999);
-- Medido: 6 ms · 414 556 filas leídas (3,2 MB)
DELETE FROM silver.curva_carga WHERE id_contador = sim_id_contador(999);
-- Medido: 7,05 s
SELECT count() AS despues FROM silver.curva_carga WHERE id_contador = sim_id_contador(999);
-- Medido: 77 ms · 86 876 filas leídas (763,6 KB)


-- PASO 3 · Corregir un dato, por orden de preferencia
--   1) reinsertar una nueva versión (ReplacingMergeTree, visto en el módulo 3)
--   2) UPDATE ligero (parche aplicado durante los merges)
--   3) ALTER … UPDATE (mutación: reescribe las parts, solo para correcciones puntuales)
--  Aquí, una corrección puntual sobre un referencial pequeño: la mutación es aceptable.
--  mutations_sync = 1 espera a que termine la reescritura antes de devolver el control.
--  En una tabla de curvas, reinsertaríamos más bien una versión CORREGIDO (módulo 3).
ALTER TABLE ref.contador UPDATE tarifa = 'BASE' WHERE tarifa = 'TEMPO' AND potencia_kva < 6
SETTINGS mutations_sync = 1;
-- Medido: 1,03 s
SELECT command, is_done, parts_to_do FROM system.mutations WHERE database = 'ref' ORDER BY create_time DESC LIMIT 1;


-- PASO 4 · Cada destinatario solo ve SU territorio (row policies)
--  Una row policy añade un filtro invisible a todas las consultas de un rol.
--  La seguridad está en la base de datos: el front no tiene que añadir un WHERE,
--  y no puede olvidarlo.
CREATE ROLE IF NOT EXISTS role_madrid;
GRANT SELECT ON gold.* TO role_madrid;

CREATE ROW POLICY OR REPLACE rp_mad_energie   ON gold.energia_municipio_dia        USING codigo_area = '001'    TO role_madrid;
CREATE ROW POLICY OR REPLACE rp_mad_courbe    ON gold.curva_area                 USING codigo_area = '001'    TO role_madrid;
CREATE ROW POLICY OR REPLACE rp_mad_synthese  ON gold.resumen_entidad_dia  USING id_destinatario = '488903' TO role_madrid;
CREATE ROW POLICY OR REPLACE rp_mad_alertes   ON gold.alertas_pmax                USING codigo_area = '001'    TO role_madrid;

SELECT short_name, database, table, select_filter, apply_to_list
FROM system.row_policies
WHERE database = 'gold';
--  En producción: un usuario (o una cuenta de servicio del front) recibe este rol.
--    CREATE USER front_madrid IDENTIFIED BY '…' DEFAULT ROLE role_madrid;
--  Consulta las mismas tablas, pero solo ve el Área Urbana de Madrid (codigo_area '001').
