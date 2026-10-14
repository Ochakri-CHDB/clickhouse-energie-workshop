-- =====================================================================
--  MODULE 2 · The metering flow simulator (run it as is)
-- =====================================================================
--  We cannot share real data. So we SIMULATE it with
--  SQL functions (UDFs) that reproduce real-world behavior:
--    · residential : morning peak, big evening peak
--    · commercial  : 8am-7pm plateau on weekdays, trough on weekends
--    · solar       : bell curve, different weather per department
--    · industry    : high base load, also runs on weekends
--    · October     : it gets colder and colder, consumption goes up
--  Target orders of magnitude (French fleet, October): a household ~12 kWh/day,
--  a C2 site loaded at ~25% of its power, weekend ≈ 0.7 × weekday,
--  energy RES / PRO / ENT ≈ 37 / 34 / 28%.
--  Everything is deterministic: everyone gets exactly the same numbers.
-- =====================================================================


-- UDFs: one function = one reusable SQL expression
--  A SQL UDF is not external code: it is an expression that ClickHouse
--  copies into the query when it runs it. No call overhead, and
--  it benefits from vectorized execution like any native function.
--  All the simulator functions start with sim_.
CREATE OR REPLACE FUNCTION sim_meter_id AS (n) ->
    toUInt64(10000000000000 + n * 4093 + cityHash64(n) % 4093);

CREATE OR REPLACE FUNCTION sim_random AS (a, b, c) ->
    (cityHash64(a, b, c) % 1000000) / 1000000.;                -- deterministic "random" between 0 and 1

CREATE OR REPLACE FUNCTION sim_local_hour AS (ts) ->
    toHour(ts - 900, 'Europe/Paris') + toMinute(ts - 900, 'Europe/Paris') / 60;   -- middle of the interval

CREATE OR REPLACE FUNCTION sim_utc_hour AS (ts) ->
    toHour(ts - 900, 'UTC') + toMinute(ts - 900, 'UTC') / 60;

--  sim_cons_w: the average power (W) of a meter over a half-hour.
--  = level (share of the subscribed power) × shape of the day × season × noise.
CREATE OR REPLACE FUNCTION sim_cons_w AS (id, profile, kva, ts) ->
    toUInt32(round(
        kva * 1000 * multiIf(profile = 'RES', 0.10,                                  -- level: share of the subscribed power
                             profile = 'ENT', 0.29,                                  --   industry (C2): heavy use
                             kva > 36,       0.24,                                  --   SMEs, commercial (C4)
                                             0.13)                                  --   small business (C5)
        * multiIf(
            profile = 'RES',                                                       -- household: morning and evening peaks
                (0.30 + 0.55 * exp(-pow(sim_local_hour(ts) - 7.5, 2) / 1.5)
                      + 1.00 * exp(-pow(sim_local_hour(ts) - 20.0, 2) / 3.0)
                      + 0.15 * exp(-pow(sim_local_hour(ts) - 13.0, 2) / 2.0))
                * if(toDayOfWeek(ts, 0, 'Europe/Paris') >= 6, 1.10, 1.0),         -- a bit more on weekends
            toDayOfWeek(ts, 0, 'Europe/Paris') >= 6,
                if(profile = 'ENT', 0.55, 0.30),                                   -- weekend: industry partly keeps running
            if(profile = 'ENT', 0.55, 0.30)
                + if(profile = 'ENT', 0.65, 0.90)
                  / ((1 + exp(-2 * (sim_local_hour(ts) - 8))) * (1 + exp(2 * (sim_local_hour(ts) - 19)))))  -- 8am-7pm plateau
        * (1 + if(profile = 'RES', 0.008, 0.003) * toDayOfMonth(ts, 'Europe/Paris'))  -- October gets colder: household heating weighs the most
        * (0.75 + 0.50 * sim_random(id, ts, 'bruit'))                               -- noise
    ));

--  sim_prod_w: solar production = peak power × sun × weather of the day.
CREATE OR REPLACE FUNCTION sim_prod_w AS (id, dept_code, kwp, ts) ->
    toUInt32(round(
        kwp * 850
        * greatest(0, sin(pi() * (sim_utc_hour(ts) - 6.4) / 10.4))   -- the sun (solar time ≈ UTC)
        * (0.25 + 0.75 * sim_random(dept_code, toDate(ts), 'meteo'))     -- clouds of the day, per department
        * (0.90 + 0.20 * sim_random(id, ts, 'bruit'))
    ));

CREATE OR REPLACE FUNCTION sim_iso AS (ts) ->                       -- source format: 2026-10-25T02:30:00+01:00
    concat(substring(formatDateTime(ts, '%Y-%m-%dT%H:%i:%S%z', 'Europe/Paris'), 1, 22), ':',
           substring(formatDateTime(ts, '%Y-%m-%dT%H:%i:%S%z', 'Europe/Paris'), 23, 2));

CREATE OR REPLACE FUNCTION sim_day_points AS (day) ->        -- ends of 30-min intervals, local time
    arrayMap(x -> toDateTime(x, 'UTC'),
             range(toUInt32(toDateTime(day, 'Europe/Paris')) + 1800,
                   toUInt32(toDateTime(day + 1, 'Europe/Paris')) + 1, 1800));


-- The simulator dictionary: the characteristics of each meter in memory
--  To generate a curve, we need the profile, the power and the solar panels
--  of each meter. A dictionary loads this data into RAM once, then
--  dictGet reads it in constant time, without a join (details in module 4).
CREATE OR REPLACE DICTIONARY simulator.dict_meter
(
    meter_id         UInt64,
    profile         String,
    power_kva  UInt16,
    pv_kwp         Float32,
    dept_code      String,
    old_end   Date,                -- last day of the old power (1970-01-01 if never changed)
    old_kva     UInt16
)
PRIMARY KEY meter_id
SOURCE(CLICKHOUSE(
    QUERY 'SELECT p.meter_id, p.profile, p.power_kva, p.pv_kwp, c.dept_code, h.valid_to, h.power_kva
           FROM ref.meter AS p
           INNER JOIN ref.municipality AS c USING (insee_code)
           LEFT JOIN (SELECT meter_id, valid_to, power_kva FROM ref.meter_history WHERE valid_to < ''2099-01-01'') AS h USING (meter_id)'
    USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(HASHED())
LIFETIME(0);


-- The 3 file generators, as PARAMETERIZED VIEWS
--  File no. k = day (k / 20) of October, batch (k % 20) of 1000 meters.
--  Each batch belongs to a metropolitan area (sim_recipient, module 1).
--  Usage: SELECT * FROM simulator.curve_files(start = 0, n = 20)  → October 1
--
--  Trap avoided: in ClickHouse an alias is GLOBAL to the query. Writing
--  'CONS' AS businessQuantity then 'PROD' AS businessQuantity makes the 2nd alias
--  take the value of the 1st. So we build tuples WITHOUT aliases, then
--  convert them in one go (CAST) to a named type: the names become the
--  JSON keys.
--
--  A parameterized view is a saved query with parameters
--  ({start:UInt32}, {n:UInt32}). You call it like a table function.

CREATE OR REPLACE VIEW simulator.curve_files AS
WITH
    toDate('2026-10-01') + intDiv(number, 20)                                  AS day,
    number % 20                                                                 AS batch,
    -- arrival: the next day between 6am and 8am, except ~1% of late files (in the afternoon)
    toDateTime64(toDateTime(day + 1, 'Europe/Paris'), 3, 'UTC')
        + toIntervalSecond(if(sim_random(day, batch, 'retard') < 0.01, 50400, 21600 + batch * 300 + cityHash64(day, batch) % 240)) AS arrival,
    sim_day_points(day)                                                    AS timestamps,
    -- ~0.3% of meters sent nothing that day (communication failure)
    arrayFilter(n -> sim_random(n, day, 'panne') >= 0.003, range(batch * 1000, batch * 1000 + 1000)) AS ns,
    arrayMap(n -> sim_meter_id(n), ns)                                            AS ids,
    arrayMap(id -> dictGet('simulator.dict_meter', ('profile', 'power_kva', 'pv_kwp', 'dept_code'), id), ids) AS attrs
SELECT
    concat('DSO_CURVE_30MIN_PUB_', toString(100000 + number), '_', sim_recipient(batch), '_', formatDateTime(arrival, '%Y%m%d%H%i%S'), '.zip') AS file_name,
    'CURVE'   AS flow_code,
    arrival AS ingested_at,
    toJSONString(CAST((
        ('DATA PORTAL', 'LOCAL_AUTHORITY', sim_recipient(batch), 'CURVE30', toString(100000 + number), 'RECURRING', 'JSON'),
        arrayMap((id, a) -> (
            leftPad(toString(id), 14, '0'),
            'RAW',
            (toString(day), toString(day + 1)),
            'PT30M',
            arrayConcat(
                -- consumption: ~0.02% missing points, ~0.03% empty values (rejects)
                [('PA', 'CONS', 'W',
                  arrayMap(t -> (sim_iso(t), if(sim_random(id, t, 'ko') < 0.0003, '', toString(sim_cons_w(id, a.1, a.2, t)))),
                           arrayFilter(t -> sim_random(id, t, 'trou') >= 0.0002, timestamps)))],
                -- production, only for meters with solar panels
                if(a.3 > 0,
                   [('PA', 'PROD', 'W', arrayMap(t -> (sim_iso(t), toString(sim_prod_w(id, a.4, a.3, t))), timestamps))],
                   []))
        ), ids, attrs)
    ), 'Tuple(header Tuple(requester String, recipientType String, recipientId String, flowCode String, publicationId String, publicationMode String, format String),
              measurements Array(Tuple(meterId String, stage String, period Tuple(startDate String, endDate String), step String,
                                  quantity Array(Tuple(physicalQuantity String, businessQuantity String, unit String,
                                                       points Array(Tuple(d String, v String)))))))')) AS payload
FROM numbers({start:UInt32}, {n:UInt32});

CREATE OR REPLACE VIEW simulator.energy_files AS
WITH
    toDate('2026-10-01') + intDiv(number, 20)                                  AS day,
    number % 20                                                                 AS batch,
    toDateTime64(toDateTime(day + 1, 'Europe/Paris'), 3, 'UTC') + toIntervalSecond(25200 + batch * 120) AS arrival,
    sim_day_points(day)                                                    AS timestamps,
    arrayMap(n -> sim_meter_id(n), range(batch * 1000, batch * 1000 + 1000))          AS ids,
    arrayMap(id -> dictGet('simulator.dict_meter', ('profile', 'power_kva', 'pv_kwp', 'dept_code'), id), ids) AS attrs
SELECT
    concat('DSO_ENERGY_DAY_PUB_', toString(200000 + number), '_', sim_recipient(batch), '_', formatDateTime(arrival, '%Y%m%d%H%i%S'), '.zip') AS file_name,
    'ENERGY'   AS flow_code,
    arrival AS ingested_at,
    toJSONString(CAST((
        ('DATA PORTAL', 'LOCAL_AUTHORITY', sim_recipient(batch), 'ENERGYD', toString(200000 + number), 'RECURRING', 'JSON'),
        arrayMap((id, a) -> (
            leftPad(toString(id), 14, '0'),
            'RAW',
            (toString(day), toString(day + 1)),
            'GLOBAL', 'DIFF.INDEX', 'P1D',
            arrayConcat(
                -- energy comes from the meter indexes: complete even when the curve has gaps
                [('EA', 'CONS', 'Wh', [(toString(day),
                    toString(round(arraySum(arrayMap(t -> sim_cons_w(id, a.1, a.2, t), timestamps)) / 2
                                   * (0.998 + 0.004 * sim_random(id, day, 'index')), 2)))])],
                if(a.3 > 0,
                   [('EA', 'PROD', 'Wh', [(toString(day),
                       toString(round(arraySum(arrayMap(t -> sim_prod_w(id, a.4, a.3, t), timestamps)) / 2, 2)))])],
                   []))
        ), ids, attrs)
    ), 'Tuple(header Tuple(requester String, recipientType String, recipientId String, flowCode String, publicationId String, publicationMode String, format String),
              measurements Array(Tuple(meterId String, stage String, period Tuple(startDate String, endDate String),
                                  valueType String, calcMode String, step String,
                                  quantity Array(Tuple(physicalQuantity String, businessQuantity String, unit String,
                                                       points Array(Tuple(d String, v String)))))))')) AS payload
FROM numbers({start:UInt32}, {n:UInt32});

CREATE OR REPLACE VIEW simulator.pmax_files AS
WITH
    toDate('2026-10-01') + intDiv(number, 20)                                  AS day,
    number % 20                                                                 AS batch,
    toDateTime64(toDateTime(day + 1, 'Europe/Paris'), 3, 'UTC') + toIntervalSecond(27000 + batch * 120) AS arrival,
    sim_day_points(day)                                                    AS timestamps,
    arrayMap(n -> sim_meter_id(n), range(batch * 1000, batch * 1000 + 1000))          AS ids,
    arrayMap(id -> dictGet('simulator.dict_meter', ('profile', 'power_kva', 'pv_kwp', 'dept_code', 'old_end', 'old_kva'), id), ids) AS attrs
SELECT
    concat('DSO_PMAX_DAY_PUB_', toString(300000 + number), '_', sim_recipient(batch), '_', formatDateTime(arrival, '%Y%m%d%H%i%S'), '.zip') AS file_name,
    'PMAX'   AS flow_code,
    arrival AS ingested_at,
    toJSONString(CAST((
        ('DATA PORTAL', 'LOCAL_AUTHORITY', sim_recipient(batch), 'PMAXD', toString(300000 + number), 'RECURRING', 'JSON'),
        arrayMap((id, a) -> (
            leftPad(toString(id), 14, '0'),
            'RAW',
            (toString(day), toString(day + 1)),
            'P1D',
            [('PMA', 'CONS', 'VA', [(
                -- the instant of the day's peak
                sim_iso(arraySort(t -> -sim_cons_w(id, a.1, a.2, t), timestamps)[1]),
                -- the subscribed power IN FORCE that day: a.6 before the change, a.2 after
                toString(toUInt32(multiIf(
                    -- C4 / C2: overruns are possible (and billed). ~3% of days,
                    -- ~25% before a power increase (the customer upgraded because they were overrunning)
                    if(day <= a.5, a.6, a.2) > 36 AND sim_random(id, day, 'pic') < if(day <= a.5, 0.25, 0.03),
                        if(day <= a.5, a.6, a.2) * 1000 * (1.02 + 0.25 * sim_random(id, day, 'amplitude')),
                    if(day <= a.5, a.6, a.2) > 36,
                        arrayMax(arrayMap(t -> sim_cons_w(id, a.1, a.2, t), timestamps)) * 1.15,
                    -- C5: the meter's breaker trips, PMax never exceeds the subscribed power
                    least(arrayMax(arrayMap(t -> sim_cons_w(id, a.1, a.2, t), timestamps)) * 1.25,
                          if(day <= a.5, a.6, a.2) * 980))))
            )])]
        ), ids, attrs)
    ), 'Tuple(header Tuple(requester String, recipientType String, recipientId String, flowCode String, publicationId String, publicationMode String, format String),
              measurements Array(Tuple(meterId String, stage String, period Tuple(startDate String, endDate String), step String,
                                  quantity Array(Tuple(physicalQuantity String, businessQuantity String, unit String,
                                                       points Array(Tuple(d String, v String)))))))')) AS payload
FROM numbers({start:UInt32}, {n:UInt32});


-- Let's test: the curve of a residential meter and of a meter with solar panels
--  bar() draws a text bar proportional to the value: a chart
--  right in the result.
--  What to look for: the morning peak around 7-8am, the big evening peak around
--  7-9pm, and production that only amounts to something around midday.
SELECT
    sim_iso(ts)                                                         AS ts_text,
    sim_cons_w(sim_meter_id(1), 'RES', 9, ts)                            AS cons_w,
    sim_prod_w(sim_meter_id(1), '92', 6, ts)                              AS prod_w,
    bar(cons_w, 0, 3000, 30)                                           AS cons_chart
FROM (SELECT arrayJoin(sim_day_points(toDate('2026-10-15'))) AS ts);
-- Measured: 11 ms · 1 row read

-- The day of the clock change (October 25) has 50 half-hours
--  sim_day_points computes the timestamps from midnight Paris time:
--  on October 25, the night lasts one hour longer, hence 2 extra points.
SELECT day, length(sim_day_points(day)) AS n_points
FROM (SELECT toDate('2026-10-24') + number AS day FROM numbers(3));
-- Measured: 2 ms · 3 rows read
