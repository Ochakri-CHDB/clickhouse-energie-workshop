-- =====================================================================
--  MÓDULO 5 · Gold (2/4): los KPI consolidados, refrescados
-- =====================================================================
--  Una vista materializada REFRESCABLE vuelve a calcular su consulta según
--  una planificación y sustituye el resultado de forma atómica. Lee silver FINAL:
--  así, duplicados y correcciones siempre se tienen en cuenta correctamente.
--
--     silver FINAL ──(cada 10 min)──► gold.energia_municipio_dia
--                                              │ DEPENDS ON
--                                              ▼
--                                    gold.resumen_entidad_dia
--
--  ¿MV incremental o refrescable?
--    · incremental: tiempo real, pero solo ve los INSERT (la trampa de la suma)
--    · refrescable: lo recalcula todo, correcta con FINAL y con las joins,
--      a cambio de un ligero retraso (regla query-mv-refreshable).
-- =====================================================================


-- PASO 1 · La energía por municipio, por día, por segmento
--  La tabla destino se ordena como la filtra el dashboard: por EPCI y luego por municipio.
CREATE OR REPLACE TABLE gold.energia_municipio_dia
(
    dia          Date,
    codigo_insee    String,
    codigo_epci     LowCardinality(String),
    codigo_dpto     LowCardinality(String),
    segmento       LowCardinality(String),
    magnitud      LowCardinality(String),
    energia_kwh   Float64,
    n_contadores        UInt32,
    potencia_max_w UInt32
)
ENGINE = MergeTree
ORDER BY (codigo_epci, codigo_insee, magnitud, dia);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_energia_municipio_dia
REFRESH EVERY 10 MINUTE
TO gold.energia_municipio_dia
AS
SELECT
    dia,
    dictGet('ref.dict_contador', 'codigo_insee', id_contador)                         AS codigo_insee,
    dictGet('ref.dict_municipio', 'codigo_epci', codigo_insee)                  AS codigo_epci,
    dictGet('ref.dict_municipio', 'codigo_dpto', codigo_insee)                  AS codigo_dpto,
    dictGet('ref.dict_contador', 'segmento', id_contador)                            AS segmento,
    magnitud,
    sum(valor_w * paso_min / 60 / 1000)                                   AS energia_kwh,
    uniqExact(id_contador)                                                     AS n_contadores,
    max(valor_w)                                                         AS potencia_max_w
FROM silver.curva_carga FINAL
GROUP BY dia, codigo_insee, codigo_epci, codigo_dpto, segmento, magnitud;

--  El primer refresco arranca enseguida. Lo seguimos en
--  system.view_refreshes (estado, duración, filas escritas, próxima ejecución):
SELECT view, status, last_success_time, last_refresh_time, next_refresh_time, read_rows, written_rows
FROM system.view_refreshes
WHERE database = 'gold';

--  Esperamos a que termine este 1.er cálculo antes de conectar otras vistas a la tabla.
--  Atención: sin esta espera, en un servicio con varias réplicas, el paso 3
--  falla con "has been changed by another replica".
SYSTEM WAIT VIEW gold.rmv_energia_municipio_dia;
-- Medido: 695 ms


-- PASO 2 · La curva de carga agregada por EPCI (para el dashboard)
--  30 millones de puntos de silver se convierten en unos pocos miles de filas:
--  una curva por territorio y por magnitud.
CREATE OR REPLACE TABLE gold.curva_epci
(
    codigo_epci     LowCardinality(String),
    magnitud      LowCardinality(String),
    ts            DateTime('UTC'),
    potencia_kw  Float64,
    n_contadores        UInt32
)
ENGINE = MergeTree
ORDER BY (codigo_epci, magnitud, ts);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_curva_epci
REFRESH EVERY 10 MINUTE
TO gold.curva_epci
AS
SELECT
    dictGet('ref.dict_municipio', 'codigo_epci', dictGet('ref.dict_contador', 'codigo_insee', id_contador)) AS codigo_epci,
    magnitud,
    ts,
    sum(valor_w) / 1000                                                                    AS potencia_kw,
    count()                                                                                 AS n_contadores
FROM silver.curva_carga FINAL
GROUP BY codigo_epci, magnitud, ts;


-- PASO 3 · Una vista que DEPENDE de otra: el resumen por entidad local
--  DEPENDS ON: espera a que la energía por municipio se haya refrescado.
CREATE OR REPLACE TABLE gold.resumen_entidad_dia
(
    id_destinatario  String,
    entidad     String,
    dia             Date,
    consumo_kwh        Float64,
    prod_kwh         Float64,
    tasa_cobertura  Float64,         -- producción / consumo
    n_contadores           UInt32
)
ENGINE = MergeTree
ORDER BY (id_destinatario, dia);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_resumen_entidad
REFRESH EVERY 10 MINUTE
DEPENDS ON gold.rmv_energia_municipio_dia
TO gold.resumen_entidad_dia
AS
SELECT
    d.id_destinatario,
    d.nombre                                                 AS entidad,
    e.dia,
    sumIf(e.energia_kwh, e.magnitud = 'CONS')             AS consumo_kwh,
    sumIf(e.energia_kwh, e.magnitud = 'PROD')             AS prod_kwh,
    round(prod_kwh / consumo_kwh, 4)                        AS tasa_cobertura,
    sumIf(e.n_contadores, e.magnitud = 'CONS')                  AS n_contadores
FROM gold.energia_municipio_dia AS e
INNER JOIN ref.destinatario AS d ON d.codigo_epci = e.codigo_epci
GROUP BY d.id_destinatario, d.nombre, e.dia;


-- PASO 4 · Forzar un refresco (en lugar de esperar 10 min)
--  SYSTEM REFRESH lanza el cálculo, SYSTEM WAIT espera a que termine.
--  El resultado sustituye al anterior de golpe: un dashboard nunca ve un estado parcial.
SYSTEM REFRESH VIEW gold.rmv_energia_municipio_dia;
SYSTEM WAIT VIEW gold.rmv_energia_municipio_dia;
-- Medido: 629 ms
SYSTEM REFRESH VIEW gold.rmv_resumen_entidad;
SYSTEM WAIT VIEW gold.rmv_resumen_entidad;
-- Medido: 289 ms
SYSTEM REFRESH VIEW gold.rmv_curva_epci;
SYSTEM WAIT VIEW gold.rmv_curva_epci;
-- Medido: 615 ms

SELECT view, status, last_success_time, round(last_success_duration_ms / 1000, 2) AS duracion_s, written_rows
FROM system.view_refreshes
WHERE database = 'gold';

SELECT entidad, round(sum(consumo_kwh) / 1000) AS consumo_mwh, round(sum(prod_kwh) / 1000) AS prod_mwh,
       round(100 * sum(prod_kwh) / sum(consumo_kwh), 1) AS cobertura_pct, max(n_contadores) AS n_contadores
FROM gold.resumen_entidad_dia
GROUP BY entidad
ORDER BY consumo_mwh DESC;
-- Medido: 35 ms · 186 filas leídas (7,9 KB)
