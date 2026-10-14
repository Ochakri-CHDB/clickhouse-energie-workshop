-- =====================================================================
--  MÓDULO 2 · Bronze: los ficheros JSON tal como llegan
-- =====================================================================
--  Regla de oro de bronze: guardamos el bruto, no transformamos nada.
--  Una fila = un fichero recibido (1000 contadores, 1 día).
--  Volumen: 20 000 contadores × 31 días, flujos CURVA (curvas de 30 min), ENERGIA (energía diaria), PMAX (potencia máxima)
--  Destinatarios: las 6 áreas urbanas (12 lotes para Madrid, 2 para Barcelona,
--  Valencia y Sevilla, 1 para Bilbao y Málaga)
--
--  ¿Por qué guardar el bruto? Si cambia una regla de parsing o se corrige
--  un bug, se puede reconstruir todo desde bronze (módulo 7), sin volver a pedir
--  los ficheros a la distribuidora.
-- =====================================================================


-- PASO 1 · La tabla bronze
CREATE OR REPLACE TABLE bronze.flujos_brutos
(
    file_name    String,
    codigo_flujo    LowCardinality(String),        -- CURVA / ENERGIA / PMAX
    ingested_at  DateTime64(3, 'UTC'),          -- hora de llegada del fichero
    payload      String CODEC(ZSTD(3))          -- el JSON bruto. ZSTD(3) comprime más que el códec por defecto (LZ4): ideal para texto que se relee poco
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ingested_at)              -- una partición por mes: pocas, fáciles de purgar (TTL, módulo 7)
ORDER BY (codigo_flujo, ingested_at, file_name);   -- bronze se relee por flujo y luego por fecha de llegada


-- PASO 2 · Un solo día de curvas CURVA (20 ficheros, ~1 millón de puntos)
--  Lo que hace la consulta, de dentro hacia fuera:
--    numbers(0, 20)   → 20 ficheros (lotes de 1000 contadores)
--    dictGet          → perfil, potencia, paneles solares de cada contador
--    arrayMap         → para cada contador, sus 48 puntos del día
--    CAST + toJSONString → el fichero JSON final, con los nombres de campo del formato de origen
INSERT INTO bronze.flujos_brutos
WITH
    toDate('2026-10-01') + intDiv(number, 20)                                  AS dia,
    number % 20                                                                 AS lote,
    -- llegada: al día siguiente entre las 6h y las 8h, salvo ~1 % de ficheros con retraso (por la tarde)
    toDateTime64(toDateTime(dia + 1, 'Europe/Madrid'), 3, 'UTC')
        + toIntervalSecond(if(sim_aleatorio(dia, lote, 'retard') < 0.01, 50400, 21600 + lote * 300 + cityHash64(dia, lote) % 240)) AS llegada,
    sim_puntos_dia(dia)                                                    AS marcas_tiempo,
    -- ~0,3 % de los contadores no enviaron nada ese día (fallo de comunicación)
    arrayFilter(n -> sim_aleatorio(n, dia, 'panne') >= 0.003, range(lote * 1000, lote * 1000 + 1000)) AS ns,
    arrayMap(n -> sim_id_contador(n), ns)                                            AS ids,
    arrayMap(id -> dictGet('simulador.dict_contador', ('perfil', 'potencia_kva', 'fv_kwp', 'codigo_provincia'), id), ids) AS attrs
SELECT
    concat('DSO_CURVA_30MIN_PUB_', toString(100000 + number), '_', sim_destinatario(lote), '_', formatDateTime(llegada, '%Y%m%d%H%i%S'), '.zip') AS file_name,
    'CURVA'   AS codigo_flujo,
    llegada AS ingested_at,
    toJSONString(CAST((
        ('PORTAL DATOS', 'ENTIDAD_LOCAL', sim_destinatario(lote), 'CURVA30', toString(100000 + number), 'RECURRENTE', 'JSON'),
        arrayMap((id, a) -> (
            leftPad(toString(id), 14, '0'),
            'BRUTO',
            (toString(dia), toString(dia + 1)),
            'PT30M',
            arrayConcat(
                -- el consumo: ~0,02 % de puntos que faltan, ~0,03 % de valores vacíos (rechazos)
                [('PA', 'CONS', 'W',
                  arrayMap(t -> (sim_iso(t), if(sim_aleatorio(id, t, 'ko') < 0.0003, '', toString(sim_consumo_w(id, a.1, a.2, t)))),
                           arrayFilter(t -> sim_aleatorio(id, t, 'trou') >= 0.0002, marcas_tiempo)))],
                -- la producción, solo para los contadores con paneles
                if(a.3 > 0,
                   [('PA', 'PROD', 'W', arrayMap(t -> (sim_iso(t), toString(sim_prod_w(id, a.4, a.3, t))), marcas_tiempo))],
                   []))
        ), ids, attrs)
    ), 'Tuple(cabecera Tuple(solicitante String, tipoDestinatario String, idDestinatario String, codigoFlujo String, idPublicacion String, modoPublicacion String, format String),
              medidas Array(Tuple(idContador String, etapa String, periodo Tuple(fechaInicio String, fechaFin String), paso String,
                                  magnitud Array(Tuple(magnitudFisica String, magnitudNegocio String, unidad String,
                                                       puntos Array(Tuple(d String, v String)))))))')) AS payload
FROM numbers(0, 20)
SETTINGS max_block_size = 2;   -- 2 ficheros por bloque: cada fichero pesa ~2 MB de JSON, así la memoria se mantiene baja
-- Medido: 901 ms · 20 filas leídas · 20 filas escritas · 213,1 MB de memoria

--  ¿Qué hemos recibido? length() da el tamaño del JSON en bytes.
SELECT codigo_flujo, count() AS ficheros, formatReadableSize(sum(length(payload))) AS volumen_json
FROM bronze.flujos_brutos
GROUP BY codigo_flujo;
-- Medido: 6 ms · 20 filas leídas

--  Un fichero, tal como se recibió
SELECT file_name, ingested_at, substring(payload, 1, 600) AS inicio_json
FROM bronze.flujos_brutos
LIMIT 1;
-- Medido: 15 ms · 5 filas leídas (11,5 MB)


-- PASO 3 · El resto del mes: días 2 a 30 (580 ficheros, ~28 millones de puntos)
--  La consulta del paso 2 está guardada en una VISTA PARAMETRIZADA (simulador.ficheros_curva).
--  Se llama como una función. El día 31 se reserva para el módulo 3.
--  Un solo INSERT de 580 ficheros en lugar de 580 INSERT pequeños: cada INSERT
--  crea una part, y pocas parts grandes cuestan menos de fusionar
--  (regla insert-batch-size).
INSERT INTO bronze.flujos_brutos
SELECT * FROM simulador.ficheros_curva(inicio = 20, n = 580)
SETTINGS max_block_size = 2;
-- Medido: 11,32 s · 580 ficheros generados y escritos (1,30 GB de JSON) · 2,2 GB de memoria
-- Qué observar: la duración incluye la generación Y la escritura de ~1,3 GB de JSON.


-- PASO 4 · Los flujos diarios: ENERGIA (energía) y PMAX (potencia máxima)
INSERT INTO bronze.flujos_brutos
SELECT * FROM simulador.ficheros_energia(inicio = 0, n = 600)
SETTINGS max_block_size = 4;
-- Medido: 3,51 s · 600 ficheros ENERGIA (168 MB de JSON) · 769,9 MB de memoria

INSERT INTO bronze.flujos_brutos
SELECT * FROM simulador.ficheros_pmax(inicio = 0, n = 600)
SETTINGS max_block_size = 4;
-- Medido: 5,39 s · 600 ficheros PMAX (145 MB de JSON) · 445,6 MB de memoria


-- PASO 5 · Balance de la ingesta
SELECT
    codigo_flujo,
    count()                                                        AS ficheros,
    min(ingested_at)                                               AS primero,
    max(ingested_at)                                               AS ultimo,
    formatReadableSize(sum(length(payload)))                       AS json_bruto
FROM bronze.flujos_brutos
GROUP BY codigo_flujo
ORDER BY codigo_flujo;
-- Medido: 60 ms · 1 800 filas leídas (29,9 KB)

--  ¿Cuánto ocupa de verdad en disco? (compresión ZSTD del JSON)
--  Qué observar: el JSON es muy repetitivo (mismas claves, mismas fechas): se
--  comprime por un factor de 10 a 15.
SELECT
    formatReadableSize(sum(data_uncompressed_bytes))                 AS bruto,
    formatReadableSize(sum(data_compressed_bytes))                   AS en_disco,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes)) AS ratio
FROM system.parts
WHERE database = 'bronze' AND table = 'flujos_brutos' AND active;

--  Las parts creadas por nuestros INSERT
--  El nombre de una part (202610_0_5_1) indica la partición, el rango de bloques y el
--  nivel de fusión. Vuelve a lanzar la consulta dentro de un minuto: los merges en segundo plano
--  habrán reducido su número.
SELECT partition, name, rows, formatReadableSize(bytes_on_disk) AS tamano, modification_time
FROM system.parts
WHERE database = 'bronze' AND table = 'flujos_brutos' AND active
ORDER BY modification_time;


-- CHECKPOINT MÓDULO 2
--  600 ficheros por flujo: 20 lotes × 30 días (el 31 llega en el módulo 3).
SELECT
    if(countIf(codigo_flujo = 'CURVA') = 600, 'OK', 'ERROR') AS curva_600_ficheros,
    if(countIf(codigo_flujo = 'ENERGIA') = 600, 'OK', 'ERROR') AS energia_600_ficheros,
    if(countIf(codigo_flujo = 'PMAX') = 600, 'OK', 'ERROR') AS pmax_600_ficheros
FROM bronze.flujos_brutos
SETTINGS select_sequential_consistency = 1;   -- leer la última versión, sea cual sea la réplica
