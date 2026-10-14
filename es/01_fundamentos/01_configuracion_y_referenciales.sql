-- =====================================================================
--  MÓDULO 1 · Fundamentos: bases de datos, MergeTree y datos de referencia
-- =====================================================================
--  Creamos las 4 capas del pipeline y los datos de referencia:
--    ref     → municipios (datos reales del INSEE), contadores, entidades locales
--    bronze  → ficheros JSON brutos, tal como llegan
--    silver  → medidas tipadas, limpias, deduplicadas
--    gold    → KPIs listos para los dashboards
--
--  Una "base de datos" de ClickHouse es un simple espacio de nombres: no cuesta
--  nada y sirve para ordenar las tablas y dar permisos por capa.
-- =====================================================================


-- PASO 1 · Las bases de datos (una por capa)
CREATE DATABASE IF NOT EXISTS ref;
CREATE DATABASE IF NOT EXISTS bronze;
CREATE DATABASE IF NOT EXISTS silver;
CREATE DATABASE IF NOT EXISTS gold;
CREATE DATABASE IF NOT EXISTS simulador;   -- el generador de datos del workshop


-- PASO 2 · Un usuario técnico para los diccionarios (módulo 4)
--  En la consola Cloud, un diccionario que lee una tabla local
--  tiene que declarar un usuario y una contraseña. Lo limitamos:
--  solo conexión local, solo lectura sobre los datos de referencia.
CREATE USER IF NOT EXISTS dict_reader IDENTIFIED BY 'Dict_Workshop_2026!' HOST LOCAL;
GRANT SELECT ON ref.* TO dict_reader;
GRANT SELECT ON simulador.* TO dict_reader;


-- PASO 3 · Los municipios franceses, leídos EN DIRECTO desde la API oficial
--  url() lee un recurso HTTP como una tabla. El formato JSONEachRow le dice
--  a ClickHouse cómo trocear la respuesta: un objeto JSON = una fila.
--  La base de datos lee el recurso ella misma, dentro de la consulta.
SELECT *
FROM url('https://geo.api.gouv.fr/communes?fields=code,nom,codeDepartement,codeRegion,codeEpci,population&format=json', JSONEachRow)
LIMIT 5;
-- Medido: 531 ms · 5 filas leídas


-- PASO 4 · Nuestra primera tabla MergeTree
--  MergeTree es el motor base de ClickHouse. Dos cosas que recordar:
--    · ORDER BY fija el orden físico de las filas en disco Y el índice
--      primario. Después ya no se puede cambiar: se elige según los
--      filtros más frecuentes (regla schema-pk-plan-before-creation).
--    · cada columna se almacena y se comprime por separado (almacenamiento
--      columnar): una consulta solo lee las columnas que usa.
CREATE OR REPLACE TABLE ref.municipio
(
    codigo_insee   String,
    nombre          String,
    codigo_dpto    LowCardinality(String),   -- ~100 valores distintos: se guardan una vez y luego números (regla: menos de 10 000 valores)
    codigo_region  LowCardinality(String),
    codigo_epci    String,                   -- sin Nullable: '' si falta (regla schema-types-avoid-nullable)
    poblacion   UInt32,                   -- el tipo entero más pequeño que basta
    lon          Float32,
    lat          Float32
)
ENGINE = MergeTree
ORDER BY codigo_insee;

--  Declaramos el esquema de la respuesta: los campos que a veces faltan se leen
--  como Nullable y luego se sustituyen por un valor por defecto con ifNull.
INSERT INTO ref.municipio
SELECT
    code, nom, codeDepartement, codeRegion, ifNull(codeEpci, ''), ifNull(population, 0),
    centre.coordinates[1], centre.coordinates[2]
FROM url('https://geo.api.gouv.fr/communes?fields=code,nom,codeDepartement,codeRegion,codeEpci,population,centre&format=json', JSONEachRow,
         'code String, nom String, codeDepartement String, codeRegion String, codeEpci Nullable(String), population Nullable(UInt32), centre Tuple(type String, coordinates Array(Float64))');
-- Medido: 471 ms · 34 969 filas leídas (5,9 MB) · 34 969 filas escritas
--  Plan B si la API no responde: el mismo fichero está en el repo
--  INSERT INTO ref.municipio SELECT * FROM url('https://raw.githubusercontent.com/Ochakri-CHDB/clickhouse-energie-workshop/main/data/communes.csv', CSVWithNames);

CREATE OR REPLACE TABLE ref.departamento (codigo_dpto String, nombre String, codigo_region String) ENGINE = MergeTree ORDER BY codigo_dpto;
INSERT INTO ref.departamento SELECT code, nom, codeRegion
FROM url('https://geo.api.gouv.fr/departements?fields=code,nom,codeRegion', JSONEachRow, 'code String, nom String, codeRegion String');
-- Medido: 314 ms · 101 filas leídas (5 KB) · 101 filas escritas

CREATE OR REPLACE TABLE ref.region (codigo_region String, nombre String) ENGINE = MergeTree ORDER BY codigo_region;
INSERT INTO ref.region SELECT code, nom
FROM url('https://geo.api.gouv.fr/regions?fields=code,nom', JSONEachRow, 'code String, nom String');
-- Medido: 121 ms · 18 filas leídas · 18 filas escritas

CREATE OR REPLACE TABLE ref.epci (codigo_epci String, nombre String) ENGINE = MergeTree ORDER BY codigo_epci;
INSERT INTO ref.epci SELECT code, nom
FROM url('https://geo.api.gouv.fr/epcis?fields=code,nom', JSONEachRow, 'code String, nom String');
-- Medido: 140 ms · 1 255 filas leídas (67 KB) · 1 255 filas escritas

SELECT count() AS n_municipios, sum(poblacion) AS poblacion_total FROM ref.municipio;
-- Medido: 3 ms · 34 969 filas leídas (136,6 KB)
-- Qué observar: unos 35 000 municipios y 69 millones de habitantes.


-- PASO 5 · Las entidades locales destinatarias de los flujos
--  Cada fichero de la distribuidora va dirigido a un destinatario (idDestinatario).
--  Vinculamos cada uno a su EPCI (mancomunidad), lo que permitirá filtrar por territorio.
CREATE OR REPLACE TABLE ref.destinatario
(
    id_destinatario String,
    nombre             String,
    codigo_epci       String
)
ENGINE = MergeTree
ORDER BY id_destinatario;

INSERT INTO ref.destinatario VALUES
    ('488903', 'Métropole du Grand Paris',      '200054781'),
    ('488904', 'Métropole de Lyon',             '200046977'),
    ('488905', 'Métropole Européenne de Lille', '200093201'),
    ('488906', 'Toulouse Métropole',            '243100518'),
    ('488907', 'Bordeaux Métropole',            '243300316'),
    ('488908', 'Nantes Métropole',              '244400404');

--  Los 20 ficheros de un día (lotes de 1000 contadores) se reparten entre las
--  6 metrópolis, más o menos en proporción a su población. Una entidad local
--  SOLO recibe los contadores de su territorio: lo tenemos en cuenta desde el sorteo.
--  CREATE FUNCTION crea una función SQL (UDF): una expresión con nombre,
--  reutilizable en todas las consultas. Aquí: número de lote → destinatario.
CREATE OR REPLACE FUNCTION sim_destinatario AS (lote) ->
    ['488903', '488903', '488903', '488903', '488903', '488903', '488903', '488903', '488903', '488903',
     '488903', '488903', '488904', '488904', '488905', '488905', '488906', '488906', '488907', '488908'][lote + 1];

SELECT sim_destinatario(lote) AS id_destinatario, count() AS lotes, count() * 1000 AS contador
FROM (SELECT number AS lote FROM numbers(20))
GROUP BY id_destinatario
ORDER BY id_destinatario;
-- Medido: 3 ms · 20 filas leídas


-- PASO 6 · El parque de contadores: 1 millón de contadores generados
--  Cada contador se asigna a un municipio, sorteado en proporción a su
--  población. Truco: un ASOF JOIN sobre la población acumulada.
--    · los 20 000 primeros contadores (los de los ficheros JSON del módulo 2) se
--      sortean dentro del territorio de su metrópoli destinataria;
--    · los 980 000 restantes en toda Francia (el cambio de escala del módulo 6).
--  Reparto calibrado sobre un parque francés de distribución: ~98,7 % de C5 (≤ 36 kVA),
--  ~1,1 % de C4 (36 a 250 kVA), ~0,2 % de C2 (HTA). Los hogares están sobre todo en 6 y 9 kVA.
--
--  Cómo funciona el sorteo en proporción a la población:
--    1. ordenamos los municipios y acumulamos su población (función de ventana);
--    2. cada contador saca un "ticket" entre 0 y la población total;
--    3. ASOF JOIN busca el PRIMER municipio cuyo acumulado supera el ticket.
--  Una ciudad grande ocupa un intervalo de acumulado grande: sale más a menudo.
CREATE OR REPLACE TABLE ref.contador
(
    id_contador             UInt64,                  -- 14 cifras caben en 8 bytes
    codigo_insee         String,
    segmento            LowCardinality(String),  -- C5 / C4 / C2
    perfil             LowCardinality(String),  -- RES (residencial) / PRO (profesional) / ENT (empresa)
    potencia_kva      UInt16,
    tarifa              LowCardinality(String),
    fv_kwp             Float32,                 -- potencia fotovoltaica instalada (0 = sin producción)
    fecha_alta  Date
)
ENGINE = MergeTree
ORDER BY id_contador
SETTINGS min_bytes_for_wide_part = 0;   -- una columna = un fichero, para leer la compresión columna a columna (paso 8)

INSERT INTO ref.contador
WITH
    zonas AS
    (
        -- 'FR' = toda Francia; si no, el código del EPCI de una metrópoli destinataria
        SELECT 'FR' AS zona, codigo_insee, poblacion FROM ref.municipio WHERE poblacion > 0
        UNION ALL
        SELECT codigo_epci, codigo_insee, poblacion FROM ref.municipio
        WHERE poblacion > 0 AND codigo_epci IN (SELECT codigo_epci FROM ref.destinatario)
    ),
    acumulado AS
    (
        SELECT zona, codigo_insee,
               sum(poblacion) OVER (PARTITION BY zona ORDER BY codigo_insee ROWS UNBOUNDED PRECEDING) AS pob_acumulada
        FROM zonas
    ),
    pob_zona AS (SELECT zona, sum(poblacion) AS pob FROM zonas GROUP BY zona),
    sorteo AS
    (
        SELECT
            z.zona                                                    AS zona,
            n.number                                                  AS n,
            10000000000000 + n.number * 4093 + cityHash64(n.number) % 4093 AS id_contador,
            cityHash64(n.number, 'commune') % z.pob                    AS ticket,
            cityHash64(n.number, 'segment') % 1000                     AS r_seg,
            cityHash64(n.number, 'detail')  % 1000                     AS r_det,
            cityHash64(n.number, 'pv')      % 1000                     AS r_pv
        FROM numbers(1000000) AS n
        LEFT JOIN ref.destinatario AS d ON d.id_destinatario = if(n.number < 20000, sim_destinatario(intDiv(n.number, 1000)), '')
        INNER JOIN pob_zona AS z ON z.zona = if(n.number < 20000, d.codigo_epci, 'FR')
    )
SELECT
    t.id_contador,
    c.codigo_insee,
    multiIf(t.r_seg < 987, 'C5', t.r_seg < 998, 'C4', 'C2')                         AS segmento,
    multiIf(segmento = 'C5' AND t.r_det < 880, 'RES', segmento = 'C2', 'ENT', 'PRO')  AS perfil,
    multiIf(perfil = 'RES', multiIf(t.r_det % 100 < 4, 3, t.r_det % 100 < 44, 6, t.r_det % 100 < 77, 9,
                                    t.r_det % 100 < 90, 12, t.r_det % 100 < 95, 15, t.r_det % 100 < 98, 18,
                                    t.r_det % 100 < 99, 24, 36),                       -- 40 % en 6 kVA, 33 % en 9 kVA
            segmento = 'C5', [9, 12, 18, 24, 36][1 + t.r_det % 5],
            segmento = 'C4', 37 + t.r_det % 214,
            250 + t.r_det)                                                             AS potencia_kva,
    multiIf(segmento = 'C5', ['BASE', 'BASE', 'BASE', 'HPHC', 'HPHC', 'TEMPO'][1 + t.r_det % 6],
            segmento = 'C4', ['CU4', 'MU4'][1 + t.r_det % 2],
            'HTA5')                                                                     AS tarifa,
    multiIf(perfil = 'RES' AND t.r_pv < 40, toFloat32([3, 4.5, 6, 9][1 + t.r_pv % 4]),   -- ~4 % de los hogares tienen solar
            perfil = 'PRO' AND t.r_pv < 50, toFloat32(9 + t.r_pv % 27),
            perfil = 'ENT' AND t.r_pv < 30, toFloat32(100 + t.r_pv * 3),
            toFloat32(0))                                                               AS fv_kwp,
    toDate('1995-01-01') + cityHash64(t.n, 'date') % 11000                             AS fecha_alta
FROM sorteo AS t
ASOF JOIN acumulado AS c ON t.zona = c.zona AND t.ticket < c.pob_acumulada;   -- el 1.er municipio de la zona cuyo acumulado supera el ticket
-- Medido: 532 ms · 1,1 M filas leídas (9,5 MB) · 1 M filas escritas · 145 MB de memoria

SELECT segmento, perfil, count() AS n_contadores, round(avg(potencia_kva), 1) AS kva_medio, countIf(fv_kwp > 0) AS n_con_fv
FROM ref.contador
GROUP BY segmento, perfil
ORDER BY n_contadores DESC;
-- Medido: 14 ms · 1 M filas leídas (4,1 MB) · 172,4 MB de memoria
-- Qué observar: un millón de filas generadas y unidas en menos de un segundo.
-- countIf solo cuenta las filas que cumplen la condición: no hace falta CASE WHEN.

--  Los 20 000 contadores de los ficheros JSON están en su destinatario:
SELECT d.nombre AS destinatario, count() AS contador
FROM ref.contador AS p
INNER JOIN ref.municipio     AS c ON c.codigo_insee = p.codigo_insee
INNER JOIN ref.destinatario AS d ON d.codigo_epci = c.codigo_epci
WHERE p.id_contador < 10000000000000 + 20000 * 4093
GROUP BY destinatario
ORDER BY contador DESC;
-- Medido: 9 ms · 59 551 filas leídas (1 MB)


-- PASO 7 · El historial de potencias contratadas (para el módulo 4)
--  ~3 % de los contadores aumentaron su potencia durante el mes de octubre.
--  Una fila por periodo de validez [valid_from, valid_to].
--  ARRAY JOIN "despliega" un array: una fila con un array de 2 elementos
--  se convierte en 2 filas. Es la herramienta central para leer los JSON de medida (módulo 3).
CREATE OR REPLACE TABLE ref.historial_contador
(
    id_contador         UInt64,
    valid_from     Date,
    valid_to       Date,
    potencia_kva  UInt16
)
ENGINE = MergeTree
ORDER BY (id_contador, valid_from);

INSERT INTO ref.historial_contador
SELECT id_contador, valid_from, valid_to, potencia_kva
FROM
(
    SELECT
        id_contador,
        potencia_kva,
        fecha_alta,
        cityHash64(id_contador, 'chgt') % 100 < 3 AND potencia_kva >= 6 AS cambio,   -- el cliente aumentó su potencia
        toDate('2026-10-05') + cityHash64(id_contador, 'j') % 20 AS fecha_cambio
    FROM ref.contador
)
ARRAY JOIN
    if(cambio, [fecha_alta, fecha_cambio], [fecha_alta])                         AS valid_from,
    if(cambio, [fecha_cambio - 1, toDate('2099-12-31')], [toDate('2099-12-31')])              AS valid_to,
    if(cambio, [toUInt16(if(potencia_kva <= 36, potencia_kva - 3, intDiv(potencia_kva * 2, 3))), potencia_kva], [potencia_kva]) AS potencia_kva;
-- Medido: 258 ms · 1 M filas leídas (11,4 MB) · 1 M filas escritas · 106,5 MB de memoria

SELECT count() AS filas, uniqExact(id_contador) AS contador, countIf(valid_to < '2099-01-01') AS cambios
FROM ref.historial_contador;
-- Medido: 18 ms · 1 M filas leídas (9,8 MB) · 93,7 MB de memoria


-- PASO 8 · Bajo el capó: parts, compresión, índice
--  Cada INSERT escribe una "part": un pequeño lote de ficheros inmutable, ya ordenado.
--  En segundo plano, ClickHouse fusiona (merge) las parts entre sí, de ahí el nombre
--  MergeTree. system.parts muestra el estado real del almacenamiento.
SELECT table, count() AS n_parts, sum(rows) AS filas,
       formatReadableSize(sum(data_uncompressed_bytes)) AS bruto,
       formatReadableSize(sum(data_compressed_bytes))   AS comprimido,
       round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio
FROM system.parts
WHERE database = 'ref' AND active
GROUP BY table
ORDER BY filas DESC;

--  Compresión columna a columna
--  Atención: en Cloud, una part de menos de 1 GB es "compacta" (todas las
--  columnas en un solo fichero) y sus tamaños por columna aparecen a 0.
--  ref.contador se crea con min_bytes_for_wide_part = 0 para poder leerlos aquí.
--  Qué observar: las columnas LowCardinality (segmento, perfil) se comprimen
--  mucho mejor que las columnas de texto libre.
SELECT name, type,
       formatReadableSize(data_compressed_bytes)   AS comprimido,
       formatReadableSize(data_uncompressed_bytes) AS bruto,
       round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio
FROM system.columns
WHERE database = 'ref' AND table = 'contador'
ORDER BY data_compressed_bytes DESC;

--  El índice disperso: ClickHouse no indexa cada fila, sino una de cada
--  8192 (un "granule"). Así el índice cabe en memoria, incluso con miles de
--  millones de filas. En una búsqueda, identifica los granules útiles y solo lee esos.
EXPLAIN indexes = 1
SELECT * FROM ref.contador WHERE id_contador = 10000000006899;

--  Compara: filtro sobre la clave (rápido) frente a fuera de la clave (scan completo)
SELECT * FROM ref.contador WHERE id_contador = 10000000006899;     -- filtro sobre la clave: 1 granule leído
-- Medido: 4 ms · 8 192 filas leídas (64 KB)
SELECT count() FROM ref.contador WHERE codigo_insee = '92063';  -- Rueil-Malmaison, fuera de la clave: se lee toda la tabla
-- Medido: 7 ms · 1 M filas leídas (7,6 MB)
-- Qué observar: "rows read" abajo en la consola. 8 192 filas leídas en la primera,
-- 1 000 000 en la segunda. Con mil millones de filas, la diferencia sería proporcionalmente la misma.


-- CHECKPOINT MÓDULO 1
--  Cada columna debe mostrar OK. Si ves un ERROR: vuelve a ejecutar el fichero (es idempotente).
SELECT
    if((SELECT count() FROM ref.municipio) > 34000, 'OK', 'ERROR') AS municipios,
    if((SELECT count() FROM ref.contador) = 1000000,   'OK', 'ERROR') AS contador,
    if((SELECT count() FROM ref.historial_contador) > 1000000, 'OK', 'ERROR') AS historial,
    if((SELECT count() FROM ref.destinatario) = 6, 'OK', 'ERROR') AS destinatarios,
    if((SELECT count() FROM ref.contador AS p INNER JOIN ref.municipio AS c ON c.codigo_insee = p.codigo_insee
        WHERE p.id_contador < 10000000000000 + 20000 * 4093
          AND c.codigo_epci IN (SELECT codigo_epci FROM ref.destinatario)) = 20000, 'OK', 'ERROR') AS contadores_en_destinatario
SETTINGS select_sequential_consistency = 1;   -- leer la última versión, sea cual sea la réplica
