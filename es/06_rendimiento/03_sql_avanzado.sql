-- =====================================================================
--  MÓDULO 6 · SQL avanzado sobre las curvas de carga
-- =====================================================================
--  Siete herramientas SQL que salen una y otra vez con series temporales.
--  Se ejecutan sobre silver.curva_carga (los 20 000 contadores de los ficheros JSON).
-- =====================================================================


-- 1 · Media móvil de 2 horas (window function)
--  OVER (ORDER BY ts ROWS BETWEEN 3 PRECEDING AND CURRENT ROW): para cada
--  fila, la media de esa fila y de las 3 anteriores, es decir 4 medias horas = 2 h.
--  La ventana suaviza el ruido sin agrupar las filas.
SELECT
    toTimeZone(ts, 'Europe/Paris')                                         AS hora,
    valor_w,
    round(avg(valor_w) OVER (ORDER BY ts ROWS BETWEEN 3 PRECEDING AND CURRENT ROW)) AS media_2h
FROM silver.curva_carga FINAL
WHERE id_contador = sim_id_contador(7) AND magnitud = 'CONS' AND dia = '2026-10-15'
ORDER BY ts;
-- Medido: 12 ms · 49 152 filas leídas (1,3 MB)


-- 2 · Hacer visibles los HUECOS: WITH FILL
--  Tomamos un contador-día incompleto detectado por el seguimiento de la recogida.
--  ORDER BY … WITH FILL añade las filas que faltan en la serie, de FROM a TO,
--  en pasos de STEP (1800 s). Las columnas de las filas añadidas toman su
--  valor por defecto (0): los huecos se detectan gracias a la columna recibido.
WITH (
    SELECT (id_contador, dia) FROM gold.recogida_contador_dia
    GROUP BY id_contador, dia
    HAVING uniqExactMerge(puntos_recibidos) BETWEEN 40 AND 47
    ORDER BY dia, id_contador LIMIT 1
) AS objetivo
SELECT toTimeZone(ts, 'Europe/Paris') AS hora, valor_w, if(recibido = 0, 'faltante', '') AS estado
FROM
(
    SELECT ts, valor_w, 1 AS recibido                    -- las filas añadidas por WITH FILL tendrán recibido = 0
    FROM silver.curva_carga FINAL
    WHERE id_contador = objetivo.1 AND magnitud = 'CONS' AND dia = objetivo.2
    ORDER BY ts WITH FILL
        FROM toDateTime(assumeNotNull(objetivo.2), 'Europe/Paris') + 1800     -- assumeNotNull: WITH FILL exige
        TO   toDateTime(assumeNotNull(objetivo.2) + 1, 'Europe/Paris') + 1    -- una constante no Nullable
        STEP 1800
);
-- Medido: 112 ms · 668 312 filas leídas (78 MB) · 896,9 MB de memoria
-- Qué observar: la media hora que falta aparece con valor_w = 0 y el estado "faltante".


-- 3 · La hora punta de cada contador (argMax), en una sola pasada
--  argMax(ts, valor_w) devuelve el ts de la fila donde valor_w es máximo:
--  no hace falta subconsulta ni unión para encontrar "la hora del máximo".
SELECT
    dictGet('ref.dict_contador', 'perfil', id_contador)                AS perfil,
    toHour(argMax(ts, valor_w), 'Europe/Paris')             AS hora_punta,
    count()                                                  AS n_contadores
FROM silver.curva_carga FINAL
WHERE magnitud = 'CONS' AND dia = '2026-10-15'
GROUP BY id_contador
ORDER BY perfil, hora_punta;   -- agrupa visualmente: RES por la tarde-noche, PRO durante el día
-- Medido: 183 ms · 30,5 M filas leídas (785,6 MB) · 347,5 MB de memoria


-- 4 · Perfil tipo: laborable vs fin de semana, por hora local
--  avgIf(valor, condición): una media filtrada. Dos columnas en un solo escaneo.
SELECT
    toHour(ts - 900, 'Europe/Paris')                                        AS hora,
    round(avgIf(valor_w, toDayOfWeek(ts, 0, 'Europe/Paris') <= 5))         AS laborable_w,
    round(avgIf(valor_w, toDayOfWeek(ts, 0, 'Europe/Paris') >= 6))         AS finde_w,
    bar(laborable_w, 0, 3000, 25)                                             AS grafico_laborable
FROM silver.curva_carga FINAL
WHERE magnitud = 'CONS' AND dictGet('ref.dict_contador', 'perfil', id_contador) = 'PRO'
GROUP BY hora
ORDER BY hora;
-- Medido: 188 ms · 23,4 M filas leídas (552,3 MB) · 322,9 MB de memoria


-- 5 · Distribución por segmento: cuantiles y factor de carga
--  quantiles(0.5, 0.9, 0.99) calcula varios percentiles en una pasada.
--  El factor de carga (media / máx) indica si un sitio consume de forma regular.
SELECT
    dictGet('ref.dict_contador', 'segmento', id_contador)       AS segmento,
    quantiles(0.5, 0.9, 0.99)(valor_w)               AS p50_p90_p99_w,
    round(avg(valor_w) / max(valor_w), 3)           AS factor_carga
FROM silver.curva_carga FINAL
WHERE magnitud = 'CONS'
GROUP BY segmento
ORDER BY segmento;
-- Medido: 234 ms · 30,5 M filas leídas (727,1 MB) · 402,8 MB de memoria


-- 6 · ASOF JOIN: la potencia contratada "a fecha", sin diccionario
--  Para cada PMax, ASOF JOIN toma la fila del historial más reciente cuyo
--  valid_from es anterior o igual al día. Mismo resultado que el diccionario
--  RANGE_HASHED del módulo 4, en forma de unión.
SELECT
    p.id_contador, p.dia, p.pmax_va, h.potencia_kva AS kva_a_fecha,
    p.pmax_va > h.potencia_kva * 1000 AS exceso
FROM silver.pmax_dia AS p FINAL
ASOF JOIN ref.historial_contador AS h ON p.id_contador = h.id_contador AND p.dia >= h.valid_from
WHERE p.id_contador IN (SELECT id_contador FROM ref.historial_contador WHERE valid_to BETWEEN '2026-10-01' AND '2026-10-30' LIMIT 3)
ORDER BY p.id_contador, p.dia
LIMIT 20;
-- Medido: 58 ms · 2,1 M filas leídas (22,6 MB) · 262,8 MB de memoria


-- 7 · Autoconsumo: ¿a qué hora cubre la producción el consumo?
--  sumIf separa CONS y PROD en la misma consulta. Reutilizamos los alias
--  prod_kw y consumo_kw en el cálculo siguiente: ClickHouse lo permite.
SELECT
    toHour(ts - 900, 'Europe/Paris')                             AS hora,
    round(sumIf(valor_w, magnitud = 'PROD') / 1000)             AS prod_kw,
    round(sumIf(valor_w, magnitud = 'CONS') / 1000)             AS consumo_kw,
    round(100 * prod_kw / consumo_kw, 1)                           AS cobertura_pct
FROM silver.curva_carga FINAL
WHERE id_contador IN (SELECT id_contador FROM ref.contador WHERE fv_kwp > 0)
  AND dia = '2026-10-15'
GROUP BY hora
ORDER BY hora;
-- Medido: 136 ms · 13,6 M filas leídas (331 MB) · 365,2 MB de memoria
