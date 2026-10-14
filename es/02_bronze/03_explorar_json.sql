-- =====================================================================
--  MÓDULO 2 · Explorar el JSON bruto, sin cargarlo en ningún otro sitio
-- =====================================================================


-- PASO 1 · Las funciones JSON leen directamente el texto
--  JSONExtract* recorre el texto en el momento de leerlo, sin ninguna preparación.
--  Práctico para explorar, pero en cada consulta se vuelve a parsear todo el JSON:
--  por eso pasamos a silver, con columnas tipadas.
SELECT
    file_name,
    JSONExtractString(payload, 'cabecera', 'codigoFlujo')        AS codigo_flujo_origen,
    JSONExtractString(payload, 'cabecera', 'idDestinatario')  AS destinatario,
    JSONLength(payload, 'medidas')                          AS n_medidas
FROM bronze.flujos_brutos
WHERE codigo_flujo = 'CURVA'
LIMIT 5;
-- Medido: 80 ms · 64 ficheros leídos (148,1 MB de JSON) · 316,2 MB de memoria


-- PASO 2 · El tipo JSON nativo: ClickHouse descubre la estructura él solo
--  payload::JSON convierte el texto al tipo JSON: cada ruta se convierte en
--  una subcolumna tipada. Útil cuando el esquema cambia a menudo (regla
--  schema-json-when-to-use). Aquí el formato de origen es estable: en silver
--  preferiremos columnas clásicas.
SELECT JSONAllPathsWithTypes(payload::JSON) AS estructura_detectada
FROM bronze.flujos_brutos
WHERE codigo_flujo = 'PMAX'
LIMIT 1;
-- Medido: 215 ms · 600 ficheros leídos (144,9 MB de JSON) · 406,1 MB de memoria

--  Se navega con puntos, como en JavaScript.
--  .:`Array(JSON)` indica el tipo esperado para un array de objetos.
SELECT
    j.cabecera.codigoFlujo                                        AS codigo_flujo,
    arrayJoin(j.medidas.:`Array(JSON)`).idContador                AS id_contador
FROM (SELECT payload::JSON AS j FROM bronze.flujos_brutos WHERE codigo_flujo = 'PMAX' LIMIT 1)
LIMIT 5;
-- Medido: 75 ms · 600 ficheros leídos (144,9 MB de JSON) · 406,2 MB de memoria


-- PASO 3 · Extracción tipada: la clave para pasar a silver
--  Describimos la forma esperada y ClickHouse la rellena en una sola pasada.
--  Después, dos ARRAY JOIN despliegan los arrays: fichero → medidas → magnitudes.
--  Es exactamente la consulta que ejecutará la vista materializada en el módulo 3.
SELECT
    m.idContador, m.etapa, g.magnitudNegocio, length(g.puntos) AS n_puntos
FROM
(
    SELECT JSONExtract(payload, 'medidas',
        'Array(Tuple(idContador String, etapa String, magnitud Array(Tuple(magnitudNegocio String, puntos Array(Tuple(d String, v String))))))') AS medidas
    FROM bronze.flujos_brutos
    WHERE codigo_flujo = 'CURVA'
    LIMIT 1
)
ARRAY JOIN medidas AS m
ARRAY JOIN m.magnitud AS g
LIMIT 10;
-- Medido: 21 ms · 64 ficheros leídos (148,1 MB de JSON) · 305,8 MB de memoria


-- PASO 4 · ¿Cuánto cuestan nuestros INSERT? (el registro de consultas)
--  system.query_log guarda una fila por consulta: duración, filas, memoria.
--  En Cloud, cada réplica tiene su propio registro: clusterAllReplicas()
--  las consulta todas.
SELECT
    event_time,
    query_duration_ms / 1000                       AS segundos,
    written_rows                                   AS ficheros_escritos,
    formatReadableSize(written_bytes)              AS tamano_escrito,
    formatReadableSize(memory_usage)               AS memoria_max,
    substring(query, position(query, 'FROM numbers'), 30) AS rango
FROM clusterAllReplicas('default', system.query_log)
WHERE type = 'QueryFinish'
  AND query_kind = 'Insert'
  AND has(tables, 'bronze.flujos_brutos')
  AND event_date = today()
ORDER BY event_time;
-- Qué observar: la memoria máxima de cada INSERT. Se queda en torno a
-- 2 GB porque max_block_size = 2 solo mantiene 2 ficheros en memoria a la vez.
