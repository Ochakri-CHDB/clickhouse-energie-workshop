-- =====================================================================
--  MÓDULO 4 · Diccionarios: los datos de referencia en memoria
-- =====================================================================
--  Un diccionario = una tabla clave → valores cargada en RAM.
--  dictGet() sustituye a una join: una búsqueda en O(1) por fila.
--  ¿Por qué es mejor que un JOIN repetido? Un JOIN reconstruye una tabla hash
--  en CADA consulta. El diccionario la construye una vez, la mantiene en
--  memoria y la recarga según LIFETIME (regla query-join-use-dictionaries).
--  No usa la memoria de la consulta, lo que protege los escaneos grandes.
-- =====================================================================


-- PASO 1 · El diccionario de municipios (clave de texto: COMPLEX_KEY_HASHED)
--  SOURCE indica dónde leer los datos, LAYOUT cómo organizarlos en memoria,
--  LIFETIME cuándo recargarlos. En Cloud, la fuente CLICKHOUSE debe declarar
--  un usuario: usamos dict_reader, de solo lectura (módulo 1).
CREATE OR REPLACE DICTIONARY ref.dict_municipio
(
    codigo_ine   String,
    nombre          String,
    codigo_provincia    String,
    codigo_ccaa  String,
    codigo_area    String,
    poblacion   UInt32
)
PRIMARY KEY codigo_ine
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'municipio' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 3600 MAX 7200);          -- se recarga cada 1 a 2 h


-- PASO 2 · El diccionario de contadores (clave numérica: HASHED, el más rápido)
CREATE OR REPLACE DICTIONARY ref.dict_contador
(
    id_contador         UInt64,
    codigo_ine     String,
    segmento        String,
    perfil         String,
    potencia_kva  UInt16,
    tarifa          String,
    fv_kwp         Float32
)
PRIMARY KEY id_contador
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'contador' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(HASHED_ARRAY())                -- variante de HASHED, más ahorradora cuando hay muchos atributos
LIFETIME(MIN 3600 MAX 7200);


-- PASO 3 · La potencia contratada "a fecha" (RANGE_HASHED)
--  Para una clave Y una fecha, encuentra la fila válida en ese momento.
--  Justo lo que hace falta para comparar una PMax con la potencia contratada
--  el día de la medida, y no con la potencia actual.
CREATE OR REPLACE DICTIONARY ref.dict_potencia_asof
(
    id_contador         UInt64,
    valid_from     Date,
    valid_to       Date,
    potencia_kva  UInt16
)
PRIMARY KEY id_contador
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'historial_contador' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(RANGE_HASHED())
RANGE(MIN valid_from MAX valid_to)
LIFETIME(MIN 3600 MAX 7200);

--  Nombres de las áreas urbanas y de las provincias
CREATE OR REPLACE DICTIONARY ref.dict_area (codigo_area String, nombre String)
PRIMARY KEY codigo_area
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'area' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED()) LIFETIME(86400);

CREATE OR REPLACE DICTIONARY ref.dict_provincia (codigo_provincia String, nombre String, codigo_ccaa String)
PRIMARY KEY codigo_provincia
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'provincia' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED()) LIFETIME(86400);


-- PASO 4 · Uso: un contador, toda su ficha, en una fila
--  Los dictGet se encadenan: contador → municipio → provincia. Ningún JOIN.
SELECT
    sim_id_contador(42)                                                              AS id_contador,
    dictGet('ref.dict_contador', 'segmento', id_contador)                                  AS segmento,
    dictGet('ref.dict_contador', 'potencia_kva', id_contador)                            AS kva_actual,
    dictGet('ref.dict_contador', 'codigo_ine', id_contador)                               AS codigo_ine,
    dictGet('ref.dict_municipio', 'nombre', codigo_ine)                              AS municipio,
    dictGet('ref.dict_provincia', 'nombre', dictGet('ref.dict_municipio', 'codigo_provincia', codigo_ine)) AS provincia,
    dictGet('ref.dict_area', 'nombre', dictGet('ref.dict_municipio', 'codigo_area', codigo_ine))       AS area;
-- Medido: 3 ms · 1 fila leída


-- PASO 5 · La potencia que cambia con el tiempo
--  Tomemos un contador que cambió de potencia en octubre
SELECT id_contador, valid_from, valid_to, potencia_kva
FROM ref.historial_contador
WHERE id_contador IN (SELECT id_contador FROM ref.historial_contador WHERE valid_to = '2026-10-14' ORDER BY id_contador LIMIT 1)
ORDER BY valid_from;
-- Medido: 8 ms · 991 232 filas leídas (9,5 MB)

SELECT
    dia,
    dictGet('ref.dict_potencia_asof', 'potencia_kva', p.id_contador, dia) AS kva_a_fecha
FROM (SELECT id_contador FROM ref.historial_contador WHERE valid_to = '2026-10-14' ORDER BY id_contador LIMIT 1) AS p
CROSS JOIN (SELECT toDate('2026-10-12') + number AS dia FROM numbers(5)) AS j;
-- Medido: 8 ms · 983 045 filas leídas (9,4 MB)
-- Qué observar: el día 15 se aplica la nueva potencia. Imprescindible para las
-- alertas de exceso del módulo 5.


-- PASO 6 · Diccionario vs JOIN: mismo resultado, compara los tiempos
--  Energía del mes por provincia. sum(valor_w) * 0.5: una potencia media
--  sobre media hora × 0,5 h = una energía en Wh.
SELECT
    dictGet('ref.dict_municipio', 'codigo_provincia', dictGet('ref.dict_contador', 'codigo_ine', id_contador)) AS codigo_provincia,
    round(sum(valor_w) * 0.5 / 1e6) AS mwh
FROM silver.curva_carga
WHERE magnitud = 'CONS'
GROUP BY codigo_provincia
ORDER BY mwh DESC
LIMIT 10;
-- Medido: 158 ms · 29,8 M filas leídas (369,5 MB) · 191,7 MB de memoria

SELECT
    c.codigo_provincia AS codigo_provincia,
    round(sum(s.valor_w) * 0.5 / 1e6) AS mwh
FROM silver.curva_carga AS s
INNER JOIN ref.contador     AS p ON p.id_contador = s.id_contador
INNER JOIN ref.municipio AS c ON c.codigo_ine = p.codigo_ine
WHERE s.magnitud = 'CONS'
GROUP BY codigo_provincia
ORDER BY mwh DESC
LIMIT 10;
-- Medido: 278 ms · 30,8 M filas leídas (384,9 MB) · 281,9 MB de memoria
-- Qué observar: mismo resultado. Compara la duración y la memoria en la parte inferior
-- de la consola: el JOIN tiene que cargar antes ref.contador y ref.municipio en memoria,
-- el diccionario no.
-- Solo salen 6 provincias: los ficheros JSON cubren los 20 000 contadores de las
-- 6 áreas urbanas destinatarias. Madrid (28) va muy por delante con unos 10 900 MWh,
-- luego Barcelona (08), Sevilla (41), Valencia (46), Málaga (29) y Bizkaia (48, Bilbao).


-- PASO 7 · Calidad: ¿hay contadores que no estén en los datos de referencia?
--  dictHas devuelve 0 si la clave no existe: un control de calidad en una línea.
SELECT count() AS puntos_contador_desconocido
FROM silver.curva_carga
WHERE NOT dictHas('ref.dict_contador', id_contador);
-- Medido: 23 ms · 31 M filas leídas (236,8 MB)


-- PASO 8 · Lo que cuesta en memoria
--  Qué observar: unos 87 MiB para 1 millón de contadores, 4 MiB para los 8 132
--  municipios, unos KiB para las 52 provincias y las 86 áreas urbanas. El diccionario
--  "a fecha" es más grande (unos 345 MiB) porque guarda intervalos por clave.
SELECT name, status, type, element_count, formatReadableSize(bytes_allocated) AS memoria, loading_duration
FROM system.dictionaries
WHERE database = 'ref';


-- PARA IR MÁS LEJOS · Coincidencia aproximada de nombres (direcciones mal escritas)
--  ngramDistance mide el parecido entre dos textos (0 = idénticos):
--  encuentra "Alcalá de Henares" a pesar de la errata (sin tilde y sin H).
SELECT nombre, codigo_ine, round(ngramDistanceCaseInsensitiveUTF8(replaceAll(nombre, '-', ' '), 'Alcala de Enares'), 3) AS distancia
FROM ref.municipio
ORDER BY distancia ASC
LIMIT 3;
-- Medido: 4 ms · 16 264 filas leídas (251 KB)
-- Qué observar: Alcalá de Henares (28005) sale primero con 0,379, por delante de
-- Tórtola de Henares (0,467) y Azuqueca de Henares (0,484).


-- CHECKPOINT
SELECT
    if((SELECT element_count FROM system.dictionaries WHERE database = 'ref' AND name = 'dict_contador') = 1000000, 'OK', 'ERROR') AS dict_contador,
    if((SELECT status FROM system.dictionaries WHERE database = 'ref' AND name = 'dict_potencia_asof') = 'LOADED', 'OK', 'ERROR') AS dict_asof,
    if(dictGet('ref.dict_municipio', 'nombre', '28005') = 'Alcalá de Henares', 'OK', 'ERROR') AS dict_municipio
SETTINGS select_sequential_consistency = 1;   -- leer la última versión, sea cual sea la réplica
