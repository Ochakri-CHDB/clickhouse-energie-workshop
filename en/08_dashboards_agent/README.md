# Module 8 · Dashboards, API and ClickHouse Agents

Gold is ready: small tables, sorted by the filters, refreshed every 10 minutes. We expose them in three ways, all from the Cloud console:

| For whom | What | Where |
|---|---|---|
| The operator, the project manager | A 5-tile dashboard, filterable by local authority and by day | this README, part 1 |
| A local authority's portal | An HTTPS API with no SQL on the client side | part 2 |
| Everyone | An agent that answers in English, builds dashboards and does data science | part 3 |

Duration: 1 h. Everything happens in the Cloud console, following the steps below: there is no SQL file to run in this module. Prerequisite: modules 00 to 07 have run on your service.

> The labels below are those of the ClickHouse Cloud console in October 2026. Dashboards and ClickHouse Agents are in **beta**: a label may have moved, the principle stays the same.

---

## 1. The "Energy · Metro areas" dashboard (20 min)

5 tiles, all filterable from the moment they are created:

| # | Tile | Type | Filters |
|---|---|---|---|
| 1 | Load curve, consumption and production | Line | authority, day |
| 2 | Monthly heatmap, day × hour | Heatmap | authority |
| 3 | Energy per day | Stacked bar | authority |
| 4 | Top 10 municipalities | Horizontal bar | authority |
| 5 | Power overrun alerts | Table | authority |

The filters take human-readable values:
- **authority**: part of the name, case does not matter. `Paris`, `Lyon`, `Lille`, `Toulouse`, `Bordeaux` or `Nantes`.
- **day**: a date in October 2026 in YYYY-MM-DD format, for example `2026-10-15`.

Since all 5 tiles use the **same parameter names**, a single filter drives the whole dashboard.

### Step 1 · Create the dashboard
1. In the service sidebar, click **Dashboards**.
2. Click **+ New Dashboard**.
3. Name it `Energy · Metro areas`. The empty dashboard opens.

### Step 2 · Add a tile (repeat 5 times)
1. Top right, click **+ New visualization**. An empty tile appears and the **Edit element** panel opens on the right.
2. **General** tab, **Query** field: choose **New query**. The **Inline Editor** opens.
3. Paste the tile's query (cards below).
4. To the right of the editor, the **Query Parameters** panel shows the detected parameters. Enter the test values: `authority` = `Paris`, and for tile 1 `day` = `2026-10-15`.
5. Run with the ▷ button, check the result, then save with the **floppy disk** icon, under the tile's name.
6. **Visualization type**: choose the type given on the card.
7. **Data** tab: map the columns to the axes as given on the card.
8. Give the tile a title and close the panel (×). Resize the tile from its bottom right corner, move it with the handle at the top left.

### The 5 cards

#### Tile 1 · Load curve of the day
Type **Line**. X axis: `hour`. Y series: `cons_mw`, `prod_mw`.
```sql
SELECT
    toTimeZone(ts, 'Europe/Paris')                          AS hour,
    round(sumIf(power_kw, quantity = 'CONS') / 1000, 2) AS cons_mw,
    round(sumIf(power_kw, quantity = 'PROD') / 1000, 2) AS prod_mw
FROM gold.epci_curve
WHERE epci_code IN (SELECT epci_code FROM ref.recipient
                    WHERE positionCaseInsensitiveUTF8(name, {authority:String}) > 0)
  AND ts >  toDateTime({day:Date}, 'Europe/Paris')
  AND ts <= toDateTime({day:Date} + 1, 'Europe/Paris')
GROUP BY hour
ORDER BY hour
```
What to look for: the evening peak around 7pm (21.9 MW for Paris on the 15th), and the solar bump at noon, far below.

#### Tile 2 · Monthly heatmap
Type **Heatmap**. X axis: `hour`. Y axis: `day`. Value: `cons_mw`.
```sql
SELECT
    toDate(ts - 1, 'Europe/Paris')        AS day,
    toHour(ts - 900, 'Europe/Paris')      AS hour,
    round(avg(power_kw) / 1000, 2)    AS cons_mw
FROM gold.epci_curve
WHERE epci_code IN (SELECT epci_code FROM ref.recipient
                    WHERE positionCaseInsensitiveUTF8(name, {authority:String}) > 0)
  AND quantity = 'CONS'
GROUP BY day, hour
ORDER BY day, hour
```
What to look for: 31 rows × 24 columns. The evening peak forms a band every day, weekends are quieter during the day, and everything gets darker at the end of the month (heating kicks in). This is the most telling tile of the dashboard.

#### Tile 3 · Energy per day
Type **Stacked bar**. X axis: `day`. Y series: `cons_mwh`, `prod_mwh`.
```sql
SELECT
    day,
    round(cons_kwh / 1000, 1) AS cons_mwh,
    round(prod_kwh / 1000, 1)  AS prod_mwh
FROM gold.authority_day_summary
WHERE positionCaseInsensitiveUTF8(authority, {authority:String}) > 0
ORDER BY day
```
What to look for: the weekend dips, and the trend that rises through October.

#### Tile 4 · Top 10 municipalities
Type **Horizontal bar**. Category: `municipality`. Value: `cons_mwh`.
```sql
SELECT
    dictGet('ref.dict_municipality', 'name', insee_code) AS municipality,
    round(sum(energy_kwh) / 1000, 1)              AS cons_mwh
FROM gold.municipality_day_energy
WHERE epci_code IN (SELECT epci_code FROM ref.recipient
                    WHERE positionCaseInsensitiveUTF8(name, {authority:String}) > 0)
  AND quantity = 'CONS'
GROUP BY insee_code
ORDER BY cons_mwh DESC
LIMIT 10
```
What to look for: the central city on top, then municipalities that host an industrial site (C2). The name comes from a dictionary, with no JOIN.

#### Tile 5 · Power overrun alerts
Type **Table**. All columns.
```sql
SELECT
    day,
    municipality,
    segment,
    subscribed_kva,
    round(pmax_va / 1000, 1) AS pmax_kva,
    overrun_pct
FROM gold.pmax_alerts
WHERE epci_code IN (SELECT epci_code FROM ref.recipient
                    WHERE positionCaseInsensitiveUTF8(name, {authority:String}) > 0)
ORDER BY day DESC, overrun_pct DESC
```
What to look for: only C4 and C2 sites (in C5, the meter's circuit breaker trips before any overrun). 140 alerts in October for Grand Paris, 33 for Lyon.

### Step 3 · Wire up the filters
1. Reopen each tile: **three dots** (⋮) top right, then **Edit**.
2. In the visualization settings, each query parameter (`authority`, `day`) shows up with its **value source**. Choose **filter**.
3. Do this on all 5 tiles.
4. Click the **funnel** in the top bar: the **Global filters** panel opens, with an `authority` field and a `day` field.

### Step 4 · Play with the dashboard
1. In **Global filters**, type `Paris` and `2026-10-15`: the 5 tiles show Grand Paris.
2. Replace with `Lyon`, then `Toulouse`: the whole dashboard switches.
3. Change the date (`2026-10-25`, the day the clocks go back: 50 half-hours): only the curve in tile 1 changes.

Every change reruns the 5 queries. Each one answers in a few milliseconds: behind the typed name, it finds the territory code in `ref.recipient`, then filters gold on the start of its sorting key (`epci_code`).

Sharing: **Share** button at the top. A colleague also needs access to the underlying **saved queries**.

Measured on the test service (3 × 64 GB), filter `Paris`: 6 to 28 ms per tile.

---

## 2. The Query API endpoint for the portal (15 min)

The portal only sends parameters (a local authority, two dates). The SQL stays in ClickHouse. We turn a saved query into an HTTPS address that can be called with an API key.

Legend: **[tested]** verified on a real service and endpoint, **[console]** to be done in the UI.

### Step 1 · Create the two API views [tested]
A **parameterized view** is a query stored in the database, with `{name:Type}` parameters. You call it like a table: `SELECT * FROM gold.api_authority_curve(recipient_id = '488903', …)`. The portal will only ever see these parameters.

Prerequisite: modules 00 to 07 have run on **this same service** (the views read the gold tables).

In the SQL console, paste this block and run it all (Cmd+Enter):
```sql
-- The load curve of a local authority, between two dates
CREATE OR REPLACE VIEW gold.api_authority_curve AS
SELECT
    toTimeZone(ts, 'Europe/Paris')   AS hour,
    quantity,
    round(power_kw, 1)           AS power_kw,
    n_meters
FROM gold.epci_curve
WHERE epci_code IN (SELECT epci_code FROM ref.recipient WHERE recipient_id = {recipient_id:String})
  AND ts >  toDateTime({start:Date}, 'Europe/Paris')
  AND ts <= toDateTime({finish:Date} + 1, 'Europe/Paris')
ORDER BY quantity, ts;

-- The day-by-day summary of a local authority
CREATE OR REPLACE VIEW gold.api_authority_summary AS
SELECT
    day,
    authority,
    round(cons_kwh / 1000, 2)        AS cons_mwh,
    round(prod_kwh / 1000, 2)         AS prod_mwh,
    round(100 * coverage_rate, 2)   AS coverage_pct,
    n_meters
FROM gold.authority_day_summary
WHERE recipient_id = {recipient_id:String}
  AND day BETWEEN {start:Date} AND {finish:Date}
ORDER BY day;

-- The module 7 role must be able to read the small reference table used by the view
GRANT SELECT ON ref.recipient TO role_grand_paris;
```
If the console opens a **Query Variables** panel, leave it empty: the parameters are only used when calling the view.

Check:
```sql
SELECT name FROM system.tables WHERE database = 'gold' AND name LIKE 'api_%';
```
Expected: `api_authority_curve` and `api_authority_summary`.

If you later see `Unknown table function gold.api_authority_curve (UNKNOWN_FUNCTION)`, the view does not exist on the service you are on: redo this step on that service.

### Step 2 · Get the values to pass [tested]
The identifier of each local authority:
```sql
SELECT recipient_id, name FROM ref.recipient ORDER BY recipient_id;
```
| recipient_id | name |
|---|---|
| 488903 | Métropole du Grand Paris |
| 488904 | Métropole de Lyon |
| 488905 | Métropole Européenne de Lille |
| 488906 | Toulouse Métropole |
| 488907 | Bordeaux Métropole |
| 488908 | Nantes Métropole |

The available dates:
```sql
SELECT min(day) AS first_day, max(day) AS last_day FROM gold.authority_day_summary;
```
Expected: from `2026-10-01` to `2026-10-31`.

### Step 3 · Write and test the endpoint query [tested]
1. New tab in the SQL console. Paste:
   ```sql
   SELECT *
   FROM gold.api_authority_curve(
       recipient_id = {recipient_id:String},
       start        = {start:Date},
       finish       = {finish:Date})
   ```
2. The **Query Variables** panel opens on the right with three fields. Enter `488903`, `2026-10-15`, `2026-10-15`.
3. Run (Cmd+Enter). Expected: **96 rows** (48 half-hours × CONS and PROD), peak at ~21.9 MW around 7pm.
4. Click **Save** and name the query `api_authority_curve`.

### Step 4 · Create the API key [tested]
1. In the organization's left menu, open **API Keys**, then click **New API Key**.
2. Name: `authority-portal`. Organization role: **Member**. Service access: **Query Endpoints** on your service. Pick an expiry date.
3. Optional: in **Allow access to this API Key**, restrict to the portal's IP addresses.
4. Click **Generate API Key**. The next screen shows the **Key ID** and the **Key secret**: copy them right away into a password vault. They will never be shown again.

### Step 5 · Create the endpoint [tested]
1. Reopen the saved query `api_authority_curve`.
2. Click **Share**, then **API Endpoint**.
3. Choose the API key from step 4.
4. Choose the **database role** that will run the query: **Read only**, or the `role_grand_paris` role from module 7 so that the endpoint only sees Grand Paris.
5. **CORS**: the portal's domain (leave empty for a command-line test).
6. Confirm. The console shows the **call address**, in the form `https://queries.clickhouse.cloud/run/<identifier>`. Copy it.

### Step 6 · Call the endpoint [tested]
In a terminal, put the values in variables (never in a versioned file):
```bash
export KEY_ID='<Key ID from step 4>'
export KEY_SECRET='<Key secret from step 4>'
export ENDPOINT='https://queries.clickhouse.cloud/run/<identifier from step 5>'
```
GET call, parameters in the address:
```bash
curl -s --user "$KEY_ID:$KEY_SECRET" \
  "$ENDPOINT?format=JSONEachRow&param_recipient_id=488903&param_start=2026-10-15&param_finish=2026-10-15"
```
POST call, parameters in the body:
```bash
curl -s --user "$KEY_ID:$KEY_SECRET" -X POST -H "Content-Type: application/json" \
  "$ENDPOINT?format=JSONEachRow" \
  -d '{"queryVariables": {"recipient_id": "488903", "start": "2026-10-15", "finish": "2026-10-15"}}'
```

Results obtained on a real endpoint:

| Call | Result |
|---|---|
| GET or POST, Grand Paris (`488903`), October 15 | HTTP 200, **96 rows** (48 half-hours × CONS and PROD), ~1 s |
| GET, Grand Paris, October 13 to 19 | HTTP 200, **672 rows** (7 days × 96) |
| GET or POST, Lyon (`488904`), endpoint created with the `role_grand_paris` role | HTTP 200, **0 rows**: the row policy hides everything that is not Grand Paris |

Pitfalls we hit:
- **`401 Unauthorized`** (and `Key is not found` on the Cloud API): the key was not copied correctly. The Key secret starts with `4b1d`: check that this prefix did not get lost in the copy-paste. To test the key alone: `curl --user "$KEY_ID:$KEY_SECRET" https://api.clickhouse.cloud/v1/organizations` should return your organization.
- **No space or extra character in the address**: `param_recipient_id=488903`, not `param_recipient_id= 488903`; `param_finish=2026-10-15`, not `param_finish=<2026-10-15`. The `<…>` in the examples must be replaced entirely.
- `404`: the endpoint identifier is wrong. `400`: a parameter is malformed (date in YYYY-MM-DD format).

### Step 7 · See the calls on the server side [tested]
Each endpoint runs under a dedicated user named `queryEndpoint:<identifier>`:
```sql
SYSTEM FLUSH LOGS;
SELECT event_time, user, round(query_duration_ms) AS ms, read_rows
FROM clusterAllReplicas('default', system.query_log)
WHERE type = 'QueryFinish' AND user LIKE 'queryEndpoint:%' AND event_date = today()
ORDER BY event_time DESC
LIMIT 10;
```
What to look for: a few milliseconds and ~8,200 rows read per call.

### Plan B · Test without an API key, over direct HTTPS [tested]
To check the query before you have a key, the service's HTTPS interface accepts the same parameters (`param_<name>`). This is a test: never put the `default` password in a portal.
```bash
curl --user "default:$CH_PASSWORD" \
  "https://$CH_HOST:8443/?param_recipient_id=488903&param_start=2026-10-15&param_finish=2026-10-15&default_format=JSONEachRow" \
  --data-binary "SELECT * FROM gold.api_authority_curve(recipient_id = {recipient_id:String}, start = {start:Date}, finish = {finish:Date}) LIMIT 3"
```

Measured (same query, native client and direct HTTPS): 3 to 30 ms, ~8,200 rows read for one day of curve.

---

## 3. ClickHouse Agents (35 min)

An agent does not guess the business: it reads the schema. So we document gold, create the agent with the right tools, ask it 2 questions to get a feel for it, then have it build 6 dashboards and give it 3 data science exercises.

### Step 1 · Document gold for the agent [tested]
An agent starts by reading the tables, their columns and their **comments** (rule `agent-discovery-schema`). Without comments, it guesses that `ts` is in local time or that `488903` is a postal code. These commands only touch metadata: instant, no data rewritten.

In the SQL console, paste this block and run it all (Cmd+Enter):
```sql
ALTER TABLE gold.authority_day_summary
    MODIFY COMMENT 'Daily summary per local authority receiving the metering flows (6 metro areas). One row per authority and per day of October 2026. Energy in kWh.';
ALTER TABLE gold.authority_day_summary
    COMMENT COLUMN recipient_id 'Recipient identifier (488903 = Métropole du Grand Paris, see ref.recipient)',
    COMMENT COLUMN day            'Local day (Europe/Paris)',
    COMMENT COLUMN cons_kwh       'Energy consumed on the territory that day, in kWh',
    COMMENT COLUMN prod_kwh        'Energy produced (solar PV) on the territory that day, in kWh',
    COMMENT COLUMN coverage_rate 'prod_kwh / cons_kwh, between 0 and 1',
    COMMENT COLUMN n_meters          'Number of meters that sent a curve that day';

ALTER TABLE gold.epci_curve
    MODIFY COMMENT 'Load curve aggregated per EPCI, 30 min step. ts = END of the interval, in UTC: convert with toTimeZone(ts, ''Europe/Paris''). Filter on epci_code then ts (sorting key).';
ALTER TABLE gold.epci_curve
    COMMENT COLUMN epci_code    'SIREN code of the EPCI (200054781 = Métropole du Grand Paris). Label: dictGet(''ref.dict_epci'', ''name'', epci_code)',
    COMMENT COLUMN quantity     'CONS = consumption, PROD = production',
    COMMENT COLUMN ts           'End of the 30 min interval, UTC',
    COMMENT COLUMN power_kw 'Average power over the interval, sum of the meters, in kW',
    COMMENT COLUMN n_meters       'Number of points (meters) aggregated';

ALTER TABLE gold.municipality_day_energy
    MODIFY COMMENT 'Energy per municipality, day, segment (C5, C4, C2) and quantity (CONS, PROD). Municipality label: dictGet(''ref.dict_municipality'', ''name'', insee_code).';
ALTER TABLE gold.municipality_day_energy
    COMMENT COLUMN segment     'C5 = households and small businesses (≤ 36 kVA), C4 = SMEs/commercial (36 to 250 kVA), C2 = HV-connected industrial sites',
    COMMENT COLUMN energy_kwh 'Energy of the day in kWh',
    COMMENT COLUMN n_meters      'Meters of this segment in the municipality that day (add up the segments for the total)';

ALTER TABLE gold.pmax_alerts
    MODIFY COMMENT 'Subscribed power overruns (PMAX flow). One row per meter and per day in overrun. Only C4 and C2 can overrun (in C5 the circuit breaker trips).';
ALTER TABLE gold.pmax_alerts
    COMMENT COLUMN subscribed_kva    'Subscribed power IN FORCE on that day, in kVA',
    COMMENT COLUMN pmax_va         'Maximum power reached during the day, in VA',
    COMMENT COLUMN overrun_pct 'Overrun as a % of the subscribed power',
    COMMENT COLUMN peak_time    'Time of the peak, Paris time';

ALTER TABLE gold.daily_completeness_kpi
    MODIFY COMMENT 'Completeness of the CURVE load curve collection at 9am the next day. Target: data_by_9am_pct >= 99.';
ALTER TABLE gold.daily_completeness_kpi
    COMMENT COLUMN data_by_9am_pct      'Points received before 9am / expected points, in %. This is the contractual KPI',
    COMMENT COLUMN complete_meters_9am_pct 'Share of meters whose day is complete at 9am, in %';
```

Check:
```sql
SELECT name, comment FROM system.tables WHERE database = 'gold' AND comment != '' ORDER BY name;
```
Expected: 6 commented tables (`pmax_alerts`, `epci_curve`, `municipality_day_energy`, `daily_completeness_kpi`, `meter_profile`, `authority_day_summary`). `meter_profile` is commented as soon as it is created in module 05.

### Step 2 · Create and configure the agent [console]
1. In the service sidebar, click **ClickHouse agents**, then **Launch ClickHouse agents**.
2. Click **+ Create New Agent** and fill in:

| Field | Value |
|---|---|
| Name | `Energy Assistant` |
| Description | `Answers business questions and builds dashboards on the October collection (gold database).` |
| **Model** | a **Claude Sonnet** model from the list (the default one is fine). You need a model that can call tools and produce artifacts |
| Category | `General` |
| Instructions | **Inline** tab, paste the text below |
| **Tools** | **+ Add**, then add all three: **ClickHouse** (connected to your service, 9 tools: list tables, run SQL…), **Artifacts** (to build the dashboards), **Run Code** (calculations and charts in Python) |
| Skills | **All** |
| Conversation starters | add requests D1, D2 and D3 from step 5 below: they will show up as buttons when a conversation starts |
| File context, Support contact | optional |

Without the **ClickHouse** tool, the agent cannot see your data. Without **Artifacts**, it answers in text but does not build a dashboard.

Instructions to paste (a single block, up to date):
```
You are the data assistant of an electricity distribution system operator. You answer
business questions in English about the collection of metering data for October 2026.
- Use ONLY the tables of the gold database and ref.recipient, through the ClickHouse tool.
  First read the comments of the tables and columns, and their sorting key.
- Always filter on the start of the sorting key and add a LIMIT.
- ts is in UTC and marks the END of a half-hour: convert with toTimeZone(ts, 'Europe/Paris').
- Municipality and EPCI names are read with dictGet('ref.dict_municipality', 'name', insee_code)
  and dictGet('ref.dict_epci', 'name', epci_code).
- When asked for a dashboard, a page or a report: query ClickHouse first,
  then build an interactive artifact with the REAL values you got (never made-up
  data), titles in English, units (MW, MWh, %) and 2 or 3 sentences of analysis.
- Otherwise, give the key figures with their unit, then the SQL query you used.

Data science with the Run Code tool:
- You always run the Python code yourself in the Run Code tool. Never suggest a
  script to run, never use clickhouse_connect or any database connection.
- Method, always the same:
  1. one query with the ClickHouse tool that returns fewer than 100 rows (aggregate or
     sample in ClickHouse);
  2. copy the result as is into your Python code;
  3. run the code in Run Code and show the figures and a chart.
- Curve of a territory: one row per day, with the 48 half-hours in an array:
  SELECT day, toDayOfWeek(day) >= 6 AS is_weekend,
         arrayMap(x -> x.2, arraySort(groupArray((half_hour, mw)))) AS cons_mw
  FROM (SELECT toDate(ts - 1800, 'Europe/Paris') AS day,
               toHour(ts - 1800, 'Europe/Paris') * 2 + intDiv(toMinute(ts - 1800, 'Europe/Paris'), 30) AS half_hour,
               round(avg(power_kw) / 1000, 2) AS mw
        FROM gold.epci_curve
        WHERE epci_code = '<EPCI code>' AND quantity = 'CONS'
        GROUP BY day, half_hour)
  GROUP BY day ORDER BY day
- Meter shapes (30 per segment C5, C4, C2):
  SELECT segment, profile, arrayMap(x -> round(x, 2), weekday_shape) AS weekday,
         arrayMap(x -> round(x, 2), weekend_shape) AS weekend
  FROM gold.meter_profile ORDER BY cityHash64(meter_id) LIMIT 30 BY segment
  If gold.meter_profile does not exist, say so in one sentence: it is created with the
  workshop file 05_gold/04_meter_shapes.sql. Do not use silver instead.
- Forecast: HistGradientBoostingRegressor(max_iter=300, learning_rate=0.05, random_state=0)
  with half_hour, is_weekend and day of month. Always compare its error (MAPE) with two naive
  methods aligned by half-hour: the previous day, and the same weekday of the previous week.
- Segmentation: KMeans(n_clusters=3, n_init=10, random_state=0) on the 48 shape values
  (weekday then weekend), then cross the clusters with the segment AND the profile.
- Profiling: split 70% / 30% (stratified by segment), typical shape = center of the
  KMeans cluster learned on the 70%, mean error in % per segment on the 30%, compared with a
  flat curve.
- Always present the result in an artifact: the charts, a table of the key figures
  (errors, cluster sizes) and 3 to 5 sentences of analysis in English, without jargon.
```

### Step 3 · Open a conversation [console]
1. Save the agent.
2. At the top of the page, choose `Energy Assistant` from the list, then click **Select**.
3. A conversation opens. The conversation starters appear as buttons.

### Step 4 · Ask 2 questions to get a feel for it
Two questions are enough to see how the agent works: it reads the comments, writes the SQL, filters on the sorting key. The interesting part comes next, with the dashboards and the data science.

Copy each question as is into the conversation and compare the answer with the expected result. The check query (expand it) gives the real figure.

**Q1** · "How much did the Métropole du Grand Paris consume in October, and what share was covered by local solar production?"

Expected: ~10,850 MWh consumed, ~450 MWh produced, coverage ~4.1%.

<details><summary>Check query</summary>

```sql
SELECT round(sum(cons_kwh) / 1000) AS cons_mwh,
       round(sum(prod_kwh) / 1000)  AS prod_mwh,
       round(100 * sum(prod_kwh) / sum(cons_kwh), 1) AS coverage_pct
FROM gold.authority_day_summary
WHERE recipient_id = '488903';
```
</details>

**Q2** · "At what time was Grand Paris's consumption peak on October 15, and how many MW?"

Expected: 7:00pm (Paris time), ~21.9 MW. The trap: ts is in UTC and marks the END of the half-hour.

<details><summary>Check query</summary>

```sql
SELECT toTimeZone(ts, 'Europe/Paris') AS hour, round(power_kw / 1000, 2) AS mw
FROM gold.epci_curve
WHERE epci_code = '200054781' AND quantity = 'CONS'
  AND ts > toDateTime('2026-10-15', 'Europe/Paris') AND ts <= toDateTime('2026-10-16', 'Europe/Paris')
ORDER BY power_kw DESC
LIMIT 1;
```
</details>

### Step 5 · Have it build dashboards (the highlight)
With the **ClickHouse** and **Artifacts** tools, the agent no longer just answers: it queries gold, then builds an interactive page with charts and key figures, in a few tens of seconds.

For each request:
1. Paste it into the conversation (or click the conversation starter).
2. Watch the queries the agent runs: it should read the comments, then filter on `epci_code` or `recipient_id`.
3. Compare the figures on the page with the expected result.
4. Ask for a tweak in the same conversation: "add a filter by metro area", "switch the curve to stacked areas", "export to PDF".

Start with **D2** (the heatmap) then **D1** (the full dashboard): they are the most visual.

A good page: real data (never made up), units (MW, MWh, %), titles in English, and a few lines of analysis under the charts.

**D1** · "Build an interactive dashboard for the Métropole du Grand Paris for October 2026: the load curve of October 15 (consumption and production), energy day by day, the top 10 municipalities, the 9am completeness KPI and the alerts of the last day. Add 3 key figures at the top of the page."

Expected: 5 charts and 3 key figures (~10,846 MWh, ~4.1% coverage, 98.4% average KPI). For the most part, these are the tile queries from this folder's README.

<details><summary>Check query</summary>

```sql
SELECT round(sum(cons_kwh) / 1000) AS cons_mwh, round(100 * sum(prod_kwh) / sum(cons_kwh), 1) AS coverage_pct
FROM gold.authority_day_summary
WHERE recipient_id = '488903';
```
</details>

**D2** · "Make a day × hour heatmap of Grand Paris's consumption in October, then explain in 3 sentences what it shows."

Expected: 31 rows × 24 columns, from ~8 to ~23 MW. The analysis should mention the evening peak (7pm to 8pm), the quieter weekend daytimes, and the rise at the end of the month.

<details><summary>Check query</summary>

```sql
SELECT toDate(ts - 1, 'Europe/Paris') AS day, toHour(ts - 900, 'Europe/Paris') AS hour,
       round(avg(power_kw) / 1000, 2) AS cons_mw
FROM gold.epci_curve
WHERE epci_code = '200054781' AND quantity = 'CONS'
GROUP BY day, hour
ORDER BY day, hour;
```
</details>

**D3** · "Compare the 6 metro areas on a single page: consumption, solar production, coverage rate and number of alerts for the month. Highlight the sunniest one."

Expected: a ranked table and a chart. Toulouse and Nantes on top (~5.3% coverage), Grand Paris by far the biggest consumer (~10,846 MWh) and the most alerts (140 of the month's 257).

<details><summary>Check query</summary>

```sql
SELECT s.authority,
       round(sum(s.cons_kwh) / 1000)                    AS cons_mwh,
       round(sum(s.prod_kwh) / 1000)                     AS prod_mwh,
       round(100 * sum(s.prod_kwh) / sum(s.cons_kwh), 1) AS coverage_pct,
       any(a.alerts)                                    AS alerts
FROM gold.authority_day_summary AS s
INNER JOIN ref.recipient AS d ON d.recipient_id = s.recipient_id
LEFT JOIN (SELECT epci_code, count() AS alerts FROM gold.pmax_alerts GROUP BY epci_code) AS a ON a.epci_code = d.epci_code
GROUP BY s.authority
ORDER BY coverage_pct DESC;
```
</details>

**D4** · "Prepare the October 30 operations report for the team lead: completeness at 9am, files that arrived late this month, overrun alerts of the day, and 3 recommendations. Lay it out as a printable page."

Expected: the KPI for the 30th above 99%, the 6 days below target with their late files (arrived at 2pm), 6 C4 alerts on the 30th, and concrete recommendations (chase the late batches, contact the sites that overrun).

<details><summary>Check query</summary>

```sql
SELECT day, data_by_9am_pct FROM gold.daily_completeness_kpi WHERE data_by_9am_pct < 99 OR day = '2026-10-30' ORDER BY day;
```
</details>

**D5** · "Which sites regularly exceed their subscribed power? Show them on a chart (average overrun and number of days) and say which ones should increase their power."

Expected: about twenty sites, almost all C4, with 3 or 4 overrun days (Lyon, Vanves, Saint-Maurice and Paris on top with 4 days). A good answer: the agent points out that in C5 the circuit breaker trips before any overrun.

<details><summary>Check query</summary>

```sql
SELECT meter_id, any(municipality) AS municipality, any(segment) AS segment, count() AS overrun_days,
       round(avg(overrun_pct), 1) AS avg_overrun_pct, max(subscribed_kva) AS subscribed_kva
FROM gold.pmax_alerts
GROUP BY meter_id
HAVING overrun_days >= 2
ORDER BY overrun_days DESC, avg_overrun_pct DESC
LIMIT 20;
```
</details>

**D6** · "Make a page for a Lyon elected official: 4 key figures for the month, the curve of a typical weekday and of a weekend day, all readable by a non-specialist."

Expected: figures for the Métropole de Lyon (~2,140 MWh, ~3.4% solar), two curves compared (the weekend lower during the day), and a jargon-free text.

<details><summary>Check query</summary>

```sql
SELECT if(toDayOfWeek(toDate(ts - 1, 'Europe/Paris')) >= 6, 'weekend', 'weekday') AS day_type,
       toHour(ts - 900, 'Europe/Paris') AS hour,
       round(avg(power_kw) / 1000, 2) AS cons_mw
FROM gold.epci_curve
WHERE epci_code = '200046977' AND quantity = 'CONS'
GROUP BY day_type, hour
ORDER BY day_type, hour;
```
</details>

### Step 6 · Data science: forecast and rebuild curves with Run Code
The **Run Code** tool gives the agent real Python (pandas, scikit-learn) in a sandbox. The split of roles is the right data scientist reflex on ClickHouse:
- **ClickHouse prepares the data**: aggregates, consumption shapes, samples. It is fast and it cuts the volume;
- **Python trains the model** on only a few hundred or a few thousand rows.

First check that the **Run Code** tool is in the agent's tool list (step 2).

**6.1 · Check that the consumption shapes are in gold [tested]**
Examples 2 and 3 use the `gold.meter_profile` table: each meter is summarized by its average shape, 24 values on weekdays and 24 at weekends, divided by its average consumption. It is created in module 05 by `05_gold/04_meter_shapes.sql`. Check in the SQL console:
```sql
SELECT segment, profile, count() AS meters FROM gold.meter_profile GROUP BY segment, profile ORDER BY segment, profile;
```
Expected: C2 ENT 40, C4 PRO ~230, C5 PRO ~2,360, C5 RES ~17,370.

If you see `Table gold.meter_profile does not exist`, open `05_gold/04_meter_shapes.sql`, paste it into the console and run it all (Cmd+Enter): under a second. Without this table, the agent will tell you it cannot do examples 2 and 3. That is the right behavior: it must not make up data.

**6.2 · The data science instructions [console]**
Run Code runs Python in a sandbox that does not have your ClickHouse credentials. Without instructions, the agent writes a script with `clickhouse_connect` and asks you to run it yourself. So the method is given once and for all, in the "Data science with the Run Code tool" part of its instructions (step 2): a compact query with the ClickHouse tool, data pasted into the code, execution in Run Code, result in an artifact.

If you created the agent before adding that part, copy the full block from step 2 again, save, then open a **new** conversation.

**6.3 · The three requests**
One sentence is enough: the method is in the instructions.

| | Request to paste | Expected result |
|---|---|---|
| **ML1 · Forecast** | "Forecast the Grand Paris load curve for Saturday October 31 from October 1 to 30, and compare it with reality." | model **~2.3%** error, previous Saturday ~3.3%, previous day ~47%. Actual peak at 7:30pm, 22.0 MW |
| **ML2 · Segmentation** | "Group the meters into 3 clusters based on the shape of their consumption, cross these clusters with the C5, C4 and C2 segments, and show me each cluster." | 90 meters (30 per segment). 3 clusters: **households** (25 residential C5, evening peak), **businesses** (the 30 C4 and 5 small C5 businesses, plateau from 8am to 7pm), **industry** (the 30 C2, high base load, active at weekends) |
| **ML3 · Profiling** | "Show me that we can rebuild a meter's curve from its energy alone, using the typical shape of its cluster." | **~2.3%** error with the typical shape, in every segment, versus ~46% with a flat curve |

Each result is shown in an artifact: charts, a table of key figures and a few sentences of analysis.

The expected results come from running these same calculations in Python (scikit-learn 1.9) on the service's data. The agent may find slightly different figures: the order of magnitude is what counts.

Takeaway for ML1: the model beats both naive methods because it knows that tomorrow is a Saturday, and it follows the end-of-month rise. With the default `GradientBoostingRegressor`, you get ~8%, worse than the previous Saturday: the choice of model matters, hence the instruction.

Takeaway for ML2: the business cluster mixes C4 sites and small C5 businesses. The consumption shape depends on usage, not on subscribed power.

Takeaway for ML3: this is the principle of **profiling**. For a meter without a load curve, you multiply its energy (read from the index) by the typical shape of its cluster.

**If the agent still does not run the code**: reply "run it yourself with Run Code, pasting the data into the code". Also check that the conversation was opened after the instructions were saved.

These results are clean because the data is simulated. On real data, weather, holidays and individual behavior increase the errors. The method stays the same.

### Step 7 · In production: a dedicated role for the agent
During the workshop, the agent runs with your privileges. In production, give it a read-only role on gold, with limits on each query (rule `agent-query-safety`). To adapt, not run during the workshop:
```sql
CREATE SETTINGS PROFILE IF NOT EXISTS agent_profile SETTINGS
    readonly = 2, max_execution_time = 30, max_rows_to_read = 1000000000,
    max_result_rows = 10000, result_overflow_mode = 'break';
CREATE ROLE IF NOT EXISTS agent_role SETTINGS PROFILE 'agent_profile';
GRANT SELECT ON gold.* TO agent_role;
GRANT SELECT ON ref.* TO agent_role;
GRANT dictGet ON ref.* TO agent_role;
```
`readonly = 2` forbids any write, `max_rows_to_read` and `max_execution_time` cap the cost of a badly phrased question. Whether this role can be selected in the agent's configuration has not been verified (beta feature).
