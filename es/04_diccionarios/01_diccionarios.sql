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
    codigo_insee   String,
    nombre          String,
    codigo_dpto    String,
    codigo_region  String,
    codigo_epci    String,
    poblacion   UInt32
)
PRIMARY KEY codigo_insee
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'municipio' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 3600 MAX 7200);          -- se recarga cada 1 a 2 h


-- PASO 2 · El diccionario de contadores (clave numérica: HASHED, el más rápido)
CREATE OR REPLACE DICTIONARY ref.dict_contador
(
    id_contador         UInt64,
    codigo_insee     String,
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

--  Nombres de los EPCI y de los departamentos
CREATE OR REPLACE DICTIONARY ref.dict_epci (codigo_epci String, nombre String)
PRIMARY KEY codigo_epci
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'epci' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED()) LIFETIME(86400);

CREATE OR REPLACE DICTIONARY ref.dict_departamento (codigo_dpto String, nombre String, codigo_region String)
PRIMARY KEY codigo_dpto
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'departamento' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED()) LIFETIME(86400);


-- PASO 4 · Uso: un contador, toda su ficha, en una fila
--  Los dictGet se encadenan: contador → municipio → departamento. Ningún JOIN.
SELECT
    sim_id_contador(42)                                                              AS id_contador,
    dictGet('ref.dict_contador', 'segmento', id_contador)                                  AS segmento,
    dictGet('ref.dict_contador', 'potencia_kva', id_contador)                            AS kva_actual,
    dictGet('ref.dict_contador', 'codigo_insee', id_contador)                               AS codigo_insee,
    dictGet('ref.dict_municipio', 'nombre', codigo_insee)                              AS municipio,
    dictGet('ref.dict_departamento', 'nombre', dictGet('ref.dict_municipio', 'codigo_dpto', codigo_insee)) AS departamento,
    dictGet('ref.dict_epci', 'nombre', dictGet('ref.dict_municipio', 'codigo_epci', codigo_insee))       AS epci;
-- Medido: 3 ms · 1 fila leída


-- PASO 5 · La potencia que cambia con el tiempo
--  Tomemos un contador que cambió de potencia en octubre
SELECT id_contador, valid_from, valid_to, potencia_kva
FROM ref.historial_contador
WHERE id_contador IN (SELECT id_contador FROM ref.historial_contador WHERE valid_to = '2026-10-14' LIMIT 1)
ORDER BY valid_from;
-- Medido: 9 ms · 991 232 filas leídas (9,5 MB)

SELECT
    dia,
    dictGet('ref.dict_potencia_asof', 'potencia_kva', p.id_contador, dia) AS kva_a_fecha
FROM (SELECT id_contador FROM ref.historial_contador WHERE valid_to = '2026-10-14' LIMIT 1) AS p
CROSS JOIN (SELECT toDate('2026-10-12') + number AS dia FROM numbers(5)) AS j;
-- Medido: 8 ms · 983 045 filas leídas (9,4 MB)
-- Qué observar: el día 15 se aplica la nueva potencia. Imprescindible para las
-- alertas de exceso del módulo 5.


-- PASO 6 · Diccionario vs JOIN: mismo resultado, compara los tiempos
--  Energía del mes por departamento. sum(valor_w) * 0.5: una potencia media
--  sobre media hora × 0,5 h = una energía en Wh.
SELECT
    dictGet('ref.dict_municipio', 'codigo_dpto', dictGet('ref.dict_contador', 'codigo_insee', id_contador)) AS dpto,
    round(sum(valor_w) * 0.5 / 1e6) AS mwh
FROM silver.curva_carga
WHERE magnitud = 'CONS'
GROUP BY dpto
ORDER BY mwh DESC
LIMIT 10;
-- Medido: 271 ms · 29,8 M filas leídas (369,5 MB) · 174,9 MB de memoria

SELECT
    c.codigo_dpto AS dpto,
    round(sum(s.valor_w) * 0.5 / 1e6) AS mwh
FROM silver.curva_carga AS s
INNER JOIN ref.contador     AS p ON p.id_contador = s.id_contador
INNER JOIN ref.municipio AS c ON c.codigo_insee = p.codigo_insee
WHERE s.magnitud = 'CONS'
GROUP BY dpto
ORDER BY mwh DESC
LIMIT 10;
-- Medido: 282 ms · 30,8 M filas leídas (385,1 MB) · 282,1 MB de memoria
-- Qué observar: mismo resultado. Compara la duración y la memoria en la parte inferior
-- de la consola: el JOIN tiene que cargar antes ref.contador y ref.municipio en memoria,
-- el diccionario no.


-- PASO 7 · Calidad: ¿hay contadores que no estén en los datos de referencia?
--  dictHas devuelve 0 si la clave no existe: un control de calidad en una línea.
SELECT count() AS puntos_contador_desconocido
FROM silver.curva_carga
WHERE NOT dictHas('ref.dict_contador', id_contador);
-- Medido: 22 ms · 31 M filas leídas (236,8 MB)


-- PASO 8 · Lo que cuesta en memoria
--  Qué observar: unas decenas de MB para 1 millón de contadores. El diccionario
--  "a fecha" es más grande porque guarda intervalos por clave.
SELECT name, status, type, element_count, formatReadableSize(bytes_allocated) AS memoria, loading_duration
FROM system.dictionaries
WHERE database = 'ref';


-- PARA IR MÁS LEJOS · Coincidencia aproximada de direcciones (caso BAN)
--  ngramDistance mide el parecido entre dos textos (0 = idénticos):
--  encuentra "Rueil-Malmaison" a pesar de la errata.
SELECT nombre, codigo_insee, round(ngramDistanceCaseInsensitiveUTF8(replaceAll(nombre, '-', ' '), 'Rueil Malmaizon'), 3) AS distancia
FROM ref.municipio
ORDER BY distancia ASC
LIMIT 3;
-- Medido: 9 ms · 61 746 filas leídas (995,3 KB)


-- CHECKPOINT
SELECT
    if((SELECT element_count FROM system.dictionaries WHERE database = 'ref' AND name = 'dict_contador') = 1000000, 'OK', 'ERROR') AS dict_contador,
    if((SELECT status FROM system.dictionaries WHERE database = 'ref' AND name = 'dict_potencia_asof') = 'LOADED', 'OK', 'ERROR') AS dict_asof,
    if(dictGet('ref.dict_municipio', 'nombre', '92063') = 'Rueil-Malmaison', 'OK', 'ERROR') AS dict_municipio
SETTINGS select_sequential_consistency = 1;   -- leer la última versión, sea cual sea la réplica
