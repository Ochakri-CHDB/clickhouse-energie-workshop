-- =====================================================================
--  MODULE 0 · First steps: from numbers() to a real metering file
-- =====================================================================
--  Key idea: in ClickHouse, a SELECT can MAKE data.
--  We start from nothing and build, step by step, a daily energy file
--  in the same format as the ones you receive from the distribution system operator.
--
--  How to use it: put the cursor inside a query and press
--  Cmd + Shift + Enter to run it on its own. At the bottom, the
--  console shows the duration, the number of rows read and the volume read:
--  these are the three numbers to watch throughout the workshop.
-- =====================================================================


-- STEP 1 · numbers() is a "table function": it generates rows
--  A table function goes after FROM like a table, but it computes
--  its rows on the fly. numbers(10) returns the integers 0 to 9.
--  We use it to simulate millions of rows without storing anything.
SELECT number
FROM numbers(10);
-- Measured: 1 ms · 10 rows read


-- STEP 2 · Apply functions to each row
--  cityHash64 always returns the same result for the same input: it is
--  a reproducible "random", identical for every participant.
--  randCanonical, on the other hand, changes on every run.
SELECT
    number,
    toDate('2026-10-01') + number              AS day,
    cityHash64(number) % 100                   AS deterministic_random,
    round(80000 + 60000 * randCanonical(), 2)  AS energy_wh
FROM numbers(10);
-- Measured: 2 ms · 10 rows read


-- STEP 3 · A realistic 14-digit meter identifier
--  A meter ID fits in a UInt64 (8 bytes). leftPad turns it back into the
--  14-digit text format used in the distribution system operator's files.
SELECT leftPad(toString(10000000000000 + number * 4093 + cityHash64(number) % 4093), 14, '0') AS meterId
FROM numbers(5);
-- Measured: 2 ms · 5 rows read


-- STEP 4 · A daily energy measurement: a named tuple becomes a JSON object
--  tuple(value AS name, ...) builds a structure; toJSONString turns it
--  into a JSON object whose keys are the names. An array [...] becomes a
--  JSON list. The enable_named_columns_in_function_tuple setting keeps the names.
SELECT toJSONString(tuple(
    leftPad(toString(10000000000000 + 4093), 14, '0')  AS meterId,
    'RAW'                                              AS stage,
    tuple('2026-10-01' AS startDate, '2026-10-02' AS endDate) AS period,
    'GLOBAL'                                           AS valueType,
    'DIFF.INDEX'                                        AS calcMode,
    'P1D'                                               AS step,
    [tuple('EA' AS physicalQuantity, 'CONS' AS businessQuantity, 'Wh' AS unit,
           [tuple('2026-10-01' AS d, '190205.98' AS v)] AS points)] AS quantity
)) AS measurement_json
SETTINGS enable_named_columns_in_function_tuple = 1;
-- Measured: 2 ms · 1 row read


-- STEP 5 · A complete file: one header + 1000 measurements
--  arrayMap(i -> ..., range(1000)) acts as a loop: it applies
--  the function to each element of the array 0..999 and returns the array
--  of results. A single result row = a whole file.
SELECT toJSONString(tuple(
    tuple('DATA PORTAL' AS requester, 'LOCAL_AUTHORITY' AS recipientType,
          '488903' AS recipientId, 'ENERGYD' AS flowCode, 'RECURRING' AS publicationMode,
          'JSON' AS format) AS header,
    arrayMap(i -> tuple(
        leftPad(toString(10000000000000 + i * 4093 + cityHash64(i) % 4093), 14, '0') AS meterId,
        'RAW' AS stage,
        tuple('2026-10-01' AS startDate, '2026-10-02' AS endDate) AS period,
        'P1D' AS step,
        [tuple('EA' AS physicalQuantity, 'CONS' AS businessQuantity, 'Wh' AS unit,
               [tuple('2026-10-01' AS d, toString(round(80000 + 60000 * (cityHash64(i) % 1000) / 1000, 2)) AS v)] AS points)] AS quantity
    ), range(1000)) AS measurements
)) AS daily_energy_file
SETTINGS enable_named_columns_in_function_tuple = 1;
-- Measured: 4 ms · 1 row read
-- What to look for: paste the result into a JSON viewer. You get exactly
-- the structure of the source format: header, then measurements > quantity > points.


-- STEP 6 · The teaser: 1 MILLION JSON measurements. How long does it take?
--  Each row builds and serializes a small JSON object. ClickHouse
--  splits numbers() into blocks and processes them on all cores in parallel.
SELECT
    count()                                   AS n_measurements,
    formatReadableSize(sum(length(json)))     AS json_volume
FROM
(
    SELECT toJSONString(tuple(
        leftPad(toString(10000000000000 + number * 4093 + cityHash64(number) % 4093), 14, '0') AS meterId,
        'RAW' AS stage,
        toString(round(80000 + 60000 * (cityHash64(number) % 1000) / 1000, 2)) AS v
    )) AS json
    FROM numbers(1000000)
)
SETTINGS enable_named_columns_in_function_tuple = 1;
-- Measured: 232 ms · 1 M rows read (7.6 MB)
-- What to look for: the duration at the bottom of the console. Replace 1000000 with 10000000:
-- the time is roughly multiplied by 10, the speed in rows/s stays stable.
