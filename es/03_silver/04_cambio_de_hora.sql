-- =====================================================================
--  MÓDULO 3 · La trampa del cambio de hora (25 de octubre de 2026)
-- =====================================================================
--  A las 3h de la madrugada se retrasa el reloj a las 2h: el día dura 25 horas,
--  es decir 50 medias horas. En España, como en toda la UE, el cambio se hace a la
--  1h UTC: Europe/Madrid pasa de +02:00 a +01:00 a las 03:00 locales.
--  Las marcas de tiempo locales 02:00 y 02:30 existen DOS veces.
--  Por eso se almacena en UTC y se muestra en hora local.
-- =====================================================================


-- PASO 1 · Número de puntos por día (hora de Madrid), para un contador
--  Qué observar: 48 puntos los días 24 y 26, 50 puntos el 25.
SELECT
    dia,
    count() AS n_puntos
FROM silver.curva_carga FINAL
WHERE id_contador = sim_id_contador(7) AND magnitud = 'CONS'
  AND dia BETWEEN '2026-10-24' AND '2026-10-26'
GROUP BY dia
ORDER BY dia;
-- Medido: 164 ms · 49 152 filas leídas (1008 KB)


-- PASO 2 · La noche del 25: misma hora local, dos instantes distintos
--  Qué observar: 02:00 y 02:30 aparecen dos veces en hora local, con un desfase +0200
--  y luego +0100. En UTC no hay ningún duplicado: por eso ts se almacena en UTC.
SELECT
    ts                                    AS ts_utc,
    toTimeZone(ts, 'Europe/Madrid')        AS hora_local,
    formatDateTime(ts, '%z', 'Europe/Madrid') AS desfase,
    valor_w
FROM silver.curva_carga FINAL
WHERE id_contador = sim_id_contador(7) AND magnitud = 'CONS'
  AND ts BETWEEN '2026-10-24 23:00:00' AND '2026-10-25 03:00:00'
ORDER BY ts;
-- Medido: 116 ms · 16 384 filas leídas (400 KB)


-- PASO 3 · El número de puntos esperados se calcula, no se supone
--  Medimos la duración real del día local en minutos y la dividimos entre 30.
--  El KPI de completitud del módulo 5 usa exactamente este cálculo.
SELECT
    dia,
    dateDiff('minute', toDateTime(dia, 'Europe/Madrid'), toDateTime(dia + 1, 'Europe/Madrid')) / 30 AS puntos_esperados
FROM (SELECT toDate('2026-10-23') + number AS dia FROM numbers(5));
-- Medido: 3 ms · 5 filas leídas
-- Qué observar: 48 puntos esperados cada día, salvo 50 el 25 de octubre.
