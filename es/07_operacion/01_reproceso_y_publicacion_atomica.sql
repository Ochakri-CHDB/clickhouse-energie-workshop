-- =====================================================================
--  MÓDULO 7 · Reprocesar un mes sin perturbar el flujo y publicarlo de golpe
-- =====================================================================
--  Caso real: cambia una regla o se corrige un bug de parsing, y hay que
--  reconstruir silver para octubre. Mientras tanto, el flujo diario sigue
--  y los dashboards siguen leyendo la versión anterior.
--
--     bronze ──(rebuild aislado)──► silver.curva_carga__build
--                                         │ controles
--                                         ▼
--             REPLACE PARTITION: cambio atómico hacia silver.curva_carga
-- =====================================================================


-- PASO 1 · Una tabla de construcción, clon de la tabla de producción
--  CREATE TABLE … AS copia la estructura (columnas, motor, clave), sin los datos.
CREATE OR REPLACE TABLE silver.curva_carga__build AS silver.curva_carga;


-- PASO 2 · El rebuild: solo nos quedamos con la ÚLTIMA versión de cada punto
--  (argMax por punto), directamente desde bronze. No se dispara ninguna MV,
--  porque escribimos en __build y no en bronze. Producción no se toca.
--  Atención: este GROUP BY trabaja sobre ~32 M de claves y pide mucha memoria.
--  En Cloud, por encima de la mitad de la RAM, ClickHouse vuelca a disco
--  en lugar de fallar: más lento, pero sin error.
INSERT INTO silver.curva_carga__build
SELECT
    id_contador, magnitud, ts,
    argMax(valor_w, version), argMax(paso_min, version), argMax(etapa, version), max(version)
FROM
(
    SELECT
        toUInt64(m.idContador) AS id_contador, g.magnitudNegocio AS magnitud, parseDateTimeBestEffort(p.d, 'UTC') AS ts,
        toUInt32(p.v) AS valor_w, toUInt8(extract(m.paso, '\\d+')) AS paso_min, m.etapa AS etapa,
        ingested_at AS version
    FROM bronze.flujos_brutos
    ARRAY JOIN JSONExtract(payload, 'medidas',
        'Array(Tuple(idContador String, etapa String, paso String, magnitud Array(Tuple(magnitudNegocio String, puntos Array(Tuple(d String, v String))))))') AS m
    ARRAY JOIN m.magnitud AS g
    ARRAY JOIN g.puntos   AS p
    WHERE codigo_flujo = 'CURVA' AND toUInt32OrNull(p.v) IS NOT NULL
)
WHERE toYYYYMM(ts) = 202610
GROUP BY id_contador, magnitud, ts;
-- Medido: 8,74 s · 623 ficheros leídos (1,4 GB de JSON) · 30,9 M filas escritas · 12,5 GB de memoria


-- PASO 3 · Controles antes de publicar
--  Comparamos el rebuild con la producción deduplicada (FINAL). Solo se publica si
--  los dos recuentos coinciden. La 3.ª columna muestra los duplicados físicos en prod.
SELECT
    (SELECT count() FROM silver.curva_carga FINAL WHERE toYYYYMM(ts) = 202610)  AS prod_deduplicada,
    (SELECT count() FROM silver.curva_carga__build)                              AS reconstruido,
    (SELECT count() FROM silver.curva_carga WHERE toYYYYMM(ts) = 202610)        AS prod_antes_merges,
    if(prod_deduplicada = reconstruido, 'OK, listo para publicar', 'ERROR, desvío: no se publica') AS veredicto
SETTINGS select_sequential_consistency = 1;
-- Medido: 221 ms · 62,8 M filas leídas (754,2 MB) · 243,4 MB de memoria


-- PASO 4 · Publicación atómica: la partición de prod se sustituye de golpe
--  Los lectores ven la versión anterior y luego la nueva. Nunca una mezcla.
--  REPLACE PARTITION no copia los datos: vuelve a enganchar las parts de __build
--  a la tabla de producción. Por eso tarda menos de un segundo.
--  Las dos tablas deben tener exactamente la misma estructura.
ALTER TABLE silver.curva_carga REPLACE PARTITION 202610 FROM silver.curva_carga__build;
-- Medido: 192 ms

SELECT count() AS filas_prod_tras_publicar
FROM silver.curva_carga
WHERE toYYYYMM(ts) = 202610
SETTINGS select_sequential_consistency = 1;
-- Medido: 181 ms · 30,9 M filas leídas (117,8 MB)
-- Qué observar: el recuento es igual al del rebuild. La tabla queda compacta, sin
-- duplicados físicos, y todo ello sin OPTIMIZE TABLE … FINAL.

DROP TABLE silver.curva_carga__build;


-- PASO 5 · Recalcular gold: basta con un refresco
--  Gracias a DEPENDS ON (módulo 5), el resumen por entidad local se actualiza solo.
SYSTEM REFRESH VIEW gold.rmv_energia_municipio_dia;
SYSTEM WAIT VIEW gold.rmv_energia_municipio_dia;
-- Medido: 1,24 s


-- PASO 6 · Intercambiar dos tablas de golpe: EXCHANGE TABLES
--  Ejemplo: una nueva versión de una tabla gold, construida al lado.
--  EXCHANGE TABLES intercambia los nombres de las dos tablas en una operación atómica:
--  ningún lector ve una tabla vacía o a medio llenar.
CREATE OR REPLACE TABLE gold.energia_municipio_dia__v2 AS gold.energia_municipio_dia;
INSERT INTO gold.energia_municipio_dia__v2 SELECT * FROM gold.energia_municipio_dia;
-- Medido: 78 ms · 22 862 filas leídas (670,2 KB) · 22 862 filas escritas
EXCHANGE TABLES gold.energia_municipio_dia AND gold.energia_municipio_dia__v2;
-- Medido: 15 ms
DROP TABLE gold.energia_municipio_dia__v2;


-- PASO 7 · Pausar una vista durante una operación pesada
--  SYSTEM STOP VIEW suspende los refrescos programados, SYSTEM START los reanuda.
--  Qué observar: el estado pasa a Disabled y luego vuelve.
SYSTEM STOP VIEW gold.rmv_alertas_pmax;
SELECT view, status FROM system.view_refreshes WHERE view = 'rmv_alertas_pmax';
SYSTEM START VIEW gold.rmv_alertas_pmax;
