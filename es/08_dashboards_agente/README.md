# Módulo 8 · Dashboards, API y ClickHouse Agents

Gold está listo: tablas pequeñas, ordenadas según los filtros, refrescadas cada 10 minutos. Las exponemos de tres formas, todas desde la consola Cloud:

| Para quién | Qué | Dónde |
|---|---|---|
| El equipo de operación, el jefe de proyecto | Un dashboard de 5 tarjetas, filtrable por entidad local y por día | este README, parte 1 |
| El portal de una entidad local | Una API HTTPS sin SQL en el lado del cliente | parte 2 |
| Todo el mundo | Un agente que responde en español, construye dashboards y hace data science | parte 3 |

Duración: 1 h. Todo se hace en la consola Cloud, siguiendo los pasos de abajo: en este módulo no hay ningún fichero SQL que ejecutar. Requisito previo: los módulos 00 a 07 se han ejecutado en tu servicio.

> Las etiquetas de abajo son las de la consola de ClickHouse Cloud en octubre de 2026. Dashboards y ClickHouse Agents están en **beta**: alguna etiqueta puede haber cambiado, el principio no.

---

## 1. El dashboard « Energía · Metrópolis » (20 min)

5 tarjetas, todas filtrables desde que se crean:

| # | Tarjeta | Tipo | Filtros |
|---|---|---|---|
| 1 | Curva de carga, consumo y producción | Line | entidad local, día |
| 2 | Mapa de calor del mes, día × hora | Heatmap | entidad local |
| 3 | Energía por día | Stacked bar | entidad local |
| 4 | Top 10 de municipios | Horizontal bar | entidad local |
| 5 | Alertas de exceso de potencia | Table | entidad local |

Los filtros aceptan valores legibles:
- **entidad**: un trozo del nombre, sin preocuparte por las mayúsculas. `Madrid`, `Barcelona`, `Valencia`, `Sevilla`, `Bilbao` o `Málaga`.
- **dia**: una fecha de octubre de 2026 en formato AAAA-MM-DD, por ejemplo `2026-10-15`.

Como las 5 tarjetas usan los **mismos nombres de parámetros**, un solo filtro controla todo el dashboard.

### Paso 1 · Crear el dashboard
1. En la barra lateral del servicio, haz clic en **Dashboards**.
2. Haz clic en **+ New Dashboard**.
3. Llámalo `Energía · Metrópolis`. Se abre el dashboard vacío.

### Paso 2 · Añadir una tarjeta (repetir 5 veces)
1. Arriba a la derecha, haz clic en **+ New visualization**. Aparece una tarjeta vacía y se abre el panel **Edit element** a la derecha.
2. Pestaña **General**, campo **Query**: elige **New query**. Se abre el **Inline Editor**.
3. Pega la consulta de la tarjeta (fichas más abajo).
4. A la derecha del editor, el panel **Query Parameters** muestra los parámetros detectados. Introduce los valores de prueba: `entidad` = `Madrid` y, para la tarjeta 1, `dia` = `2026-10-15`.
5. Ejecuta con el botón ▷, comprueba el resultado y guarda con el icono del **disquete**, con el nombre de la tarjeta.
6. **Visualization type**: elige el tipo indicado en la ficha.
7. Pestaña **Data**: asocia las columnas a los ejes como se indica en la ficha.
8. Ponle un título a la tarjeta y cierra el panel (×). Cambia el tamaño de la tarjeta desde su esquina inferior derecha y muévela con el asa de arriba a la izquierda.

### Las 5 fichas

#### Tarjeta 1 · Curva de carga del día
Tipo **Line**. Eje X: `hora`. Series Y: `consumo_mw`, `prod_mw`.
```sql
SELECT
    toTimeZone(ts, 'Europe/Madrid')                          AS hora,
    round(sumIf(potencia_kw, magnitud = 'CONS') / 1000, 2) AS consumo_mw,
    round(sumIf(potencia_kw, magnitud = 'PROD') / 1000, 2) AS prod_mw
FROM gold.curva_area
WHERE codigo_area IN (SELECT codigo_area FROM ref.destinatario
                    WHERE positionCaseInsensitiveUTF8(nombre, {entidad:String}) > 0)
  AND ts >  toDateTime({dia:Date}, 'Europe/Madrid')
  AND ts <= toDateTime({dia:Date} + 1, 'Europe/Madrid')
GROUP BY hora
ORDER BY hora
```
Qué observar: la punta de la tarde hacia las 19h (21,9 MW para Madrid el día 15) y la joroba solar a mediodía, muy por debajo.

#### Tarjeta 2 · Mapa de calor del mes
Tipo **Heatmap**. Eje X: `hora`. Eje Y: `dia`. Valor: `consumo_mw`.
```sql
SELECT
    toDate(ts - 1, 'Europe/Madrid')        AS dia,
    toHour(ts - 900, 'Europe/Madrid')      AS hora,
    round(avg(potencia_kw) / 1000, 2)    AS consumo_mw
FROM gold.curva_area
WHERE codigo_area IN (SELECT codigo_area FROM ref.destinatario
                    WHERE positionCaseInsensitiveUTF8(nombre, {entidad:String}) > 0)
  AND magnitud = 'CONS'
GROUP BY dia, hora
ORDER BY dia, hora
```
Qué observar: 31 filas × 24 columnas. La punta de la tarde forma una franja cada día, los fines de semana son más tranquilos durante el día y todo se oscurece a final de mes (arranca la calefacción). Es la tarjeta más elocuente del dashboard.

#### Tarjeta 3 · Energía por día
Tipo **Stacked bar**. Eje X: `dia`. Series Y: `consumo_mwh`, `prod_mwh`.
```sql
SELECT
    dia,
    round(consumo_kwh / 1000, 1) AS consumo_mwh,
    round(prod_kwh / 1000, 1)  AS prod_mwh
FROM gold.resumen_entidad_dia
WHERE positionCaseInsensitiveUTF8(entidad, {entidad:String}) > 0
ORDER BY dia
```
Qué observar: los valles de los fines de semana y la tendencia que sube a lo largo de octubre.

#### Tarjeta 4 · Top 10 de municipios
Tipo **Horizontal bar**. Categoría: `municipio`. Valor: `consumo_mwh`.
```sql
SELECT
    dictGet('ref.dict_municipio', 'nombre', codigo_ine) AS municipio,
    round(sum(energia_kwh) / 1000, 1)              AS consumo_mwh
FROM gold.energia_municipio_dia
WHERE codigo_area IN (SELECT codigo_area FROM ref.destinatario
                    WHERE positionCaseInsensitiveUTF8(nombre, {entidad:String}) > 0)
  AND magnitud = 'CONS'
GROUP BY codigo_ine
ORDER BY consumo_mwh DESC
LIMIT 10
```
Qué observar: la ciudad central en cabeza (Madrid, ~5 600 MWh) y después municipios que albergan un emplazamiento industrial (C2), como Leganés, Alcobendas o Rivas-Vaciamadrid. El nombre sale de un diccionario, sin JOIN.

#### Tarjeta 5 · Alertas de exceso de potencia
Tipo **Table**. Todas las columnas.
```sql
SELECT
    dia,
    municipio,
    segmento,
    kva_contratado,
    round(pmax_va / 1000, 1) AS pmax_kva,
    exceso_pct
FROM gold.alertas_pmax
WHERE codigo_area IN (SELECT codigo_area FROM ref.destinatario
                    WHERE positionCaseInsensitiveUTF8(nombre, {entidad:String}) > 0)
ORDER BY dia DESC, exceso_pct DESC
```
Qué observar: solo emplazamientos C4 y C2 (en C5, el limitador del contador corta antes de cualquier exceso). 140 alertas en octubre para el Área Urbana de Madrid, 33 para la de Barcelona.

### Paso 3 · Conectar los filtros
1. Vuelve a abrir cada tarjeta: **tres puntos** (⋮) arriba a la derecha y después **Edit**.
2. En los ajustes de la visualización, cada parámetro de la consulta (`entidad`, `dia`) aparece con su **origen de valor** (value source). Elige **filter**.
3. Hazlo en las 5 tarjetas.
4. Haz clic en el **embudo** de la barra superior: se abre el panel **Global filters**, con un campo `entidad` y un campo `dia`.

### Paso 4 · Jugar con el dashboard
1. En **Global filters**, escribe `Madrid` y `2026-10-15`: las 5 tarjetas muestran el Área Urbana de Madrid.
2. Cámbialo por `Barcelona` y luego por `Sevilla`: todo el dashboard cambia.
3. Cambia la fecha (`2026-10-25`, el día del cambio de hora: 50 medias horas): solo cambia la curva de la tarjeta 1.

Cada cambio relanza las 5 consultas. Cada una responde en unos milisegundos: a partir del nombre escrito, encuentra el código del territorio en `ref.destinatario` y luego filtra gold por el principio de su clave de ordenación (`codigo_area`).

Compartir: botón **Share** arriba. Un compañero también necesita acceso a las **consultas guardadas** que hay detrás.

Medido en el servicio de prueba (3 × 64 GB), filtro `Madrid`: de 6 a 28 ms por tarjeta.

---

## 2. El Query API endpoint para el portal (15 min)

El portal solo envía parámetros (una entidad local, dos fechas). El SQL se queda en ClickHouse. Convertimos una consulta guardada en una dirección HTTPS que se puede llamar con una clave API.

Leyenda: **[probado]** verificado en un servicio y un endpoint reales, **[consola]** a hacer en la interfaz.

### Paso 1 · Crear las dos vistas de la API [probado]
Una **vista parametrizada** es una consulta guardada en la base de datos, con parámetros `{nombre:Tipo}`. Se llama como una tabla: `SELECT * FROM gold.api_curva_entidad(id_destinatario = '488903', …)`. El portal solo verá esos parámetros.

Requisito previo: los módulos 00 a 07 se han ejecutado en **este mismo servicio** (las vistas leen las tablas gold).

En la consola SQL, pega este bloque y ejecútalo entero (Cmd+Enter):
```sql
-- La curva de carga de una entidad local, entre dos fechas
CREATE OR REPLACE VIEW gold.api_curva_entidad AS
SELECT
    toTimeZone(ts, 'Europe/Madrid')   AS hora,
    magnitud,
    round(potencia_kw, 1)           AS potencia_kw,
    n_contadores
FROM gold.curva_area
WHERE codigo_area IN (SELECT codigo_area FROM ref.destinatario WHERE id_destinatario = {id_destinatario:String})
  AND ts >  toDateTime({inicio:Date}, 'Europe/Madrid')
  AND ts <= toDateTime({fin:Date} + 1, 'Europe/Madrid')
ORDER BY magnitud, ts;

-- El resumen día a día de una entidad local
CREATE OR REPLACE VIEW gold.api_resumen_entidad AS
SELECT
    dia,
    entidad,
    round(consumo_kwh / 1000, 2)        AS consumo_mwh,
    round(prod_kwh / 1000, 2)         AS prod_mwh,
    round(100 * tasa_cobertura, 2)   AS cobertura_pct,
    n_contadores
FROM gold.resumen_entidad_dia
WHERE id_destinatario = {id_destinatario:String}
  AND dia BETWEEN {inicio:Date} AND {fin:Date}
ORDER BY dia;

-- El rol del módulo 7 tiene que poder leer el pequeño referencial que usa la vista
GRANT SELECT ON ref.destinatario TO role_madrid;
```
Si la consola abre un panel **Query Variables**, déjalo vacío: los parámetros solo sirven para llamar a la vista.

Comprueba:
```sql
SELECT name FROM system.tables WHERE database = 'gold' AND name LIKE 'api_%';
```
Resultado esperado: `api_curva_entidad` y `api_resumen_entidad`.

Si más adelante ves `Unknown table function gold.api_curva_entidad (UNKNOWN_FUNCTION)`, es que la vista no existe en el servicio en el que estás: repite este paso en ese servicio.

### Paso 2 · Obtener los valores que hay que pasar [probado]
El identificador de cada entidad local:
```sql
SELECT id_destinatario, nombre FROM ref.destinatario ORDER BY id_destinatario;
```
| id_destinatario | nombre |
|---|---|
| 488903 | Área Urbana de Madrid |
| 488904 | Área Urbana de Barcelona |
| 488905 | Área Urbana de Valencia |
| 488906 | Área Urbana de Sevilla |
| 488907 | Área Urbana de Bilbao |
| 488908 | Área Urbana de Málaga |

Las fechas disponibles:
```sql
SELECT min(dia) AS primer_dia, max(dia) AS ultimo_dia FROM gold.resumen_entidad_dia;
```
Resultado esperado: del `2026-10-01` al `2026-10-31`.

### Paso 3 · Escribir y probar la consulta del endpoint [probado]
1. Nueva pestaña en la consola SQL. Pega:
   ```sql
   SELECT *
   FROM gold.api_curva_entidad(
       id_destinatario = {id_destinatario:String},
       inicio          = {inicio:Date},
       fin             = {fin:Date})
   ```
2. El panel **Query Variables** se abre a la derecha con tres campos. Introduce `488903`, `2026-10-15`, `2026-10-15`.
3. Ejecuta (Cmd+Enter). Resultado esperado: **96 filas** (48 medias horas × CONS y PROD), punta de ~21,9 MW hacia las 19h.
4. Haz clic en **Save** y llama a la consulta `api_curva_entidad`.

### Paso 4 · Crear la clave API [probado]
1. En el menú de la izquierda de la organización, abre **API Keys** y haz clic en **New API Key**.
2. Nombre: `portal-entidades`. Rol de organización: **Member**. Acceso al servicio: **Query Endpoints** en tu servicio. Elige una fecha de caducidad.
3. Opcional: en **Allow access to this API Key**, limita el acceso a las direcciones IP del portal.
4. Haz clic en **Generate API Key**. La pantalla siguiente muestra el **Key ID** y el **Key secret**: cópialos enseguida en un gestor de contraseñas. No se volverán a mostrar nunca.

### Paso 5 · Crear el endpoint [probado]
1. Vuelve a abrir la consulta guardada `api_curva_entidad`.
2. Haz clic en **Share** y luego en **API Endpoint**.
3. Elige la clave API del paso 4.
4. Elige el **rol de base de datos** que ejecutará la consulta: **Read only**, o el rol `role_madrid` del módulo 7 para que el endpoint solo vea el Área Urbana de Madrid.
5. **CORS**: el dominio del portal (déjalo vacío para una prueba desde la línea de comandos).
6. Confirma. La consola muestra la **dirección de llamada**, con la forma `https://queries.clickhouse.cloud/run/<identificador>`. Cópiala.

### Paso 6 · Llamar al endpoint [probado]
En un terminal, guarda los valores en variables (nunca en un fichero versionado):
```bash
export KEY_ID='<Key ID del paso 4>'
export KEY_SECRET='<Key secret del paso 4>'
export ENDPOINT='https://queries.clickhouse.cloud/run/<identificador del paso 5>'
```
Llamada GET, con los parámetros en la dirección:
```bash
curl -s --user "$KEY_ID:$KEY_SECRET" \
  "$ENDPOINT?format=JSONEachRow&param_id_destinatario=488903&param_inicio=2026-10-15&param_fin=2026-10-15"
```
Llamada POST, con los parámetros en el cuerpo:
```bash
curl -s --user "$KEY_ID:$KEY_SECRET" -X POST -H "Content-Type: application/json" \
  "$ENDPOINT?format=JSONEachRow" \
  -d '{"queryVariables": {"id_destinatario": "488903", "inicio": "2026-10-15", "fin": "2026-10-15"}}'
```

Resultados obtenidos en un endpoint real:

| Llamada | Resultado |
|---|---|
| GET o POST, Madrid (`488903`), el 15 de octubre | HTTP 200, **96 filas** (48 medias horas × CONS y PROD), ~1 s |
| GET, Madrid, del 13 al 19 de octubre | HTTP 200, **672 filas** (7 días × 96) |
| GET o POST, Barcelona (`488904`), endpoint creado con el rol `role_madrid` | HTTP 200, **0 filas**: la row policy oculta todo lo que no sea el Área Urbana de Madrid |

Trampas encontradas:
- **`401 Unauthorized`** (y `Key is not found` en la API de Cloud): la clave está mal copiada. El Key secret empieza por `4b1d`: comprueba que ese principio no se ha perdido al copiar y pegar. Para probar solo la clave: `curl --user "$KEY_ID:$KEY_SECRET" https://api.clickhouse.cloud/v1/organizations` debe devolver tu organización.
- **Ni espacios ni caracteres de más en la dirección**: `param_id_destinatario=488903`, y no `param_id_destinatario= 488903`; `param_fin=2026-10-15`, y no `param_fin=<2026-10-15`. Los `<…>` de los ejemplos se sustituyen enteros.
- `404`: el identificador del endpoint es incorrecto. `400`: un parámetro está mal formado (fecha en formato AAAA-MM-DD).

### Paso 7 · Ver las llamadas en el lado del servidor [probado]
Cada endpoint se ejecuta con un usuario dedicado llamado `queryEndpoint:<identificador>`:
```sql
SYSTEM FLUSH LOGS;
SELECT event_time, user, round(query_duration_ms) AS ms, read_rows
FROM clusterAllReplicas('default', system.query_log)
WHERE type = 'QueryFinish' AND user LIKE 'queryEndpoint:%' AND event_date = today()
ORDER BY event_time DESC
LIMIT 10;
```
Qué observar: unos milisegundos y ~8 200 filas leídas por llamada.

### Plan B · Probar sin clave API, por HTTPS directo [probado]
Para comprobar la consulta antes de tener una clave, la interfaz HTTPS del servicio acepta los mismos parámetros (`param_<nombre>`). Es una prueba: no pongas nunca la contraseña de `default` en un portal.
```bash
curl --user "default:$CH_PASSWORD" \
  "https://$CH_HOST:8443/?param_id_destinatario=488903&param_inicio=2026-10-15&param_fin=2026-10-15&default_format=JSONEachRow" \
  --data-binary "SELECT * FROM gold.api_curva_entidad(id_destinatario = {id_destinatario:String}, inicio = {inicio:Date}, fin = {fin:Date}) LIMIT 3"
```

Medido (misma consulta, cliente nativo y HTTPS directo): de 3 a 30 ms, ~8 200 filas leídas para un día de curva.

---

## 3. ClickHouse Agents (35 min)

Un agente no adivina el negocio: lee el esquema. Así que documentamos gold, creamos el agente con las herramientas adecuadas, le hacemos 2 preguntas para entrar en materia, luego le pedimos que construya 6 dashboards y le encargamos 3 ejercicios de data science.

### Paso 1 · Documentar gold para el agente [probado]
Un agente empieza leyendo las tablas, sus columnas y sus **comentarios** (regla `agent-discovery-schema`). Sin comentarios, adivinará que `ts` está en hora local o que `488903` es un código postal. Estos comandos solo tocan los metadatos: instantáneo, no se reescribe ningún dato.

En la consola SQL, pega este bloque y ejecútalo entero (Cmd+Enter):
```sql
ALTER TABLE gold.resumen_entidad_dia
    MODIFY COMMENT 'Resumen diario por entidad local destinataria de los flujos de medida (6 metrópolis). Una fila por entidad local y por día de octubre de 2026. Energías en kWh.';
ALTER TABLE gold.resumen_entidad_dia
    COMMENT COLUMN id_destinatario 'Identificador del destinatario (488903 = Área Urbana de Madrid, ver ref.destinatario)',
    COMMENT COLUMN dia            'Día local (Europe/Madrid)',
    COMMENT COLUMN consumo_kwh       'Energía consumida en el territorio ese día, en kWh',
    COMMENT COLUMN prod_kwh        'Energía producida (fotovoltaica) en el territorio ese día, en kWh',
    COMMENT COLUMN tasa_cobertura 'prod_kwh / consumo_kwh, entre 0 y 1',
    COMMENT COLUMN n_contadores          'Número de contadores que han enviado una curva ese día';

ALTER TABLE gold.curva_area
    MODIFY COMMENT 'Curva de carga agregada por Gran Área Urbana, paso de 30 min. ts = FIN del intervalo, en UTC: convertir con toTimeZone(ts, ''Europe/Madrid''). Filtrar por codigo_area y después por ts (clave de ordenación).';
ALTER TABLE gold.curva_area
    COMMENT COLUMN codigo_area    'Código de la Gran Área Urbana del Ministerio de Transportes (001 = Área Urbana de Madrid, 002 = Barcelona). Los municipios fuera de un área tienen un código vacío. Nombre: dictGet(''ref.dict_area'', ''nombre'', codigo_area)',
    COMMENT COLUMN magnitud     'CONS = consumo, PROD = producción',
    COMMENT COLUMN ts           'Fin del intervalo de 30 min, UTC',
    COMMENT COLUMN potencia_kw 'Potencia media en el intervalo, suma de los contadores, en kW',
    COMMENT COLUMN n_contadores       'Número de puntos (contadores) agregados';

ALTER TABLE gold.energia_municipio_dia
    MODIFY COMMENT 'Energía por municipio, día, segmento (C5, C4, C2) y magnitud (CONS, PROD). Nombre del municipio: dictGet(''ref.dict_municipio'', ''nombre'', codigo_ine).';
ALTER TABLE gold.energia_municipio_dia
    COMMENT COLUMN segmento     'C5 = particulares y pequeños profesionales (≤ 36 kVA), C4 = pymes/terciario (36 a 250 kVA), C2 = industriales en media tensión',
    COMMENT COLUMN energia_kwh 'Energía del día en kWh',
    COMMENT COLUMN n_contadores      'Contadores de este segmento en el municipio ese día (sumar los segmentos para el total)';

ALTER TABLE gold.alertas_pmax
    MODIFY COMMENT 'Excesos sobre la potencia contratada (flujo PMAX). Una fila por contador y por día con exceso. Solo los C4 y C2 pueden superarla (en C5 el limitador corta).';
ALTER TABLE gold.alertas_pmax
    COMMENT COLUMN kva_contratado    'Potencia contratada VIGENTE ese día, en kVA',
    COMMENT COLUMN pmax_va         'Potencia máxima alcanzada en el día, en VA',
    COMMENT COLUMN exceso_pct 'Exceso en % de la potencia contratada',
    COMMENT COLUMN instante_punta    'Instante de la punta, hora de Madrid';

ALTER TABLE gold.kpi_completitud_dia
    MODIFY COMMENT 'Completitud de la recogida de las curvas CURVA a las 9h del día siguiente. Objetivo: datos_9h_pct >= 99.';
ALTER TABLE gold.kpi_completitud_dia
    COMMENT COLUMN datos_9h_pct      'Puntos recibidos antes de las 9h / puntos esperados, en %. Es el KPI contractual',
    COMMENT COLUMN contadores_completos_9h_pct 'Proporción de contadores con el día completo a las 9h, en %';
```

Comprueba:
```sql
SELECT name, comment FROM system.tables WHERE database = 'gold' AND comment != '' ORDER BY name;
```
Resultado esperado: 6 tablas comentadas (`alertas_pmax`, `curva_area`, `energia_municipio_dia`, `kpi_completitud_dia`, `perfil_contador`, `resumen_entidad_dia`). `perfil_contador` ya lleva comentarios desde que se crea en el módulo 05.

### Paso 2 · Crear y configurar el agente [consola]
1. En la barra lateral del servicio, haz clic en **ClickHouse agents** y luego en **Launch ClickHouse agents**.
2. Haz clic en **+ Create New Agent** y rellena:

| Campo | Valor |
|---|---|
| Nombre | `Asistente Energía` |
| Descripción | `Responde a preguntas de negocio y construye dashboards sobre la recogida de datos de octubre (base gold).` |
| **Model** | un modelo **Claude Sonnet** de la lista (el que viene por defecto sirve). Hace falta un modelo capaz de llamar a herramientas y de producir artifacts |
| Category | `General` |
| Instructions | pestaña **Inline**, pega el texto de abajo |
| **Tools** | **+ Add** y añade las tres: **ClickHouse** (conectada a tu servicio, 9 herramientas: listar las tablas, ejecutar SQL…), **Artifacts** (para construir los dashboards), **Run Code** (cálculos y gráficos en Python) |
| Skills | **All** |
| Conversation starters | añade las peticiones D1, D2 y D3 del paso 5 de abajo: aparecerán como botones al empezar una conversación |
| File context, Support contact | opcionales |

Sin la herramienta **ClickHouse**, el agente no ve tus datos. Sin **Artifacts**, responde con texto pero no construye ningún dashboard.

Instrucciones que hay que pegar (un único bloque, actualizado):
```
Eres el asistente de datos de una distribuidora de electricidad. Respondes en español
a preguntas de negocio sobre la recogida de datos de medida de octubre de 2026.
- Usa ÚNICAMENTE las tablas de la base gold y ref.destinatario, a través de la herramienta ClickHouse.
  Lee primero los comentarios de las tablas y de las columnas, y su clave de ordenación.
- Filtra siempre por el principio de la clave de ordenación y añade un LIMIT.
- ts está en UTC y marca el FINAL de una media hora: convierte con toTimeZone(ts, 'Europe/Madrid').
- Los nombres de municipios y de áreas urbanas se leen con dictGet('ref.dict_municipio', 'nombre', codigo_ine)
  y dictGet('ref.dict_area', 'nombre', codigo_area).
- Cuando te pidan un dashboard, una página o un informe: consulta primero ClickHouse
  y después construye un artifact interactivo con los valores REALES obtenidos (nunca datos
  inventados), títulos en español, las unidades (MW, MWh, %) y 2 o 3 frases de análisis.
- Si no, da las cifras clave con su unidad y después la consulta SQL utilizada.

Data science con la herramienta Run Code:
- Ejecutas siempre tú mismo el código Python en la herramienta Run Code. No propongas nunca un
  script para que lo lance otro, no uses nunca clickhouse_connect ni ninguna conexión a una base.
- Método, siempre el mismo:
  1. una consulta con la herramienta ClickHouse que devuelva menos de 100 filas (agrega o
     muestrea en ClickHouse);
  2. copia el resultado tal cual en tu código Python;
  3. ejecuta el código en Run Code y muestra las cifras y un gráfico.
- Curva de un territorio: una fila por día, con las 48 medias horas en un array:
  SELECT dia, toDayOfWeek(dia) >= 6 AS es_finde,
         arrayMap(x -> x.2, arraySort(groupArray((media_hora, mw)))) AS consumo_mw
  FROM (SELECT toDate(ts - 1800, 'Europe/Madrid') AS dia,
               toHour(ts - 1800, 'Europe/Madrid') * 2 + intDiv(toMinute(ts - 1800, 'Europe/Madrid'), 30) AS media_hora,
               round(avg(potencia_kw) / 1000, 2) AS mw
        FROM gold.curva_area
        WHERE codigo_area = '<código del área, 001 = Madrid>' AND magnitud = 'CONS'
        GROUP BY dia, media_hora)
  GROUP BY dia ORDER BY dia
- Formas de los contadores (30 por segmento C5, C4, C2):
  SELECT segmento, perfil, arrayMap(x -> round(x, 2), forma_laborable) AS laborable,
         arrayMap(x -> round(x, 2), forma_finde) AS finde
  FROM gold.perfil_contador ORDER BY cityHash64(id_contador) LIMIT 30 BY segmento
  Si gold.perfil_contador no existe, dilo en una frase: se crea con el fichero
  05_gold/04_formas_contadores.sql del workshop. No uses silver en su lugar.
- Previsión: HistGradientBoostingRegressor(max_iter=300, learning_rate=0.05, random_state=0)
  con media_hora, es_finde y el día del mes. Compara siempre su error (MAPE) con dos métodos
  ingenuos alineados por media hora: el día anterior y el mismo día de la semana anterior.
- Segmentación: KMeans(n_clusters=3, n_init=10, random_state=0) sobre los 48 valores de forma
  (laborable y después fin de semana), y cruza las familias con el segmento Y el perfil.
- Perfilado: separa 70 % / 30 % (estratificado por segmento), forma tipo = centro del grupo
  KMeans aprendido sobre el 70 %, error medio en % por segmento sobre el 30 %, comparado con
  una curva plana.
- Presenta siempre el resultado en un artifact: los gráficos, una tabla de las cifras
  clave (errores, tamaño de los grupos) y de 3 a 5 frases de análisis en español, sin jerga.
```

### Paso 3 · Abrir una conversación [consola]
1. Guarda el agente.
2. Arriba de la página, elige `Asistente Energía` en la lista y haz clic en **Select**.
3. Se abre una conversación. Los conversation starters aparecen como botones.

### Paso 4 · Hacer 2 preguntas para entrar en materia
Con dos preguntas basta para ver cómo trabaja el agente: lee los comentarios, escribe el SQL, filtra por la clave de ordenación. Lo más interesante viene después, con los dashboards y la data science.

Copia cada pregunta tal cual en la conversación y compara la respuesta con el resultado esperado. La consulta de verificación (despliégala) da la cifra real.

**Q1** · "¿Cuánto consumió el Área Urbana de Madrid en octubre y qué parte cubrió la producción solar local?"

Resultado esperado: ~10 846 MWh consumidos, ~445 MWh producidos, cobertura de ~4,1 %.

<details><summary>Consulta de verificación</summary>

```sql
SELECT round(sum(consumo_kwh) / 1000) AS consumo_mwh,
       round(sum(prod_kwh) / 1000)  AS prod_mwh,
       round(100 * sum(prod_kwh) / sum(consumo_kwh), 1) AS cobertura_pct
FROM gold.resumen_entidad_dia
WHERE id_destinatario = '488903';
```
</details>

**Q2** · "¿A qué hora fue la punta de consumo del Área Urbana de Madrid el 15 de octubre, y de cuántos MW?"

Resultado esperado: 19h00 (hora de Madrid), ~21,9 MW. Trampa: ts está en UTC y marca el FINAL de la media hora.

<details><summary>Consulta de verificación</summary>

```sql
SELECT toTimeZone(ts, 'Europe/Madrid') AS hora, round(potencia_kw / 1000, 2) AS mw
FROM gold.curva_area
WHERE codigo_area = '001' AND magnitud = 'CONS'
  AND ts > toDateTime('2026-10-15', 'Europe/Madrid') AND ts <= toDateTime('2026-10-16', 'Europe/Madrid')
ORDER BY potencia_kw DESC
LIMIT 1;
```
</details>

### Paso 5 · Pedirle que construya dashboards (el momento estrella)
Con las herramientas **ClickHouse** y **Artifacts**, el agente ya no se limita a responder: consulta gold y construye una página interactiva con gráficos y cifras clave, en unas decenas de segundos.

Para cada petición:
1. Pégala en la conversación (o haz clic en el conversation starter).
2. Mira las consultas que ejecuta el agente: debe leer los comentarios y después filtrar por `codigo_area` o `id_destinatario`.
3. Compara las cifras de la página con el resultado esperado.
4. Pide un retoque en la misma conversación: « añade un filtro por metrópoli », « pasa la curva a áreas apiladas », « exporta a PDF ».

Empieza por **D2** (el mapa de calor) y luego **D1** (el dashboard completo): son los más visuales.

Una buena página: datos reales (nunca inventados), unidades (MW, MWh, %), títulos en español y unas líneas de análisis bajo los gráficos.

**D1** · "Construye un dashboard interactivo del Área Urbana de Madrid para octubre de 2026: la curva de carga del 15 de octubre (consumo y producción), la energía día a día, el top 10 de municipios, el KPI de completitud a las 9h y las alertas del último día. Añade 3 cifras clave arriba de la página."

Resultado esperado: 5 gráficos y 3 cifras clave (~10 846 MWh, ~4,1 % de cobertura, 98,4 % de KPI medio). En lo esencial, son las consultas de las tarjetas del README de esta carpeta.

<details><summary>Consulta de verificación</summary>

```sql
SELECT round(sum(consumo_kwh) / 1000) AS consumo_mwh, round(100 * sum(prod_kwh) / sum(consumo_kwh), 1) AS cobertura_pct
FROM gold.resumen_entidad_dia
WHERE id_destinatario = '488903';
```
</details>

**D2** · "Haz un mapa de calor día × hora del consumo del Área Urbana de Madrid en octubre y explica en 3 frases lo que muestra."

Resultado esperado: 31 filas × 24 columnas, de unos 8 MW por la noche a más de 20 MW en la punta. El análisis debe mencionar la punta de la tarde (18h-19h, la franja más oscura), los fines de semana más tranquilos durante el día y la subida a final de mes.

<details><summary>Consulta de verificación</summary>

```sql
SELECT toDate(ts - 1, 'Europe/Madrid') AS dia, toHour(ts - 900, 'Europe/Madrid') AS hora,
       round(avg(potencia_kw) / 1000, 2) AS consumo_mw
FROM gold.curva_area
WHERE codigo_area = '001' AND magnitud = 'CONS'
GROUP BY dia, hora
ORDER BY dia, hora;
```
</details>

**D3** · "Compara las 6 metrópolis en una sola página: consumo, producción solar, tasa de cobertura y número de alertas del mes. Destaca la más solar."

Resultado esperado: una tabla ordenada y un gráfico. Sevilla (~5,5 %) y Málaga (~5,2 %) en cabeza por cobertura, Madrid, con diferencia, el mayor consumidor (~10 846 MWh) y el que más alertas tiene (140 de las 257 del mes).

<details><summary>Consulta de verificación</summary>

```sql
SELECT s.entidad,
       round(sum(s.consumo_kwh) / 1000)                    AS consumo_mwh,
       round(sum(s.prod_kwh) / 1000)                     AS prod_mwh,
       round(100 * sum(s.prod_kwh) / sum(s.consumo_kwh), 1) AS cobertura_pct,
       any(a.alertas)                                    AS alertas
FROM gold.resumen_entidad_dia AS s
INNER JOIN ref.destinatario AS d ON d.id_destinatario = s.id_destinatario
LEFT JOIN (SELECT codigo_area, count() AS alertas FROM gold.alertas_pmax GROUP BY codigo_area) AS a ON a.codigo_area = d.codigo_area
GROUP BY s.entidad
ORDER BY cobertura_pct DESC;
```
</details>

**D4** · "Prepara el informe de operación del 30 de octubre para el jefe de equipo: completitud a las 9h, ficheros que llegaron tarde este mes, alertas de exceso del día y 3 recomendaciones. Preséntalo como una página para imprimir."

Resultado esperado: KPI del día 30 por encima del 99 %, los 6 días bajo el objetivo con sus ficheros retrasados (llegados a las 14h), 6 alertas C4 el día 30 y recomendaciones concretas (reclamar los lotes retrasados, contactar con los emplazamientos que superan su potencia).

<details><summary>Consulta de verificación</summary>

```sql
SELECT dia, datos_9h_pct FROM gold.kpi_completitud_dia WHERE datos_9h_pct < 99 OR dia = '2026-10-30' ORDER BY dia;
```
</details>

**D5** · "¿Qué emplazamientos superan con frecuencia su potencia contratada? Muéstralos en un gráfico (exceso medio y número de días) y di cuáles deberían aumentar su potencia."

Resultado esperado: una veintena de emplazamientos, casi todos C4, con 3 o 4 días de exceso (Pallejà, Madrid, Getafe y Móstoles en cabeza con 4 días). Buena respuesta: el agente recuerda que en C5 el limitador corta antes de cualquier exceso.

<details><summary>Consulta de verificación</summary>

```sql
SELECT id_contador, any(municipio) AS municipio, any(segmento) AS segmento, count() AS dias_exceso,
       round(avg(exceso_pct), 1) AS exceso_medio_pct, max(kva_contratado) AS kva_contratado
FROM gold.alertas_pmax
GROUP BY id_contador
HAVING dias_exceso >= 2
ORDER BY dias_exceso DESC, exceso_medio_pct DESC
LIMIT 20;
```
</details>

**D6** · "Haz una página para un cargo electo de Barcelona: 4 cifras clave del mes, la curva de un día laborable tipo y la de un día de fin de semana, todo comprensible para alguien que no es especialista."

Resultado esperado: cifras del Área Urbana de Barcelona (~2 140 MWh, ~3,3 % solar), dos curvas comparadas (el fin de semana más bajo durante el día) y un texto sin jerga.

<details><summary>Consulta de verificación</summary>

```sql
SELECT if(toDayOfWeek(toDate(ts - 1, 'Europe/Madrid')) >= 6, 'fin de semana', 'laborable') AS tipo_dia,
       toHour(ts - 900, 'Europe/Madrid') AS hora,
       round(avg(potencia_kw) / 1000, 2) AS consumo_mw
FROM gold.curva_area
WHERE codigo_area = '002' AND magnitud = 'CONS'
GROUP BY tipo_dia, hora
ORDER BY tipo_dia, hora;
```
</details>

### Paso 6 · Data science: prever y reconstruir curvas con Run Code
La herramienta **Run Code** le da al agente un Python de verdad (pandas, scikit-learn) en un sandbox. El reparto de papeles es el buen reflejo de un data scientist con ClickHouse:
- **ClickHouse prepara los datos**: agregados, formas de consumo, muestras. Es rápido y reduce el volumen;
- **Python entrena el modelo** con solo unos cientos o unos miles de filas.

Comprueba primero que la herramienta **Run Code** está en la lista de herramientas del agente (paso 2).

**6.1 · Comprobar que las formas de consumo están en gold [probado]**
Los ejemplos 2 y 3 usan la tabla `gold.perfil_contador`: cada contador se resume en ella por su forma media, 24 valores en día laborable y 24 en fin de semana, divididos por su consumo medio. Se crea en el módulo 05 con `05_gold/04_formas_contadores.sql`. Compruébalo en la consola SQL:
```sql
SELECT segmento, perfil, count() AS contadores FROM gold.perfil_contador GROUP BY segmento, perfil ORDER BY segmento, perfil;
```
Resultado esperado: C2 ENT 40, C4 PRO ~230, C5 PRO ~2 360, C5 RES ~17 370.

Si ves `Table gold.perfil_contador does not exist`, abre `05_gold/04_formas_contadores.sql`, pégalo en la consola y ejecútalo entero (Cmd+Enter): menos de un segundo. Sin esta tabla, el agente te responderá que no puede hacer los ejemplos 2 y 3. Es el comportamiento correcto: no debe inventarse datos.

**6.2 · Las instrucciones de data science [consola]**
Run Code ejecuta Python en un sandbox que no tiene tus credenciales de ClickHouse. Sin instrucciones, el agente escribe un script con `clickhouse_connect` y te pide que lo lances tú. Por eso el método se le da de una vez por todas, en la parte « Data science con la herramienta Run Code » de sus instrucciones (paso 2): consulta compacta con la herramienta ClickHouse, datos pegados en el código, ejecución en Run Code, resultado en un artifact.

Si creaste el agente antes de añadir esa parte, vuelve a copiar el bloque completo del paso 2, guarda y abre una conversación **nueva**.

**6.3 · Las tres peticiones**
Basta con una frase: el método está en las instrucciones.

| | Petición que hay que pegar | Resultado esperado |
|---|---|---|
| **ML1 · Previsión** | « Prevé la curva de carga del Área Urbana de Madrid para el sábado 31 de octubre a partir de los datos del 1 al 30 de octubre, y compárala con la realidad. » | error del modelo del orden del **2,3 %**, sábado anterior del orden del 3,3 %, día anterior del orden del 47 %. Punta real hacia las 19h30, del orden de 22 MW |
| **ML2 · Segmentación** | « Agrupa los contadores en 3 familias según la forma de su consumo, cruza esas familias con los segmentos C5, C4 y C2, y enséñame cada familia. » | 90 contadores (30 por segmento). 3 familias: **hogares** (25 C5 residenciales, punta de la tarde), **profesionales** (los 30 C4 y 5 pequeños profesionales C5, meseta de 8h a 19h), **industria** (los 30 C2, consumo base alto, activos el fin de semana) |
| **ML3 · Perfilado** | « Demuéstrame que se puede reconstruir la curva de un contador a partir solo de su energía, con la forma tipo de su familia. » | **~2,3 %** de error con la forma tipo, en cada segmento, frente a ~46 % con una curva plana |

Cada resultado se muestra en un artifact: gráficos, tabla de cifras clave y unas frases de análisis.

Los resultados esperados salen de ejecutar estos mismos cálculos en Python (scikit-learn 1.9) sobre los datos del servicio. El agente puede obtener cifras algo distintas: lo que cuenta es el orden de magnitud.

Para recordar de ML1: el modelo gana a los dos métodos ingenuos porque sabe que mañana es sábado y porque sigue la subida de final de mes. Con el `GradientBoostingRegressor` por defecto se obtiene ~8 %, peor que el sábado anterior: la elección del modelo importa, de ahí la instrucción.

Para recordar de ML2: la familia profesional mezcla C4 y pequeños profesionales C5. La forma del consumo depende del uso, no de la potencia contratada.

Para recordar de ML3: es el principio del **perfilado**. Para un contador sin curva de carga, se multiplica su energía (leída por índice) por la forma tipo de su familia.

**Si el agente sigue sin ejecutar el código**: respóndele « ejecútalo tú mismo con Run Code, pegando los datos en el código ». Comprueba también que la conversación se abrió después de guardar las instrucciones.

Estos resultados son limpios porque los datos son simulados. Con datos reales, la meteorología, las vacaciones y los comportamientos individuales aumentan los errores. El método, en cambio, es el mismo.

### Paso 7 · En producción: un rol dedicado al agente
Durante el workshop, el agente funciona con tus permisos. En producción, se le da un rol de solo lectura sobre gold, con límites en cada consulta (regla `agent-query-safety`). Adáptalo a tu caso, no se ejecuta durante el workshop:
```sql
CREATE SETTINGS PROFILE IF NOT EXISTS perfil_agente SETTINGS
    readonly = 2, max_execution_time = 30, max_rows_to_read = 1000000000,
    max_result_rows = 10000, result_overflow_mode = 'break';
CREATE ROLE IF NOT EXISTS rol_agente SETTINGS PROFILE 'perfil_agente';
GRANT SELECT ON gold.* TO rol_agente;
GRANT SELECT ON ref.* TO rol_agente;
GRANT dictGet ON ref.* TO rol_agente;
```
`readonly = 2` prohíbe cualquier escritura, y `max_rows_to_read` y `max_execution_time` acotan el coste de una pregunta mal planteada. No está comprobado que se pueda elegir este rol en la configuración del agente (funcionalidad en beta).
