-- =====================================================================
--  MÓDULO 5 · Gold (4/4): la forma de consumo de cada contador
-- =====================================================================
--  Una tabla de "features" para ciencia de datos (módulo 8, agente + Run Code).
--  Cada contador se resume en su forma media: 24 valores para un día
--  laborable y 24 para un día de fin de semana, divididos por su consumo
--  medio (1 = la media del contador). 30 M de puntos se convierten en 20 000 filas.
--
--  Buena práctica: preparamos los datos en ClickHouse (rápido, lo más cerca
--  posible de los datos) y al modelo Python solo le enviamos el resultado pequeño.
-- =====================================================================


-- PASO 1 · La tabla: una fila por contador, las formas en arrays
--  Array(Float32): 24 valores en una sola columna, que se leen de una vez.
--  ORDER BY (segmento, perfil, id_contador): a menudo se muestrea por segmento.
CREATE OR REPLACE TABLE gold.perfil_contador
(
    id_contador          UInt64,
    perfil          LowCardinality(String),
    segmento         LowCardinality(String),
    potencia_kva   UInt16,
    consumo_medio_w     Float64,
    forma_laborable   Array(Float32),
    forma_finde   Array(Float32)
)
ENGINE = MergeTree
ORDER BY (segmento, perfil, id_contador);


-- PASO 2 · El cálculo, en una sola consulta
--  La subconsulta calcula la media por contador, tipo de día y hora local.
--  groupArrayIf reúne las 24 horas de un tipo de día en un array,
--  arraySort((x, h) -> h, ...) las vuelve a poner en orden de hora,
--  y arrayMap divide cada valor por la media del contador.
INSERT INTO gold.perfil_contador
SELECT
    id_contador,
    dictGet('ref.dict_contador', 'perfil', id_contador),
    dictGet('ref.dict_contador', 'segmento', id_contador),
    dictGet('ref.dict_contador', 'potencia_kva', id_contador),
    round(avg(consumo_w), 1),
    arrayMap(x -> toFloat32(round(x / avg(consumo_w), 3)), arraySort((x, h) -> h, groupArrayIf(consumo_w, tipo_dia = 'laborable'), groupArrayIf(hora, tipo_dia = 'laborable'))),
    arrayMap(x -> toFloat32(round(x / avg(consumo_w), 3)), arraySort((x, h) -> h, groupArrayIf(consumo_w, tipo_dia = 'fin de semana'), groupArrayIf(hora, tipo_dia = 'fin de semana')))
FROM
(
    SELECT id_contador,
           if(toDayOfWeek(ts - 1, 0, 'Europe/Madrid') >= 6, 'fin de semana', 'laborable') AS tipo_dia,
           toHour(ts - 900, 'Europe/Madrid') AS hora,
           avg(valor_w) AS consumo_w
    FROM silver.curva_carga FINAL
    WHERE magnitud = 'CONS'
    GROUP BY id_contador, tipo_dia, hora
)
GROUP BY id_contador;
-- Medido: 431 ms · 30,5 M filas leídas (727,4 MB) · 20 000 filas escritas · 463,1 MB de memoria


-- PASO 3 · Comentarios para el agente (módulo 8)
ALTER TABLE gold.perfil_contador
    MODIFY COMMENT 'Forma de consumo media de cada contador en octubre de 2026, para ciencia de datos. Una fila por contador.';
-- Medido: 74 ms
ALTER TABLE gold.perfil_contador
    COMMENT COLUMN segmento       'C5 (hasta 36 kVA), C4 (de 36 a 250 kVA), C2 (conectado en media tensión, HTA)',
    COMMENT COLUMN perfil        'Perfil declarado: RES (residencial), PRO (profesional), ENT (empresa, industria)',
    COMMENT COLUMN consumo_medio_w   'Potencia media del contador en el mes, en W',
    COMMENT COLUMN forma_laborable '24 valores, de 0h a 23h (hora de Madrid), día laborable, divididos por consumo_medio_w',
    COMMENT COLUMN forma_finde '24 valores, de 0h a 23h (hora de Madrid), día de fin de semana, divididos por consumo_medio_w';
-- Medido: 74 ms


-- PASO 4 · Las formas medias por perfil
SELECT perfil, count() AS contadores, arrayMap(x -> round(x, 1), any(forma_laborable)) AS ejemplo_laborable
FROM gold.perfil_contador
GROUP BY perfil;
-- Medido: 9 ms · 20 000 filas leídas (2 MB)
-- Qué observar: la punta de la tarde-noche de los hogares (RES), la meseta de 8h a 19h de
-- los profesionales (PRO), la base de consumo elevada de la industria (ENT).

--  La muestra que usará el agente: 30 contadores por segmento, en una consulta
SELECT segmento, perfil, count() AS contadores
FROM (SELECT segmento, perfil FROM gold.perfil_contador ORDER BY cityHash64(id_contador) LIMIT 30 BY segmento)
GROUP BY segmento, perfil
ORDER BY segmento, perfil;
-- Medido: 4 ms · 20 000 filas leídas (195,4 KB)
-- Qué observar: LIMIT 30 BY segmento conserva 30 filas por cada valor de segmento.
-- El segmento C5 mezcla hogares y pequeños profesionales.


-- CHECKPOINT MÓDULO 5 (4/4)
--  Una fila por cada contador de los ficheros JSON (20 000, o 19 999 si el módulo 7 ya
--  ha borrado un contador), con 24 valores por forma.
SELECT
    if((SELECT count() FROM gold.perfil_contador) >= 19999, 'OK', 'ERROR') AS formas,
    if((SELECT min(length(forma_laborable)) FROM gold.perfil_contador) = 24, 'OK', 'ERROR') AS longitud_24
SETTINGS select_sequential_consistency = 1;
