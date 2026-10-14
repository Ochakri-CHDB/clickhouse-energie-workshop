-- =====================================================================
--  MÓDULO 1 · Fundamentos: bases de datos, MergeTree y datos de referencia
-- =====================================================================
--  Creamos las 4 capas del pipeline y los datos de referencia:
--    ref     → municipios, provincias, comunidades autónomas y áreas urbanas
--              (datos abiertos reales del INE y del Ministerio de Transportes),
--              contadores, entidades locales destinatarias
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


-- PASO 3 · Los municipios de España, leídos EN DIRECTO desde los datos abiertos oficiales
--  url() lee un recurso HTTP como una tabla. El formato JSONEachRow le dice
--  a ClickHouse cómo dividir la respuesta: un objeto JSON = una fila.
--  La base de datos lee el recurso ella misma, dentro de la consulta.
--  Fuentes públicas, sin clave de acceso:
--    · INE (API JSON): el padrón municipal, población a 1 de enero de 2025
--    · INE (API JSON): las provincias y las comunidades autónomas
--    · Ministerio de Transportes (SIU): el centroide de cada municipio y las Grandes Áreas Urbanas
--  El INE devuelve cada municipio con un array MetaData (municipio, sexo…)
--  y un array Data con los valores: arrayFirst toma el elemento del municipio.
SELECT arrayFirst(m -> m.T3_Variable = 'Municipios', MetaData).Codigo AS codigo_ine,
       arrayFirst(m -> m.T3_Variable = 'Municipios', MetaData).Nombre AS nombre,
       Data[1].Valor AS poblacion
FROM url('https://servicios.ine.es/wstempus/js/ES/DATOS_TABLA/29005?nult=1&tip=AM&tv=18:451', JSONEachRow,
         'MetaData Array(Tuple(T3_Variable String, Nombre String, Codigo String)), Data Array(Tuple(Anyo UInt16, Valor Nullable(Float64)))')
LIMIT 5;
-- Medido: 874 ms · 5 filas leídas (2,8 KB)
-- Qué observar: el código INE tiene 5 cifras, provincia (2) + municipio (3):
-- Ababuj (44001) está en la provincia 44, Teruel. Ningún fichero descargado a mano.


-- PASO 4 · Nuestra primera tabla MergeTree
--  MergeTree es el motor básico de ClickHouse. Dos cosas que recordar:
--    · ORDER BY fija el orden físico de las filas en disco Y el índice
--      primario. Ya no se puede cambiar después: se elige según los
--      filtros más frecuentes (regla schema-pk-plan-before-creation).
--    · cada columna se almacena y se comprime por separado (almacenamiento columnar):
--      una consulta solo lee las columnas que utiliza.

--  Primero, las comunidades autónomas y las provincias (INE). Cada provincia
--  apunta a su comunidad por el Id interno del INE (FK_JerarquiaPadres, un array):
--  ARRAY JOIN lo despliega y el JOIN recupera el código de la comunidad.
--  El WHERE descarta las entradas que no son ni provincia ni comunidad.
CREATE OR REPLACE TABLE ref.ccaa (codigo_ccaa String, nombre String) ENGINE = MergeTree ORDER BY codigo_ccaa;
INSERT INTO ref.ccaa SELECT Codigo, Nombre
FROM url('https://servicios.ine.es/wstempus/js/ES/VALORES_VARIABLE/70', JSONEachRow, 'Id UInt32, Codigo String, Nombre String')
WHERE match(Codigo, '^[0-9]{2}$') AND Codigo BETWEEN '01' AND '19';
-- Medido: 856 ms · 29 filas leídas (3,1 KB) · 19 filas escritas
-- Qué observar: 19 comunidades autónomas, las 17 más Ceuta y Melilla.

CREATE OR REPLACE TABLE ref.provincia (codigo_provincia String, nombre String, codigo_ccaa String) ENGINE = MergeTree ORDER BY codigo_provincia;
INSERT INTO ref.provincia
SELECT p.Codigo, p.Nombre, c.Codigo
FROM url('https://servicios.ine.es/wstempus/js/ES/VALORES_VARIABLE/115', JSONEachRow, 'Codigo String, Nombre String, FK_JerarquiaPadres Array(UInt32)') AS p
ARRAY JOIN p.FK_JerarquiaPadres AS padre
INNER JOIN url('https://servicios.ine.es/wstempus/js/ES/VALORES_VARIABLE/70', JSONEachRow, 'Id UInt32, Codigo String') AS c ON c.Id = padre
WHERE match(p.Codigo, '^[0-9]{2}$') AND p.Codigo != '00' AND c.Codigo BETWEEN '01' AND '19';
-- Medido: 2,07 s · 90 filas leídas (8,7 KB) · 52 filas escritas
-- Qué observar: 52 provincias, las 50 más Ceuta y Melilla.

--  Una Gran Área Urbana es la delimitación oficial del Ministerio de Transportes
--  (Atlas de las Áreas Urbanas): una ciudad de más de 50 000 habitantes y los
--  municipios de su aglomeración. Hay 86, y hacen aquí el papel de las metrópolis:
--  cada entidad local destinataria de los flujos es un área urbana (paso 5).
--
--  Ninguna tabla dice qué municipios contiene cada área: lo calculamos con
--  pointInPolygon((lon, lat), polígono), que devuelve 1 si el punto está dentro.
--  Probamos el centroide de cada municipio frente a los polígonos de las 86 áreas:
--    · primero un filtro rápido por rectángulo (x0..x1, y0..y1): descarta casi todos
--      los pares municipio × área sin hacer ningún cálculo geométrico;
--    · después el test exacto, anillo por anillo. Un área puede tener varios trozos
--      y huecos (los anillos de Esri mezclan contornos y huecos): el punto está
--      dentro si cae en un número IMPAR de anillos (regla par-impar).
CREATE OR REPLACE TABLE ref.area (codigo_area String, nombre String) ENGINE = MergeTree ORDER BY codigo_area;
INSERT INTO ref.area SELECT f.attributes.COD_AU, f.attributes.NOMBRE_AU
FROM url('https://mapas.fomento.gob.es/arcgis/rest/services/SIU/Unidades_administrativas_visorSIU/FeatureServer/1/query?where=1%3D1&outFields=COD_AU%2CNOMBRE_AU&returnGeometry=false&f=json',
         JSONEachRow, 'features Array(Tuple(attributes Tuple(COD_AU String, NOMBRE_AU String)))')
ARRAY JOIN features AS f;
-- Medido: 375 ms · 1 fila leída (6,5 KB) · 86 filas escritas
-- Qué observar: 1 fila leída. El servicio devuelve un solo objeto JSON con un array
-- features: ARRAY JOIN lo convierte en 86 filas ('001' es Madrid, '002' Barcelona…).

CREATE OR REPLACE TABLE ref.municipio_area (codigo_ine String, codigo_area String) ENGINE = MergeTree ORDER BY codigo_ine;
INSERT INTO ref.municipio_area
WITH
    puntos AS
    (
        SELECT f.attributes.CodINE AS codigo_ine, f.centroid.x AS lon, f.centroid.y AS lat
        FROM url('https://mapas.fomento.gob.es/arcgis/rest/services/SIU/Unidades_administrativas_visorSIU/FeatureServer/3/query?where=1%3D1&outFields=CodINE&returnGeometry=false&returnCentroid=true&outSR=4326&orderByFields=OBJECTID&resultRecordCount=2000&resultOffset={0,2000,4000,6000,8000}&f=json',
                 JSONEachRow, 'features Array(Tuple(attributes Tuple(CodINE String), centroid Tuple(x Float64, y Float64)))')
        ARRAY JOIN features AS f   -- 2 000 municipios por página: el glob {…} pide las 5 páginas
    ),
    areas AS
    (
        SELECT f.attributes.COD_AU AS codigo_area,
               arrayMap(r -> arrayMap(p -> (p[1], p[2]), r), f.geometry.rings) AS anillos,
               arrayReduce('min', arrayMap(p -> p.1, arrayFlatten(anillos))) AS x0,
               arrayReduce('max', arrayMap(p -> p.1, arrayFlatten(anillos))) AS x1,
               arrayReduce('min', arrayMap(p -> p.2, arrayFlatten(anillos))) AS y0,
               arrayReduce('max', arrayMap(p -> p.2, arrayFlatten(anillos))) AS y1
        FROM url('https://mapas.fomento.gob.es/arcgis/rest/services/SIU/Unidades_administrativas_visorSIU/FeatureServer/1/query?where=1%3D1&outFields=COD_AU&outSR=4326&f=json',
                 JSONEachRow, 'features Array(Tuple(attributes Tuple(COD_AU String), geometry Tuple(rings Array(Array(Array(Float64))))))')
        ARRAY JOIN features AS f
    )
SELECT p.codigo_ine, a.codigo_area
FROM puntos AS p CROSS JOIN areas AS a
WHERE p.lon BETWEEN a.x0 AND a.x1 AND p.lat BETWEEN a.y0 AND a.y1
  AND arrayCount(r -> pointInPolygon((p.lon, p.lat), r), a.anillos) % 2 = 1;
-- Medido: 8,97 s · 6 filas leídas (15,8 MB) · 756 filas escritas · 96,1 MB de memoria
-- Qué observar: 6 respuestas JSON (5 páginas de municipios + los polígonos, 15,8 MB)
-- y 756 municipios dentro de un área urbana. Una unión espacial completa, en SQL,
-- sin extensión ni herramienta SIG.

--  La tabla de municipios, por fin: padrón del INE + centroide + área urbana.
--  Tres LEFT JOIN sobre el código INE. Los municipios fuera de un área urbana
--  (la gran mayoría) se quedan con codigo_area = ''.
CREATE OR REPLACE TABLE ref.municipio
(
    codigo_ine        String,                   -- 5 cifras: provincia (2) + municipio (3)
    nombre            String,
    codigo_provincia  LowCardinality(String),   -- 52 valores distintos: se guardan una vez, luego números (regla: menos de 10 000 valores)
    codigo_ccaa       LowCardinality(String),
    codigo_area       String,                   -- '' fuera de las áreas urbanas (regla schema-types-avoid-nullable)
    poblacion         UInt32,                   -- el tipo entero más pequeño que basta
    lon               Float32,
    lat               Float32
)
ENGINE = MergeTree
ORDER BY codigo_ine;

INSERT INTO ref.municipio
WITH
    padron AS
    (
        SELECT arrayFirst(m -> m.T3_Variable = 'Municipios', MetaData).Codigo AS codigo_ine,
               arrayFirst(m -> m.T3_Variable = 'Municipios', MetaData).Nombre AS nombre,
               toUInt32(Data[1].Valor) AS poblacion
        FROM url('https://servicios.ine.es/wstempus/js/ES/DATOS_TABLA/29005?nult=1&tip=AM&tv=18:451', JSONEachRow,
                 'MetaData Array(Tuple(T3_Variable String, Nombre String, Codigo String)), Data Array(Tuple(Anyo UInt16, Valor Nullable(Float64)))')
        WHERE Data[1].Valor IS NOT NULL   -- 6 municipios desaparecidos no tienen dato en 2025
    ),
    centroides AS
    (
        SELECT f.attributes.CodINE AS codigo_ine, f.centroid.x AS lon, f.centroid.y AS lat
        FROM url('https://mapas.fomento.gob.es/arcgis/rest/services/SIU/Unidades_administrativas_visorSIU/FeatureServer/3/query?where=1%3D1&outFields=CodINE&returnGeometry=false&returnCentroid=true&outSR=4326&orderByFields=OBJECTID&resultRecordCount=2000&resultOffset={0,2000,4000,6000,8000}&f=json',
                 JSONEachRow, 'features Array(Tuple(attributes Tuple(CodINE String), centroid Tuple(x Float64, y Float64)))')
        ARRAY JOIN features AS f
    )
SELECT p.codigo_ine, p.nombre, substring(p.codigo_ine, 1, 2), pr.codigo_ccaa, a.codigo_area, p.poblacion, c.lon, c.lat
FROM padron AS p
LEFT JOIN ref.provincia      AS pr ON pr.codigo_provincia = substring(p.codigo_ine, 1, 2)
LEFT JOIN centroides         AS c  ON c.codigo_ine = p.codigo_ine
LEFT JOIN ref.municipio_area AS a  ON a.codigo_ine = p.codigo_ine
SETTINGS join_use_nulls = 0;   -- sin coincidencia: '' o 0, nunca NULL
-- Medido: 4,84 s · 8 951 filas leídas (5,4 MB) · 8 132 filas escritas · 51,3 MB de memoria
--  Plan B si una fuente no responde: la misma tabla está en el repo, con codigo_area ya
--  calculado (provincias.csv, ccaa.csv y areas.csv, en data/es/, se cargan igual)
--  INSERT INTO ref.municipio SELECT * FROM url('https://raw.githubusercontent.com/Ochakri-CHDB/clickhouse-energie-workshop/main/data/es/municipios.csv', CSVWithNames);

SELECT count() AS n_municipios, sum(poblacion) AS poblacion_total FROM ref.municipio;
-- Medido: 24 ms · 8 132 filas leídas (31,8 KB)
-- Qué observar: 8 132 municipios y 49 114 494 habitantes (padrón a 1 de enero de 2025).
-- Atención: Usansolo (48916), municipio nuevo en 2025, aún no tiene centroide en la
-- capa del ministerio: su lon/lat vale 0 y no pertenece a ningún área urbana.


-- PASO 5 · Las entidades locales destinatarias de los flujos
--  Cada fichero de la distribuidora va dirigido a un destinatario (idDestinatario).
--  Vinculamos cada uno a su Gran Área Urbana (codigo_area), lo que permitirá
--  filtrar por territorio.
CREATE OR REPLACE TABLE ref.destinatario
(
    id_destinatario String,
    nombre             String,
    codigo_area       String
)
ENGINE = MergeTree
ORDER BY id_destinatario;

INSERT INTO ref.destinatario VALUES
    ('488903', 'Área Urbana de Madrid',    '001'),
    ('488904', 'Área Urbana de Barcelona', '002'),
    ('488905', 'Área Urbana de Valencia',  '003'),
    ('488906', 'Área Urbana de Sevilla',   '004'),
    ('488907', 'Área Urbana de Bilbao',    '005'),
    ('488908', 'Área Urbana de Málaga',    '006');

--  Los 20 ficheros de un día (lotes de 1000 contadores) se reparten entre las
--  6 áreas urbanas. Madrid se lleva 12: es el territorio que seguiremos en los
--  módulos 7 y 8. Una entidad local SOLO recibe los contadores de su territorio:
--  lo tenemos en cuenta desde el sorteo.
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
-- Qué observar: 12 lotes (12 000 contadores) para Madrid (488903), 2 para Barcelona,
-- Valencia y Sevilla, 1 para Bilbao y Málaga.


-- PASO 6 · El parque de contadores: 1 millón de contadores generados
--  Cada contador se asigna a un municipio, sorteado en proporción a su
--  población. Truco: un ASOF JOIN sobre la población acumulada.
--    · los 20 000 primeros contadores (los de los ficheros JSON del módulo 2) se
--      sortean dentro del territorio de su área urbana destinataria;
--    · los 980 000 restantes en toda España (el cambio de escala del módulo 6).
--  Reparto calibrado sobre un parque de distribución real: ~98,7 % de C5 (≤ 36 kVA),
--  ~1,1 % de C4 (36 a 250 kVA), ~0,2 % de C2 (HTA). Los hogares están sobre todo en 6 y 9 kVA.
--  Simplificación: Canarias va una hora por detrás de la Península, pero la simulación
--  usa la hora peninsular (Europe/Madrid) para todos los contadores.
--
--  Cómo funciona el sorteo en proporción a la población:
--    1. ordenamos los municipios y acumulamos su población (función de ventana);
--    2. cada contador saca un "ticket" entre 0 y la población total;
--    3. ASOF JOIN busca el PRIMER municipio cuyo acumulado supera el ticket.
--  Una ciudad grande ocupa un intervalo de acumulado grande: sale más a menudo.
CREATE OR REPLACE TABLE ref.contador
(
    id_contador             UInt64,                  -- 14 cifras caben en 8 bytes
    codigo_ine         String,
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
        -- 'ES' = toda España; si no, el código del área urbana de un destinatario
        SELECT 'ES' AS zona, codigo_ine, poblacion FROM ref.municipio WHERE poblacion > 0
        UNION ALL
        SELECT codigo_area, codigo_ine, poblacion FROM ref.municipio
        WHERE poblacion > 0 AND codigo_area IN (SELECT codigo_area FROM ref.destinatario)
    ),
    acumulado AS
    (
        SELECT zona, codigo_ine,
               sum(poblacion) OVER (PARTITION BY zona ORDER BY codigo_ine ROWS UNBOUNDED PRECEDING) AS pob_acumulada
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
        INNER JOIN pob_zona AS z ON z.zona = if(n.number < 20000, d.codigo_area, 'ES')
    )
SELECT
    t.id_contador,
    c.codigo_ine,
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
-- Medido: 510 ms · 1 M filas leídas (7,9 MB) · 1 M filas escritas · 131,5 MB de memoria

SELECT segmento, perfil, count() AS n_contadores, round(avg(potencia_kva), 1) AS kva_medio, countIf(fv_kwp > 0) AS n_con_fv
FROM ref.contador
GROUP BY segmento, perfil
ORDER BY n_contadores DESC;
-- Medido: 14 ms · 1 M filas leídas (4,1 MB) · 172,4 MB de memoria
-- Qué observar: un millón de filas generadas y unidas en menos de un segundo.
-- 868 433 hogares (C5 RES, 8,8 kVA de media), 118 402 C5 PRO, 11 114 C4 y 2 051 C2.
-- countIf solo cuenta las filas que cumplen la condición: no hace falta CASE WHEN.

--  Los 20 000 contadores de los ficheros JSON están en su destinatario:
SELECT d.nombre AS destinatario, count() AS contador
FROM ref.contador AS p
INNER JOIN ref.municipio     AS c ON c.codigo_ine = p.codigo_ine
INNER JOIN ref.destinatario AS d ON d.codigo_area = c.codigo_area
WHERE p.id_contador < 10000000000000 + 20000 * 4093
GROUP BY destinatario
ORDER BY contador DESC;
-- Medido: 8 ms · 32 714 filas leídas (465,8 KB)
-- Qué observar: 12 000 en Madrid, 2 000 en Barcelona, Valencia y Sevilla, 1 000 en
-- Bilbao y Málaga. Ni uno fuera de su área urbana.


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
-- Medido: 266 ms · 1 M filas leídas (11,4 MB) · 1 M filas escritas · 106,5 MB de memoria

SELECT count() AS filas, uniqExact(id_contador) AS contador, countIf(valid_to < '2099-01-01') AS cambios
FROM ref.historial_contador;
-- Medido: 20 ms · 1 M filas leídas (9,8 MB) · 93,7 MB de memoria
-- Qué observar: 1 028 889 filas para 1 000 000 de contadores: 28 889 cambios (~3 %).


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
-- Medido: 4 ms · 8 filas leídas
-- Qué observar: una sola part por tabla. ref.contador: 26,9 MiB en bruto, 6,9 MiB
-- en disco (×3,9).

--  Compresión columna a columna
--  Atención: en Cloud, una part de menos de 1 GB es "compacta" (todas las
--  columnas en un solo fichero) y sus tamaños por columna aparecen a 0.
--  ref.contador se crea con min_bytes_for_wide_part = 0 para poder leerlos aquí.
--  Qué observar: segmento (LowCardinality, 3 valores) se comprime ×32,8; codigo_ine,
--  texto con miles de valores, solo ×6,1. fecha_alta, casi aleatoria, apenas ×1,1.
SELECT name, type,
       formatReadableSize(data_compressed_bytes)   AS comprimido,
       formatReadableSize(data_uncompressed_bytes) AS bruto,
       round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio
FROM system.columns
WHERE database = 'ref' AND table = 'contador'
ORDER BY data_compressed_bytes DESC;
-- Medido: 2 ms · 8 filas leídas

--  El índice disperso: ClickHouse no indexa cada fila, sino una de cada
--  8192 (un "granule"). Así el índice cabe en memoria, incluso con miles de
--  millones de filas. En una búsqueda, identifica los granules útiles y solo lee esos.
EXPLAIN indexes = 1
SELECT * FROM ref.contador WHERE id_contador = 10000000006899;
-- Medido: 2 ms · 12 filas leídas

--  Compara: filtro sobre la clave (rápido) frente a fuera de la clave (scan completo)
SELECT * FROM ref.contador WHERE id_contador = 10000000006899;     -- filtro sobre la clave: 1 granule leído
-- Medido: 5 ms · 8 192 filas leídas (64 KB)
SELECT count() FROM ref.contador WHERE codigo_ine = '28005';  -- Alcalá de Henares, fuera de la clave: se lee toda la tabla
-- Medido: 6 ms · 1 M filas leídas (7,6 MB)
-- Qué observar: "rows read" abajo en la consola. 8 192 filas leídas en la primera,
-- 1 000 000 en la segunda (para encontrar los 4 463 contadores de Alcalá de Henares). Con mil millones de filas, la diferencia sería proporcionalmente la misma.


-- CHECKPOINT MÓDULO 1
--  Cada columna debe mostrar OK. Si ves un ERROR: vuelve a ejecutar el fichero (es idempotente).
SELECT
    if((SELECT count() FROM ref.municipio) > 8000, 'OK', 'ERROR') AS municipios,
    if((SELECT count() FROM ref.contador) = 1000000,   'OK', 'ERROR') AS contador,
    if((SELECT count() FROM ref.historial_contador) > 1000000, 'OK', 'ERROR') AS historial,
    if((SELECT count() FROM ref.destinatario) = 6, 'OK', 'ERROR') AS destinatarios,
    if((SELECT count() FROM ref.contador AS p INNER JOIN ref.municipio AS c ON c.codigo_ine = p.codigo_ine
        WHERE p.id_contador < 10000000000000 + 20000 * 4093
          AND c.codigo_area IN (SELECT codigo_area FROM ref.destinatario)) = 20000, 'OK', 'ERROR') AS contadores_en_destinatario
SETTINGS select_sequential_consistency = 1;   -- leer la última versión, sea cual sea la réplica
-- Medido: 37 ms · 32 719 filas leídas (465,7 KB)
