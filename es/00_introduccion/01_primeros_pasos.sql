-- =====================================================================
--  MÓDULO 0 · Primeros pasos: de numbers() a un fichero de medida real
-- =====================================================================
--  Idea clave: en ClickHouse, un SELECT puede FABRICAR datos.
--  Partimos de cero y construimos, paso a paso, un fichero de energía diaria
--  con el mismo formato que los que recibes de la distribuidora (DSO).
--
--  Cómo usarlo: coloca el cursor dentro de una consulta y pulsa
--  Cmd + Mayús + Intro para ejecutarla sola. Abajo, la consola SQL
--  muestra la duración, el número de filas leídas y el volumen leído:
--  son las tres cifras que vas a mirar durante todo el workshop.
-- =====================================================================


-- PASO 1 · numbers() es una "table function": genera filas
--  Una table function se usa después de FROM como una tabla, pero
--  calcula sus filas al vuelo. numbers(10) devuelve los enteros del 0 al 9.
--  La usamos para simular millones de filas sin almacenar nada.
SELECT number
FROM numbers(10);
-- Medido: 1 ms · 10 filas leídas


-- PASO 2 · Aplicamos funciones a cada fila
--  cityHash64 siempre da el mismo resultado para la misma entrada: es
--  un "azar" reproducible, idéntico para todos los participantes.
--  randCanonical, en cambio, cambia en cada ejecución.
SELECT
    number,
    toDate('2026-10-01') + number              AS dia,
    cityHash64(number) % 100                   AS azar_determinista,
    round(80000 + 60000 * randCanonical(), 2)  AS energia_wh
FROM numbers(10);
-- Medido: 2 ms · 10 filas leídas


-- PASO 3 · Un identificador de contador realista de 14 cifras
--  Un contador cabe en un UInt64 (8 bytes). leftPad lo devuelve al formato
--  texto de 14 cifras, como en los ficheros de la distribuidora.
SELECT leftPad(toString(10000000000000 + number * 4093 + cityHash64(number) % 4093), 14, '0') AS idContador
FROM numbers(5);
-- Medido: 2 ms · 5 filas leídas


-- PASO 4 · Una medida de energía diaria: una tupla con nombres se convierte en objeto JSON
--  tuple(valor AS nombre, ...) crea una estructura; toJSONString la convierte
--  en un objeto JSON cuyas claves son los nombres. Un array [...] se convierte
--  en una lista JSON. El ajuste enable_named_columns_in_function_tuple conserva
--  los nombres.
SELECT toJSONString(tuple(
    leftPad(toString(10000000000000 + 4093), 14, '0')  AS idContador,
    'BRUTO'                                              AS etapa,
    tuple('2026-10-01' AS fechaInicio, '2026-10-02' AS fechaFin) AS periodo,
    'GLOBAL'                                           AS tipoValor,
    'DIFF.INDEX'                                        AS modoCalculo,
    'P1D'                                               AS paso,
    [tuple('EA' AS magnitudFisica, 'CONS' AS magnitudNegocio, 'Wh' AS unidad,
           [tuple('2026-10-01' AS d, '190205.98' AS v)] AS puntos)] AS magnitud
)) AS medida_json
SETTINGS enable_named_columns_in_function_tuple = 1;
-- Medido: 2 ms · 1 fila leída


-- PASO 5 · Un fichero completo: una cabecera + 1000 medidas
--  arrayMap(i -> ..., range(1000)) hace de bucle: aplica la función a cada
--  elemento del array 0..999 y devuelve el array de resultados.
--  Una sola fila de resultado = un fichero entero.
SELECT toJSONString(tuple(
    tuple('PORTAL DATOS' AS solicitante, 'ENTIDAD_LOCAL' AS tipoDestinatario,
          '488903' AS idDestinatario, 'ENERGIAD' AS codigoFlujo, 'RECURRENTE' AS modoPublicacion,
          'JSON' AS format) AS cabecera,
    arrayMap(i -> tuple(
        leftPad(toString(10000000000000 + i * 4093 + cityHash64(i) % 4093), 14, '0') AS idContador,
        'BRUTO' AS etapa,
        tuple('2026-10-01' AS fechaInicio, '2026-10-02' AS fechaFin) AS periodo,
        'P1D' AS paso,
        [tuple('EA' AS magnitudFisica, 'CONS' AS magnitudNegocio, 'Wh' AS unidad,
               [tuple('2026-10-01' AS d, toString(round(80000 + 60000 * (cityHash64(i) % 1000) / 1000, 2)) AS v)] AS puntos)] AS magnitud
    ), range(1000)) AS medidas
)) AS fichero_energia_dia
SETTINGS enable_named_columns_in_function_tuple = 1;
-- Medido: 4 ms · 1 fila leída
-- Qué observar: copia el resultado en un visor JSON. Aparece exactamente la
-- estructura del formato de origen: cabecera, luego medidas > magnitud > puntos.


-- PASO 6 · El aperitivo: 1 MILLÓN de medidas JSON. ¿Cuánto tarda?
--  Cada fila fabrica y serializa un pequeño objeto JSON. ClickHouse
--  divide numbers() en bloques y los procesa en paralelo en todos los núcleos.
SELECT
    count()                                   AS n_medidas,
    formatReadableSize(sum(length(json)))     AS volumen_json
FROM
(
    SELECT toJSONString(tuple(
        leftPad(toString(10000000000000 + number * 4093 + cityHash64(number) % 4093), 14, '0') AS idContador,
        'BRUTO' AS etapa,
        toString(round(80000 + 60000 * (cityHash64(number) % 1000) / 1000, 2)) AS v
    )) AS json
    FROM numbers(1000000)
)
SETTINGS enable_named_columns_in_function_tuple = 1;
-- Medido: 271 ms · 1 M filas leídas (7,6 MB)
-- Qué observar: la duración abajo en la consola. Sustituye 1000000 por 10000000:
-- el tiempo se multiplica más o menos por 10, la velocidad en filas/s se mantiene.
