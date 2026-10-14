-- =====================================================================
--  MÓDULO 3 · Backfill del histórico, y después flujo continuo
-- =====================================================================


-- PASO 1 · Backfill: reprocesamos bronze en las MV, con un INSERT … SELECT
--  Ejecutamos nosotros mismos la consulta de la MV, sobre todo el histórico de bronze.
--  Atención: hay que hacerlo DESPUÉS de crear la MV; si no, los ficheros
--  que llegaran mientras tanto se perderían. Aquí bronze no recibe nada durante la operación.
INSERT INTO silver.curva_carga
SELECT
    toUInt64(m.idContador), g.magnitudNegocio, parseDateTimeBestEffort(p.d, 'UTC'), toUInt32(p.v),
    toUInt8(extract(m.paso, '\\d+')), m.etapa, ingested_at
FROM bronze.flujos_brutos
ARRAY JOIN JSONExtract(payload, 'medidas',
    'Array(Tuple(idContador String, etapa String, paso String, magnitud Array(Tuple(magnitudNegocio String, puntos Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.magnitud AS g
ARRAY JOIN g.puntos   AS p
WHERE codigo_flujo = 'CURVA' AND toUInt32OrNull(p.v) IS NOT NULL
SETTINGS max_block_size = 4;
-- Medido: 18,2 s · 600 ficheros leídos (1,4 GB de JSON) · 29,9 M filas escritas · 1,7 GB de memoria
-- Qué observar: ~30 millones de puntos extraídos del JSON. Mira la velocidad en filas/s
-- en la parte inferior de la consola: todo el parsing del JSON se hace en la base de datos.

INSERT INTO silver.rechazos
SELECT ingested_at, file_name, codigo_flujo, m.idContador, p.d, p.v, 'valor no numérico'
FROM bronze.flujos_brutos
ARRAY JOIN JSONExtract(payload, 'medidas', 'Array(Tuple(idContador String, magnitud Array(Tuple(puntos Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.magnitud AS g
ARRAY JOIN g.puntos   AS p
WHERE codigo_flujo = 'CURVA' AND toUInt32OrNull(p.v) IS NULL
SETTINGS max_block_size = 4;
-- Medido: 2,68 s · 600 ficheros leídos (1,4 GB de JSON) · 8 754 filas escritas · 985,1 MB de memoria

INSERT INTO silver.energia_dia
SELECT toUInt64(m.idContador), g.magnitudNegocio, toDate(p.d), toDecimal64(p.v, 2), m.etapa, ingested_at
FROM bronze.flujos_brutos
ARRAY JOIN JSONExtract(payload, 'medidas', 'Array(Tuple(idContador String, etapa String, magnitud Array(Tuple(magnitudNegocio String, puntos Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.magnitud AS g
ARRAY JOIN g.puntos   AS p
WHERE codigo_flujo = 'ENERGIA';
-- Medido: 797 ms · 600 ficheros leídos (170 MB de JSON) · 625 080 filas escritas · 336,4 MB de memoria

INSERT INTO silver.pmax_dia
SELECT toUInt64(m.idContador), toDate(m.periodo.fechaInicio), toUInt32(p.v), parseDateTimeBestEffort(p.d, 'UTC'), ingested_at
FROM bronze.flujos_brutos
ARRAY JOIN JSONExtract(payload, 'medidas', 'Array(Tuple(idContador String, periodo Tuple(fechaInicio String), magnitud Array(Tuple(puntos Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.magnitud AS g
ARRAY JOIN g.puntos   AS p
WHERE codigo_flujo = 'PMAX';
-- Medido: 852 ms · 600 ficheros leídos (147,2 MB de JSON) · 600 000 filas escritas · 408,6 MB de memoria

SELECT
    (SELECT count() FROM silver.curva_carga) AS puntos_curva,
    (SELECT count() FROM silver.energia_dia)  AS filas_energia,
    (SELECT count() FROM silver.pmax_dia)     AS filas_pmax,
    (SELECT count() FROM silver.rechazos)        AS rechazos;
-- Medido: 4 ms · 5 filas leídas


-- PASO 2 · El flujo continuo: llega el 31 de octubre
--  Insertamos SOLO en bronze. Mira cómo silver se llena solo.
--  Se dispara toda la cadena: bronze → MV → silver → MV (módulo 5) → gold.
SELECT count() AS puntos_antes FROM silver.curva_carga WHERE dia = '2026-10-31';
-- Medido: 63 ms · 29,9 M filas leídas (57,1 MB)

INSERT INTO bronze.flujos_brutos
SELECT * FROM simulador.ficheros_curva(inicio = 600, n = 20)
SETTINGS max_block_size = 2;
-- Medido: 5,95 s · 100 ficheros leídos (184,1 MB de JSON) · 996 328 filas escritas · 306,1 MB de memoria

SELECT count() AS puntos_despues FROM silver.curva_carga WHERE dia = '2026-10-31';
-- Medido: 62 ms · 25 M filas leídas (47,8 MB)
-- Qué observar: el número de puntos del día 31 pasa de 0 a ~1 millón.
-- Venga de donde venga el INSERT en bronze, las vistas materializadas lo propagan.


-- PASO 3 · Lo que la compresión hace con las curvas
--  Qué observar: bronze (JSON) ocupa decenas de kilobytes por fichero, silver
--  alrededor de 1,5 bytes por punto. El formato columnar tipado es la verdadera mejora.
SELECT
    table,
    formatReadableQuantity(sum(rows))                                AS filas,
    formatReadableSize(sum(data_uncompressed_bytes))                 AS bruto,
    formatReadableSize(sum(data_compressed_bytes))                   AS en_disco,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes)) AS ratio,
    round(sum(data_compressed_bytes) / sum(rows), 2)                 AS bytes_por_punto
FROM system.parts
WHERE database IN ('bronze', 'silver') AND active
GROUP BY table
ORDER BY sum(data_compressed_bytes) DESC;

--  Por columna (tamaños legibles gracias a min_bytes_for_wide_part = 0, ver módulo 1).
--  Qué observar: ts e id_contador no cuestan casi nada gracias al orden y a los codecs;
--  valor_w, que contiene el "ruido" de las medidas, es la que más ocupa.
SELECT name, type, compression_codec,
       formatReadableSize(data_compressed_bytes) AS en_disco,
       round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio
FROM system.columns
WHERE database = 'silver' AND table = 'curva_carga';


-- CHECKPOINT
--  Más de 28 M de puntos, 600 000 PMax (20 000 contadores × 30 días) y el día 31 llegado por el flujo.
SELECT
    if((SELECT count() FROM silver.curva_carga) > 28000000, 'OK', 'ERROR') AS curvas,
    if((SELECT count() FROM silver.energia_dia)  > 600000,   'OK', 'ERROR') AS energia,
    if((SELECT count() FROM silver.pmax_dia)     = 600000,   'OK', 'ERROR') AS pmax,
    if((SELECT count() FROM silver.curva_carga WHERE dia = '2026-10-31') > 900000, 'OK', 'ERROR') AS flujo_continuo
SETTINGS select_sequential_consistency = 1;   -- leer la última versión, sea cual sea la réplica
