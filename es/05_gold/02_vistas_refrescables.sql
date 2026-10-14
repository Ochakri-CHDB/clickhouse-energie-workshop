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
--  La tabla destino se ordena como la filtra el dashboard: por área urbana y luego por municipio.
CREATE OR REPLACE TABLE gold.energia_municipio_dia
(
    dia          Date,
    codigo_ine    String,
    codigo_area     LowCardinality(String),
    codigo_provincia     LowCardinality(String),
    segmento       LowCardinality(String),
    magnitud      LowCardinality(String),
    energia_kwh   Float64,
    n_contadores        UInt32,
    potencia_max_w UInt32
)
ENGINE = MergeTree
ORDER BY (codigo_area, codigo_ine, magnitud, dia);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_energia_municipio_dia
REFRESH EVERY 10 MINUTE
TO gold.energia_municipio_dia
AS
SELECT
    dia,
    dictGet('ref.dict_contador', 'codigo_ine', id_contador)                         AS codigo_ine,
    dictGet('ref.dict_municipio', 'codigo_area', codigo_ine)                  AS codigo_area,
    dictGet('ref.dict_municipio', 'codigo_provincia', codigo_ine)                  AS codigo_provincia,
    dictGet('ref.dict_contador', 'segmento', id_contador)                            AS segmento,
    magnitud,
    sum(valor_w * paso_min / 60 / 1000)                                   AS energia_kwh,
    uniqExact(id_contador)                                                     AS n_contadores,
    max(valor_w)                                                         AS potencia_max_w
FROM silver.curva_carga FINAL
GROUP BY dia, codigo_ine, codigo_area, codigo_provincia, segmento, magnitud;

--  El primer refresco arranca enseguida. Lo seguimos en
--  system.view_refreshes (estado, duración, filas escritas, próxima ejecución):
SELECT view, status, last_success_time, last_refresh_time, next_refresh_time, read_rows, written_rows
FROM system.view_refreshes
WHERE database = 'gold';

--  Esperamos a que termine este 1.er cálculo antes de conectar otras vistas a la tabla.
--  Atención: sin esta espera, en un servicio con varias réplicas, el paso 3
--  falla con "has been changed by another replica".
SYSTEM WAIT VIEW gold.rmv_energia_municipio_dia;
-- Medido: 396 ms


-- PASO 2 · La curva de carga agregada por área urbana (para el dashboard)
--  30 millones de puntos de silver se convierten en unas 18 000 filas:
--  una curva por territorio y por magnitud.
CREATE OR REPLACE TABLE gold.curva_area
(
    codigo_area     LowCardinality(String),
    magnitud      LowCardinality(String),
    ts            DateTime('UTC'),
    potencia_kw  Float64,
    n_contadores        UInt32
)
ENGINE = MergeTree
ORDER BY (codigo_area, magnitud, ts);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_curva_area
REFRESH EVERY 10 MINUTE
TO gold.curva_area
AS
SELECT
    dictGet('ref.dict_municipio', 'codigo_area', dictGet('ref.dict_contador', 'codigo_ine', id_contador)) AS codigo_area,
    magnitud,
    ts,
    sum(valor_w) / 1000                                                                    AS potencia_kw,
    count()                                                                                 AS n_contadores
FROM silver.curva_carga FINAL
GROUP BY codigo_area, magnitud, ts;


-- PASO 3 · Una vista que DEPENDE de otra: el resumen por destinatario (área urbana)
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
INNER JOIN ref.destinatario AS d ON d.codigo_area = e.codigo_area
GROUP BY d.id_destinatario, d.nombre, e.dia;


-- PASO 4 · Forzar un refresco (en lugar de esperar 10 min)
--  SYSTEM REFRESH lanza el cálculo, SYSTEM WAIT espera a que termine.
--  El resultado sustituye al anterior de golpe: un dashboard nunca ve un estado parcial.
SYSTEM REFRESH VIEW gold.rmv_energia_municipio_dia;
SYSTEM WAIT VIEW gold.rmv_energia_municipio_dia;
-- Medido: 663 ms
SYSTEM REFRESH VIEW gold.rmv_resumen_entidad;
SYSTEM WAIT VIEW gold.rmv_resumen_entidad;
-- Medido: 268 ms
SYSTEM REFRESH VIEW gold.rmv_curva_area;
SYSTEM WAIT VIEW gold.rmv_curva_area;
-- Medido: 625 ms

SELECT view, status, last_success_time, round(last_success_duration_ms / 1000, 2) AS duracion_s, written_rows
FROM system.view_refreshes
WHERE database = 'gold';

SELECT entidad, round(sum(consumo_kwh) / 1000) AS consumo_mwh, round(sum(prod_kwh) / 1000) AS prod_mwh,
       round(100 * sum(prod_kwh) / sum(consumo_kwh), 1) AS cobertura_pct, max(n_contadores) AS n_contadores
FROM gold.resumen_entidad_dia
GROUP BY entidad
ORDER BY consumo_mwh DESC;
-- Medido: 32 ms · 186 filas leídas (8,2 KB)
-- Qué observar: 6 destinatarios × 31 días = 186 filas. El Área Urbana de Madrid
-- (12 lotes, 11 973 contadores) consume unos 10 846 MWh en el mes, cinco veces más
-- que Barcelona (2 140 MWh). La cobertura solar va del 3,3 % (Barcelona) al 5,5 % (Sevilla).
