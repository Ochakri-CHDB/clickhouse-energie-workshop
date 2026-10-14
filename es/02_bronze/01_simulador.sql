-- =====================================================================
--  MÓDULO 2 · El simulador de flujos de medida (ejecútalo tal cual)
-- =====================================================================
--  No podemos compartir datos reales. Así que los SIMULAMOS con
--  funciones SQL (UDF) que reproducen comportamientos reales:
--    · residencial : punta de la mañana, gran punta de la noche
--    · terciario   : meseta de 8h a 19h entre semana, valle el fin de semana
--    · solar       : curva en campana, meteorología distinta por departamento
--    · industria   : consumo base alto, también funciona el fin de semana
--    · octubre     : cada vez hace más frío, el consumo sube
--  Órdenes de magnitud buscados (parque francés, octubre): un hogar ~12 kWh/día,
--  un sitio C2 cargado al ~25 % de su potencia, fin de semana ≈ 0,7 × laborable,
--  energía RES / PRO / ENT ≈ 37 / 34 / 28 %.
--  Todo es determinista: todos obtienen exactamente las mismas cifras.
-- =====================================================================


-- Las UDF: una función = una expresión SQL reutilizable
--  Una UDF SQL no es código externo: es una expresión que ClickHouse
--  copia dentro de la consulta en el momento de ejecutarla. Sin coste de llamada,
--  y aprovecha el cálculo vectorizado como cualquier función nativa.
--  Todas las funciones del simulador empiezan por sim_.
CREATE OR REPLACE FUNCTION sim_id_contador AS (n) ->
    toUInt64(10000000000000 + n * 4093 + cityHash64(n) % 4093);

CREATE OR REPLACE FUNCTION sim_aleatorio AS (a, b, c) ->
    (cityHash64(a, b, c) % 1000000) / 1000000.;                -- "azar" determinista entre 0 y 1

CREATE OR REPLACE FUNCTION sim_hora_local AS (ts) ->
    toHour(ts - 900, 'Europe/Paris') + toMinute(ts - 900, 'Europe/Paris') / 60;   -- mitad del intervalo

CREATE OR REPLACE FUNCTION sim_hora_utc AS (ts) ->
    toHour(ts - 900, 'UTC') + toMinute(ts - 900, 'UTC') / 60;

--  sim_consumo_w: la potencia media (W) de un contador en una media hora.
--  = nivel (fracción de la potencia contratada) × forma del día × estación × ruido.
CREATE OR REPLACE FUNCTION sim_consumo_w AS (id, perfil, kva, ts) ->
    toUInt32(round(
        kva * 1000 * multiIf(perfil = 'RES', 0.10,                                  -- nivel: fracción de la potencia contratada
                             perfil = 'ENT', 0.29,                                  --   industria (C2): uso intensivo
                             kva > 36,       0.24,                                  --   pyme, terciario (C4)
                                             0.13)                                  --   pequeño profesional (C5)
        * multiIf(
            perfil = 'RES',                                                       -- hogar: puntas de mañana y noche
                (0.30 + 0.55 * exp(-pow(sim_hora_local(ts) - 7.5, 2) / 1.5)
                      + 1.00 * exp(-pow(sim_hora_local(ts) - 20.0, 2) / 3.0)
                      + 0.15 * exp(-pow(sim_hora_local(ts) - 13.0, 2) / 2.0))
                * if(toDayOfWeek(ts, 0, 'Europe/Paris') >= 6, 1.10, 1.0),         -- un poco más el fin de semana
            toDayOfWeek(ts, 0, 'Europe/Paris') >= 6,
                if(perfil = 'ENT', 0.55, 0.30),                                   -- fin de semana: la industria funciona en parte
            if(perfil = 'ENT', 0.55, 0.30)
                + if(perfil = 'ENT', 0.65, 0.90)
                  / ((1 + exp(-2 * (sim_hora_local(ts) - 8))) * (1 + exp(2 * (sim_hora_local(ts) - 19)))))  -- meseta de 8h a 19h
        * (1 + if(perfil = 'RES', 0.008, 0.003) * toDayOfMonth(ts, 'Europe/Paris'))  -- octubre se enfría: la calefacción de los hogares es lo que más pesa
        * (0.75 + 0.50 * sim_aleatorio(id, ts, 'bruit'))                               -- ruido
    ));

--  sim_prod_w: la producción solar = potencia pico × sol × meteorología del día.
CREATE OR REPLACE FUNCTION sim_prod_w AS (id, codigo_dpto, kwp, ts) ->
    toUInt32(round(
        kwp * 850
        * greatest(0, sin(pi() * (sim_hora_utc(ts) - 6.4) / 10.4))   -- el sol (hora solar ≈ UTC)
        * (0.25 + 0.75 * sim_aleatorio(codigo_dpto, toDate(ts), 'meteo'))     -- nubes del día, por departamento
        * (0.90 + 0.20 * sim_aleatorio(id, ts, 'bruit'))
    ));

CREATE OR REPLACE FUNCTION sim_iso AS (ts) ->                       -- formato de origen: 2026-10-25T02:30:00+01:00
    concat(substring(formatDateTime(ts, '%Y-%m-%dT%H:%i:%S%z', 'Europe/Paris'), 1, 22), ':',
           substring(formatDateTime(ts, '%Y-%m-%dT%H:%i:%S%z', 'Europe/Paris'), 23, 2));

CREATE OR REPLACE FUNCTION sim_puntos_dia AS (dia) ->        -- finales de intervalos de 30 min, hora local
    arrayMap(x -> toDateTime(x, 'UTC'),
             range(toUInt32(toDateTime(dia, 'Europe/Paris')) + 1800,
                   toUInt32(toDateTime(dia + 1, 'Europe/Paris')) + 1, 1800));


-- El diccionario del simulador: las características de cada contador en memoria
--  Para generar una curva hacen falta el perfil, la potencia y los paneles
--  de cada contador. Un diccionario carga esa información en RAM una vez, y luego
--  dictGet la lee en tiempo constante, sin join (detalles en el módulo 4).
CREATE OR REPLACE DICTIONARY simulador.dict_contador
(
    id_contador         UInt64,
    perfil         String,
    potencia_kva  UInt16,
    fv_kwp         Float32,
    codigo_dpto      String,
    fin_anterior   Date,                -- último día de la potencia anterior (1970-01-01 si nunca cambió)
    kva_anterior     UInt16
)
PRIMARY KEY id_contador
SOURCE(CLICKHOUSE(
    QUERY 'SELECT p.id_contador, p.perfil, p.potencia_kva, p.fv_kwp, c.codigo_dpto, h.valid_to, h.potencia_kva
           FROM ref.contador AS p
           INNER JOIN ref.municipio AS c USING (codigo_insee)
           LEFT JOIN (SELECT id_contador, valid_to, potencia_kva FROM ref.historial_contador WHERE valid_to < ''2099-01-01'') AS h USING (id_contador)'
    USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(HASHED())
LIFETIME(0);


-- Los 3 generadores de ficheros, en forma de VISTAS PARAMETRIZADAS
--  Fichero n.º k = día (k / 20) del mes de octubre, lote (k % 20) de 1000 contadores.
--  Cada lote pertenece a una metrópoli (sim_destinatario, módulo 1).
--  Uso: SELECT * FROM simulador.ficheros_curva(inicio = 0, n = 20)  → el 1 de octubre
--
--  Trampa evitada: en ClickHouse un alias es GLOBAL en la consulta. Escribir
--  'CONS' AS magnitudNegocio y luego 'PROD' AS magnitudNegocio hace que el 2.º alias
--  tome el valor del 1.º. Por eso construimos tuplas SIN alias y luego
--  las convertimos de golpe (CAST) a un tipo con nombres: los nombres pasan a ser
--  las claves del JSON.
--
--  Una vista parametrizada es una consulta guardada con parámetros
--  ({inicio:UInt32}, {n:UInt32}). Se llama como una table function.

CREATE OR REPLACE VIEW simulador.ficheros_curva AS
WITH
    toDate('2026-10-01') + intDiv(number, 20)                                  AS dia,
    number % 20                                                                 AS lote,
    -- llegada: al día siguiente entre las 6h y las 8h, salvo ~1 % de ficheros con retraso (por la tarde)
    toDateTime64(toDateTime(dia + 1, 'Europe/Paris'), 3, 'UTC')
        + toIntervalSecond(if(sim_aleatorio(dia, lote, 'retard') < 0.01, 50400, 21600 + lote * 300 + cityHash64(dia, lote) % 240)) AS llegada,
    sim_puntos_dia(dia)                                                    AS marcas_tiempo,
    -- ~0,3 % de los contadores no enviaron nada ese día (fallo de comunicación)
    arrayFilter(n -> sim_aleatorio(n, dia, 'panne') >= 0.003, range(lote * 1000, lote * 1000 + 1000)) AS ns,
    arrayMap(n -> sim_id_contador(n), ns)                                            AS ids,
    arrayMap(id -> dictGet('simulador.dict_contador', ('perfil', 'potencia_kva', 'fv_kwp', 'codigo_dpto'), id), ids) AS attrs
SELECT
    concat('DSO_CURVA_30MIN_PUB_', toString(100000 + number), '_', sim_destinatario(lote), '_', formatDateTime(llegada, '%Y%m%d%H%i%S'), '.zip') AS file_name,
    'CURVA'   AS codigo_flujo,
    llegada AS ingested_at,
    toJSONString(CAST((
        ('PORTAL DATOS', 'ENTIDAD_LOCAL', sim_destinatario(lote), 'CURVA30', toString(100000 + number), 'RECURRENTE', 'JSON'),
        arrayMap((id, a) -> (
            leftPad(toString(id), 14, '0'),
            'BRUTO',
            (toString(dia), toString(dia + 1)),
            'PT30M',
            arrayConcat(
                -- el consumo: ~0,02 % de puntos que faltan, ~0,03 % de valores vacíos (rechazos)
                [('PA', 'CONS', 'W',
                  arrayMap(t -> (sim_iso(t), if(sim_aleatorio(id, t, 'ko') < 0.0003, '', toString(sim_consumo_w(id, a.1, a.2, t)))),
                           arrayFilter(t -> sim_aleatorio(id, t, 'trou') >= 0.0002, marcas_tiempo)))],
                -- la producción, solo para los contadores con paneles
                if(a.3 > 0,
                   [('PA', 'PROD', 'W', arrayMap(t -> (sim_iso(t), toString(sim_prod_w(id, a.4, a.3, t))), marcas_tiempo))],
                   []))
        ), ids, attrs)
    ), 'Tuple(cabecera Tuple(solicitante String, tipoDestinatario String, idDestinatario String, codigoFlujo String, idPublicacion String, modoPublicacion String, format String),
              medidas Array(Tuple(idContador String, etapa String, periodo Tuple(fechaInicio String, fechaFin String), paso String,
                                  magnitud Array(Tuple(magnitudFisica String, magnitudNegocio String, unidad String,
                                                       puntos Array(Tuple(d String, v String)))))))')) AS payload
FROM numbers({inicio:UInt32}, {n:UInt32});

CREATE OR REPLACE VIEW simulador.ficheros_energia AS
WITH
    toDate('2026-10-01') + intDiv(number, 20)                                  AS dia,
    number % 20                                                                 AS lote,
    toDateTime64(toDateTime(dia + 1, 'Europe/Paris'), 3, 'UTC') + toIntervalSecond(25200 + lote * 120) AS llegada,
    sim_puntos_dia(dia)                                                    AS marcas_tiempo,
    arrayMap(n -> sim_id_contador(n), range(lote * 1000, lote * 1000 + 1000))          AS ids,
    arrayMap(id -> dictGet('simulador.dict_contador', ('perfil', 'potencia_kva', 'fv_kwp', 'codigo_dpto'), id), ids) AS attrs
SELECT
    concat('DSO_ENERGIA_DIA_PUB_', toString(200000 + number), '_', sim_destinatario(lote), '_', formatDateTime(llegada, '%Y%m%d%H%i%S'), '.zip') AS file_name,
    'ENERGIA'   AS codigo_flujo,
    llegada AS ingested_at,
    toJSONString(CAST((
        ('PORTAL DATOS', 'ENTIDAD_LOCAL', sim_destinatario(lote), 'ENERGIAD', toString(200000 + number), 'RECURRENTE', 'JSON'),
        arrayMap((id, a) -> (
            leftPad(toString(id), 14, '0'),
            'BRUTO',
            (toString(dia), toString(dia + 1)),
            'GLOBAL', 'DIFF.INDEX', 'P1D',
            arrayConcat(
                -- la energía sale de los índices: está completa aunque la curva tenga huecos
                [('EA', 'CONS', 'Wh', [(toString(dia),
                    toString(round(arraySum(arrayMap(t -> sim_consumo_w(id, a.1, a.2, t), marcas_tiempo)) / 2
                                   * (0.998 + 0.004 * sim_aleatorio(id, dia, 'index')), 2)))])],
                if(a.3 > 0,
                   [('EA', 'PROD', 'Wh', [(toString(dia),
                       toString(round(arraySum(arrayMap(t -> sim_prod_w(id, a.4, a.3, t), marcas_tiempo)) / 2, 2)))])],
                   []))
        ), ids, attrs)
    ), 'Tuple(cabecera Tuple(solicitante String, tipoDestinatario String, idDestinatario String, codigoFlujo String, idPublicacion String, modoPublicacion String, format String),
              medidas Array(Tuple(idContador String, etapa String, periodo Tuple(fechaInicio String, fechaFin String),
                                  tipoValor String, modoCalculo String, paso String,
                                  magnitud Array(Tuple(magnitudFisica String, magnitudNegocio String, unidad String,
                                                       puntos Array(Tuple(d String, v String)))))))')) AS payload
FROM numbers({inicio:UInt32}, {n:UInt32});

CREATE OR REPLACE VIEW simulador.ficheros_pmax AS
WITH
    toDate('2026-10-01') + intDiv(number, 20)                                  AS dia,
    number % 20                                                                 AS lote,
    toDateTime64(toDateTime(dia + 1, 'Europe/Paris'), 3, 'UTC') + toIntervalSecond(27000 + lote * 120) AS llegada,
    sim_puntos_dia(dia)                                                    AS marcas_tiempo,
    arrayMap(n -> sim_id_contador(n), range(lote * 1000, lote * 1000 + 1000))          AS ids,
    arrayMap(id -> dictGet('simulador.dict_contador', ('perfil', 'potencia_kva', 'fv_kwp', 'codigo_dpto', 'fin_anterior', 'kva_anterior'), id), ids) AS attrs
SELECT
    concat('DSO_PMAX_DIA_PUB_', toString(300000 + number), '_', sim_destinatario(lote), '_', formatDateTime(llegada, '%Y%m%d%H%i%S'), '.zip') AS file_name,
    'PMAX'   AS codigo_flujo,
    llegada AS ingested_at,
    toJSONString(CAST((
        ('PORTAL DATOS', 'ENTIDAD_LOCAL', sim_destinatario(lote), 'PMAXD', toString(300000 + number), 'RECURRENTE', 'JSON'),
        arrayMap((id, a) -> (
            leftPad(toString(id), 14, '0'),
            'BRUTO',
            (toString(dia), toString(dia + 1)),
            'P1D',
            [('PMA', 'CONS', 'VA', [(
                -- el instante de la punta del día
                sim_iso(arraySort(t -> -sim_consumo_w(id, a.1, a.2, t), marcas_tiempo)[1]),
                -- la potencia contratada VIGENTE ese día: a.6 antes del cambio, a.2 después
                toString(toUInt32(multiIf(
                    -- C4 / C2: excesos posibles (y facturados). ~3 % de los días,
                    -- ~25 % antes de una subida de potencia (el cliente la subió porque se pasaba)
                    if(dia <= a.5, a.6, a.2) > 36 AND sim_aleatorio(id, dia, 'pic') < if(dia <= a.5, 0.25, 0.03),
                        if(dia <= a.5, a.6, a.2) * 1000 * (1.02 + 0.25 * sim_aleatorio(id, dia, 'amplitude')),
                    if(dia <= a.5, a.6, a.2) > 36,
                        arrayMax(arrayMap(t -> sim_consumo_w(id, a.1, a.2, t), marcas_tiempo)) * 1.15,
                    -- C5: el interruptor del contador corta, la PMax nunca supera la potencia contratada
                    least(arrayMax(arrayMap(t -> sim_consumo_w(id, a.1, a.2, t), marcas_tiempo)) * 1.25,
                          if(dia <= a.5, a.6, a.2) * 980))))
            )])]
        ), ids, attrs)
    ), 'Tuple(cabecera Tuple(solicitante String, tipoDestinatario String, idDestinatario String, codigoFlujo String, idPublicacion String, modoPublicacion String, format String),
              medidas Array(Tuple(idContador String, etapa String, periodo Tuple(fechaInicio String, fechaFin String), paso String,
                                  magnitud Array(Tuple(magnitudFisica String, magnitudNegocio String, unidad String,
                                                       puntos Array(Tuple(d String, v String)))))))')) AS payload
FROM numbers({inicio:UInt32}, {n:UInt32});


-- Probemos: la curva de un residencial y de un contador con paneles solares
--  bar() dibuja una barra de texto proporcional al valor: un gráfico
--  directamente en el resultado.
--  Qué observar: la punta de la mañana hacia las 7h-8h, la gran punta de la noche
--  hacia las 19h-21h, y la producción, que solo cuenta a mediodía.
SELECT
    sim_iso(ts)                                                         AS ts_texto,
    sim_consumo_w(sim_id_contador(1), 'RES', 9, ts)                            AS consumo_w,
    sim_prod_w(sim_id_contador(1), '92', 6, ts)                              AS prod_w,
    bar(consumo_w, 0, 3000, 30)                                           AS grafico_consumo
FROM (SELECT arrayJoin(sim_puntos_dia(toDate('2026-10-15'))) AS ts);
-- Medido: 11 ms · 1 fila leída

-- El día del cambio de hora (25 de octubre) tiene 50 medias horas
--  sim_puntos_dia calcula las marcas de tiempo a partir de la medianoche, hora de París:
--  el 25 de octubre la noche dura una hora más, así que hay 2 puntos más.
SELECT dia, length(sim_puntos_dia(dia)) AS n_puntos
FROM (SELECT toDate('2026-10-24') + number AS dia FROM numbers(3));
-- Medido: 2 ms · 3 filas leídas
