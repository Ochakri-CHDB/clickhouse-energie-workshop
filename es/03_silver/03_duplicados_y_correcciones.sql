-- =====================================================================
--  MÓDULO 3 · Reenvíos de ficheros y correcciones: ReplacingMergeTree
-- =====================================================================
--  En la vida real: un fichero se reenvía dos veces, una curva
--  BRUTO se corrige unos días después. ¿Qué hace silver?
-- =====================================================================


-- El contador que vamos a seguir (sim_id_contador convierte un número en un identificador de contador)
SELECT sim_id_contador(42) AS contador_seguido;
-- Medido: 1 ms · 1 fila leída


-- PASO 1 · Un fichero se reenvía idéntico, 3 días después
INSERT INTO bronze.flujos_brutos
SELECT
    replaceOne(file_name, '_488903_', '_488903_REENVIO_') AS file_name,
    codigo_flujo,
    ingested_at + INTERVAL 3 DAY                          AS ingested_at,
    payload
FROM bronze.flujos_brutos
WHERE codigo_flujo = 'CURVA'
  AND file_name LIKE 'DSO_CURVA_30MIN_PUB_100280_%';   -- el lote 0 del 15 de octubre
-- Medido: 385 ms · 624 ficheros leídos (11,6 MB de JSON) · 49 864 filas escritas · 109,7 MB de memoria

--  Ahora los puntos están duplicados en disco…
--  Qué observar: 96 filas para 48 marcas de tiempo distintas. Nada se sobrescribió en el INSERT.
SELECT count() AS filas, uniqExact(ts) AS puntos_distintos
FROM silver.curva_carga
WHERE id_contador = sim_id_contador(42) AND dia = '2026-10-15';
-- Medido: 92 ms · 78 684 filas leídas (648,3 KB)


-- PASO 2 · Tres formas de leer SIN duplicados
--  a) FINAL: ClickHouse deduplica en el momento de la lectura.
--     Sencillo y correcto. Cuesta algo más que una lectura normal, sobre todo
--     sin filtro: lo reservamos para consultas filtradas o para las tablas gold.
SELECT count() AS filas
FROM silver.curva_carga FINAL
WHERE id_contador = sim_id_contador(42) AND dia = '2026-10-15';
-- Medido: 90 ms · 86 876 filas leídas (1,7 MB)

--  b) argMax(valor, version): el valor de la fila con la versión más alta.
--     Mismo resultado que FINAL, escrito a mano.
SELECT toTimeZone(ts, 'Europe/Madrid') AS hora_local, argMax(valor_w, version) AS valor_w
FROM silver.curva_carga
WHERE id_contador = sim_id_contador(42) AND dia = '2026-10-15'
GROUP BY hora_local
ORDER BY hora_local
LIMIT 5;
-- Medido: 118 ms · 16 384 filas leídas (203,7 KB)

--  c) Dejar que los merges hagan limpieza: deduplican en segundo plano,
--     sin fecha garantizada. NO llamamos a OPTIMIZE TABLE … FINAL: reescribe
--     toda la partición (regla insert-optimize-avoid-final). Basta con FINAL en lectura.


-- PASO 3 · Una corrección: la distribuidora vuelve a publicar la curva del 15 como CORREGIDO
INSERT INTO bronze.flujos_brutos
SELECT
    replaceOne(file_name, '_488903_', '_488903_CORRECCION_'),
    codigo_flujo,
    ingested_at + INTERVAL 5 DAY,
    replaceAll(payload, '"etapa":"BRUTO"', '"etapa":"CORREGIDO"')
FROM bronze.flujos_brutos
WHERE codigo_flujo = 'CURVA'
  AND file_name LIKE 'DSO_CURVA_30MIN_PUB_100280_488903_2%';
-- Medido: 131 ms · 625 ficheros leídos (11,6 MB de JSON) · 49 864 filas escritas · 103,7 MB de memoria

SELECT etapa, count() AS puntos, max(version) AS version_retenida
FROM silver.curva_carga FINAL
WHERE id_contador = sim_id_contador(42) AND dia = '2026-10-15'
GROUP BY etapa;
-- Medido: 89 ms · 111 452 filas leídas (2,5 MB)
-- Qué observar: una sola versión visible, CORREGIDO ha sustituido a BRUTO, sin ningún UPDATE.
-- Es la forma de corregir en ClickHouse: se reinserta una versión más reciente
-- (regla insert-mutation-avoid-update).


-- PASO 4 · La trampa que hay que conocer (volvemos a ella en el módulo 5)
--  Una MV ve los INSERT, no el estado deduplicado. Una suma calculada por
--  una MV contaría dos veces el fichero reenviado. Los agregados idempotentes
--  (max, min, uniq) no se ven afectados. Las sumas, sí.
