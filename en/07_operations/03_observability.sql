-- =====================================================================
--  MODULE 7 · Observing the platform with… SQL
-- =====================================================================
--  Everything ClickHouse does is logged in system.* tables.
--  In Cloud, clusterAllReplicas() queries all the replicas.
--  It all reads as SQL, so it can feed
--  a dashboard or an alert like any other table.
-- =====================================================================


-- 1 · The most expensive queries of the last hour
--  What to look for: the big INSERTs and the rebuild on top. Those are what you optimize first.
SELECT
    query_kind,
    round(query_duration_ms / 1000, 1)        AS seconds,
    formatReadableQuantity(read_rows)         AS rows_read,
    formatReadableSize(memory_usage)          AS memory,
    substring(replaceAll(query, '\n', ' '), 1, 80) AS query_text
FROM clusterAllReplicas('default', system.query_log)
WHERE type = 'QueryFinish' AND event_time > now() - INTERVAL 1 HOUR
  AND has(databases, 'silver')
ORDER BY query_duration_ms DESC
LIMIT 10;


-- 2 · The cost of each materialized view (time spent on each INSERT)
--  An MV slows down the INSERTs into its source table: this log tells you by how much.
SELECT
    view_name,
    count()                                   AS triggers,
    round(sum(view_duration_ms) / 1000, 1)    AS total_seconds,
    formatReadableQuantity(sum(written_rows)) AS rows_written,
    formatReadableSize(max(peak_memory_usage)) AS max_memory
FROM clusterAllReplicas('default', system.query_views_log)
WHERE event_time > now() - INTERVAL 1 DAY
  AND (view_name LIKE 'silver.%' OR view_name LIKE 'gold.%')
GROUP BY view_name
ORDER BY total_seconds DESC;


-- 3 · Refreshable materialized views: status, duration, next run
SELECT view, status, last_success_time, round(last_success_duration_ms / 1000, 2) AS duration_s, next_refresh_time, exception
FROM system.view_refreshes
WHERE database = 'gold';


-- 4 · Parts and merges (the "breathing" of MergeTree)
--  Too many active parts (hundreds per partition) point to INSERTs that are too
--  small. system.part_log traces every creation (NewPart) and merge (MergeParts).
SELECT table, count() AS active_parts, formatReadableQuantity(sum(rows)) AS row_count
FROM system.parts
WHERE database IN ('bronze', 'silver', 'gold') AND active
GROUP BY table
ORDER BY active_parts DESC;

SELECT event_type, table, count() AS events, round(avg(duration_ms)) AS avg_ms
FROM clusterAllReplicas('default', system.part_log)
WHERE database IN ('bronze', 'silver', 'gold') AND event_time > now() - INTERVAL 1 DAY
GROUP BY event_type, table
ORDER BY events DESC
LIMIT 15;


-- 5 · Dictionary memory
SELECT database, name, status, element_count, formatReadableSize(bytes_allocated) AS memory
FROM system.dictionaries
WHERE database IN ('ref', 'simulator')
ORDER BY bytes_allocated DESC;


-- 6 · Storage, layer by layer
--  What to look for: bronze (the JSON) and load_curve_xl weigh the most; gold only a few MB,
--  even though it is what the dashboards read.
SELECT
    database,
    formatReadableQuantity(sum(rows))                AS row_count,
    formatReadableSize(sum(data_uncompressed_bytes)) AS raw,
    formatReadableSize(sum(data_compressed_bytes))   AS on_disk,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio
FROM system.parts
WHERE database IN ('ref', 'bronze', 'silver', 'gold') AND active
GROUP BY database
ORDER BY sum(data_compressed_bytes) DESC;
