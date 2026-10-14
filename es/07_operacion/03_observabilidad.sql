-- =====================================================================
--  MÓDULO 7 · Observar la plataforma con… SQL
-- =====================================================================
--  Todo lo que hace ClickHouse queda registrado en tablas system.*
--  En Cloud, clusterAllReplicas() consulta todas las réplicas.
--  Todo se lee en SQL, así que puede
--  alimentar un dashboard o una alerta como cualquier otra tabla.
-- =====================================================================


-- 1 · Las consultas más costosas de la última hora
--  Qué observar: arriba, los INSERT grandes y el rebuild. Son los primeros a optimizar.
SELECT
    query_kind,
    round(query_duration_ms / 1000, 1)        AS segundos,
    formatReadableQuantity(read_rows)         AS filas_leidas,
    formatReadableSize(memory_usage)          AS memoria,
    substring(replaceAll(query, '\n', ' '), 1, 80) AS consulta
FROM clusterAllReplicas('default', system.query_log)
WHERE type = 'QueryFinish' AND event_time > now() - INTERVAL 1 HOUR
  AND has(databases, 'silver')
ORDER BY query_duration_ms DESC
LIMIT 10;


-- 2 · El coste de cada vista materializada (tiempo dedicado en cada INSERT)
--  Una MV ralentiza los INSERT de su tabla de origen: este registro dice cuánto.
SELECT
    view_name,
    count()                                   AS disparos,
    round(sum(view_duration_ms) / 1000, 1)    AS segundos_total,
    formatReadableQuantity(sum(written_rows)) AS filas_escritas,
    formatReadableSize(max(peak_memory_usage)) AS memoria_max
FROM clusterAllReplicas('default', system.query_views_log)
WHERE event_time > now() - INTERVAL 1 DAY
  AND (view_name LIKE 'silver.%' OR view_name LIKE 'gold.%')
GROUP BY view_name
ORDER BY segundos_total DESC;


-- 3 · Las vistas materializadas refrescables: estado, duración, próxima ejecución
SELECT view, status, last_success_time, round(last_success_duration_ms / 1000, 2) AS duracion_s, next_refresh_time, exception
FROM system.view_refreshes
WHERE database = 'gold';


-- 4 · Las parts y los merges (la "respiración" de MergeTree)
--  Demasiadas parts activas (cientos por partición) indican INSERT demasiado
--  pequeños. system.part_log registra cada creación (NewPart) y fusión (MergeParts).
SELECT table, count() AS partes_activas, formatReadableQuantity(sum(rows)) AS filas
FROM system.parts
WHERE database IN ('bronze', 'silver', 'gold') AND active
GROUP BY table
ORDER BY partes_activas DESC;

SELECT event_type, table, count() AS eventos, round(avg(duration_ms)) AS ms_medio
FROM clusterAllReplicas('default', system.part_log)
WHERE database IN ('bronze', 'silver', 'gold') AND event_time > now() - INTERVAL 1 DAY
GROUP BY event_type, table
ORDER BY eventos DESC
LIMIT 15;


-- 5 · La memoria de los diccionarios
SELECT database, name, status, element_count, formatReadableSize(bytes_allocated) AS memoria
FROM system.dictionaries
WHERE database IN ('ref', 'simulador')
ORDER BY bytes_allocated DESC;


-- 6 · El almacenamiento, capa por capa
--  Qué observar: bronze (el JSON) y curva_carga_xl son los que más pesan; gold, apenas
--  unos MB, aunque es lo que leen los dashboards.
SELECT
    database,
    formatReadableQuantity(sum(rows))                AS filas,
    formatReadableSize(sum(data_uncompressed_bytes)) AS bruto,
    formatReadableSize(sum(data_compressed_bytes))   AS en_disco,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio
FROM system.parts
WHERE database IN ('ref', 'bronze', 'silver', 'gold') AND active
GROUP BY database
ORDER BY sum(data_compressed_bytes) DESC;
