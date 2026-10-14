-- =====================================================================
--  MÓDULO 3 · Silver: medidas tipadas, limpias y deduplicadas
-- =====================================================================
--  Bronze (1 fila = 1 fichero)  ──MV──►  Silver (1 fila = 1 punto)
--  La vista materializada (MV) es un TRIGGER sobre INSERT: cada bloque
--  insertado en bronze se transforma y se escribe en silver, al vuelo.
--  Nunca recalcula lo que ya existe: solo procesa las filas nuevas, en el
--  momento del INSERT. El coste se paga una vez, al escribir.
-- =====================================================================


-- PASO 1 · La tabla de curvas de carga
--  ReplacingMergeTree: para una misma clave (id_contador, magnitud, ts), gana la fila
--  con la versión más reciente. Perfecto para reenvíos y correcciones.
--  El reemplazo ocurre durante los merges en segundo plano, no en el INSERT:
--  mientras tanto, las dos versiones conviven en disco (lo veremos en 03).
CREATE OR REPLACE TABLE silver.curva_carga
(
    id_contador        UInt64,
    magnitud      LowCardinality(String),                        -- CONS / PROD
    ts            DateTime('UTC')      CODEC(Delta, ZSTD(1)),    -- fin del intervalo, en UTC. Delta guarda la diferencia con la fila anterior (1800 s): casi nada
    valor_w      UInt32               CODEC(T64, ZSTD(1)),      -- potencia media en W. T64 elimina los bits altos que no se usan
    paso_min       UInt8,
    etapa  LowCardinality(String),                        -- BRUTO / CORREGIDO
    version       DateTime64(3, 'UTC') CODEC(Delta, ZSTD(1)),    -- llegada del fichero: gana la más reciente
    dia          Date MATERIALIZED toDate(ts - 1, 'Europe/Paris') -- calculado al insertar: el día local (ts - 1 porque las 00:00 cierran el día anterior)
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(ts)                -- una partición por mes: pocas y acotadas
ORDER BY (magnitud, id_contador, ts)          -- de menor a mayor cardinalidad: 2 valores, luego el contador, luego el tiempo
SETTINGS min_bytes_for_wide_part = 0;    -- una columna = un fichero: así podremos leer la compresión por columna


-- PASO 2 · Los flujos diarios
--  Mismo principio: ReplacingMergeTree con la fecha de llegada como versión.
CREATE OR REPLACE TABLE silver.energia_dia
(
    id_contador        UInt64,
    magnitud      LowCardinality(String),
    dia          Date,
    energia_wh    Decimal(18, 2),                                -- Decimal: sin errores de redondeo en las sumas
    etapa  LowCardinality(String),
    version       DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(dia)
ORDER BY (id_contador, magnitud, dia);

CREATE OR REPLACE TABLE silver.pmax_dia
(
    id_contador        UInt64,
    dia          Date,
    pmax_va       UInt32,
    ts_pmax       DateTime('UTC'),
    version       DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(dia)
ORDER BY (id_contador, dia);

--  Los rechazos: no se pierde nada, no se bloquea nada
--  Un valor ilegible no detiene la carga: va a esta tabla, junto con el
--  fichero de origen, para analizarlo.
CREATE OR REPLACE TABLE silver.rechazos
(
    ingested_at   DateTime64(3, 'UTC'),
    file_name     String,
    codigo_flujo     LowCardinality(String),
    id_contador        String,
    ts_texto    String,
    valor        String,
    motivo         LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY (codigo_flujo, ingested_at);


-- PASO 3 · La MV bronze → silver para las curvas (CURVA)
--  3 ARRAY JOIN en cascada: fichero → medidas → magnitudes → puntos.
--  Así, un fichero de 1000 contadores × 48 puntos produce ~48 000 filas en silver.
--  "TO silver.curva_carga": la MV escribe en una tabla que hemos creado nosotros
--  (mantenemos el control del motor, la clave y los codecs).
CREATE OR REPLACE MATERIALIZED VIEW silver.mv_curva TO silver.curva_carga AS
SELECT
    toUInt64(m.idContador)                         AS id_contador,
    g.magnitudNegocio                          AS magnitud,
    parseDateTimeBestEffort(p.d, 'UTC')       AS ts,                -- "+01:00" / "+02:00" → UTC
    toUInt32(p.v)                             AS valor_w,
    toUInt8(extract(m.paso, '\\d+'))           AS paso_min,           -- 'PT30M' → 30
    m.etapa                             AS etapa,
    ingested_at                               AS version
FROM bronze.flujos_brutos
ARRAY JOIN JSONExtract(payload, 'medidas',
    'Array(Tuple(idContador String, etapa String, paso String, magnitud Array(Tuple(magnitudNegocio String, puntos Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.magnitud AS g
ARRAY JOIN g.puntos   AS p
WHERE codigo_flujo = 'CURVA'
  AND toUInt32OrNull(p.v) IS NOT NULL;   -- toUInt32OrNull devuelve NULL en lugar de un error si el valor es ilegible

--  Una 2.ª MV sobre la misma fuente: captura lo que la 1.ª descarta.
--  Varias MV pueden leer la misma tabla: cada INSERT en bronze las dispara todas.
CREATE OR REPLACE MATERIALIZED VIEW silver.mv_curva_rechazos TO silver.rechazos AS
SELECT
    ingested_at, file_name, codigo_flujo,
    m.idContador AS id_contador, p.d AS ts_texto, p.v AS valor,
    'valor no numérico' AS motivo
FROM bronze.flujos_brutos
ARRAY JOIN JSONExtract(payload, 'medidas',
    'Array(Tuple(idContador String, magnitud Array(Tuple(puntos Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.magnitud AS g
ARRAY JOIN g.puntos   AS p
WHERE codigo_flujo = 'CURVA'
  AND toUInt32OrNull(p.v) IS NULL;


-- PASO 4 · Las MV de los flujos diarios (ENERGIA, PMAX)
CREATE OR REPLACE MATERIALIZED VIEW silver.mv_energia_dia TO silver.energia_dia AS
SELECT
    toUInt64(m.idContador)                         AS id_contador,
    g.magnitudNegocio                          AS magnitud,
    toDate(p.d)                               AS dia,
    toDecimal64(p.v, 2)                       AS energia_wh,
    m.etapa                             AS etapa,
    ingested_at                               AS version
FROM bronze.flujos_brutos
ARRAY JOIN JSONExtract(payload, 'medidas',
    'Array(Tuple(idContador String, etapa String, magnitud Array(Tuple(magnitudNegocio String, puntos Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.magnitud AS g
ARRAY JOIN g.puntos   AS p
WHERE codigo_flujo = 'ENERGIA';

CREATE OR REPLACE MATERIALIZED VIEW silver.mv_pmax_dia TO silver.pmax_dia AS
SELECT
    toUInt64(m.idContador)                         AS id_contador,
    toDate(m.periodo.fechaInicio)               AS dia,
    toUInt32(p.v)                             AS pmax_va,
    parseDateTimeBestEffort(p.d, 'UTC')       AS ts_pmax,
    ingested_at                               AS version
FROM bronze.flujos_brutos
ARRAY JOIN JSONExtract(payload, 'medidas',
    'Array(Tuple(idContador String, periodo Tuple(fechaInicio String), magnitud Array(Tuple(puntos Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.magnitud AS g
ARRAY JOIN g.puntos   AS p
WHERE codigo_flujo = 'PMAX';


-- PASO 5 · Sorpresa: ¡silver está vacío!
SELECT
    (SELECT count() FROM silver.curva_carga) AS puntos_curva,
    (SELECT count() FROM silver.energia_dia)  AS filas_energia,
    (SELECT count() FROM silver.pmax_dia)     AS filas_pmax;
-- Medido: 3 ms · 4 filas leídas
-- Qué observar: una MV solo ve los INSERT que llegan DESPUÉS de su creación.
--    Los ficheros que ya están en bronze hay que "reprocesarlos": es el backfill.
--    Es intencionado: crear una MV sobre una tabla de 1 TB no bloquea nada.
