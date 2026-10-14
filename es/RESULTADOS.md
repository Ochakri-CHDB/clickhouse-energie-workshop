# Resultados medidos · Workshop ClickHouse Energía

Medidas del 14 de octubre de 2026, ejecución completa desde cero (`./run_all.sh`, unos 3 min 40 en total) en el servicio de pruebas:
**ClickHouse Cloud 26.6, AWS eu-central-1, 3 réplicas de 64 GB (16 vCPU cada una)**, la configuración
recomendada a los participantes. Duraciones leídas en `system.query_log` (tiempo de servidor). Los datos de medida son simulados
y deterministas: volúmenes, filas leídas y resultados son idénticos para cada participante. La geografía es real
(padrón del INE a 1 de enero de 2025, Grandes Áreas Urbanas del Ministerio de Transportes).
Las mismas cifras aparecen como comentario (`Medido`) bajo cada instrucción de los ficheros SQL.

> Órdenes de magnitud para las slides
> - **1 500 millones** de puntos de curva generados y escritos en **64 s** (8 lotes de 7,7 a 8,4 s, ~23 M de puntos/s), **1,41 bytes por punto**
> - La curva de un contador en un mes: **16 384 filas leídas de 1 500 millones**, de 5 a 55 ms
> - **3 réplicas** sobre el mismo escaneo de 1 500 millones de filas: **5,7 s → 3,1 s** (×1,8), sin cambiar el SQL
> - Una proyección: la punta nacional pasa de **2,5 s a 34 ms** (×75), **67 000 veces menos filas leídas**
> - El JSON bruto comprimido **×15**, las curvas tipadas **×18 a ×24**
> - La geografía real: **8 132 municipios** del INE y **86 áreas urbanas**, unidos con `pointInPolygon` en 9 s
> - Un panel de dashboard sobre gold: **de 6 a 28 ms**

---

## 00 · Primeros pasos
| Medida | Valor |
|---|---|
| 1 millón de medidas JSON generadas con un SELECT | 271 ms (56,9 MB de JSON) |
| 10 millones (variante propuesta, ejecución anterior) | 2,35 s, 569 MB de JSON |

## 01 · Fundamentos y datos de referencia
| Medida | Valor |
|---|---|
| Municipios leídos en directo (padrón del INE + centroides del Ministerio de Transportes) | 8 132 municipios, 49,1 M de habitantes, `ref.municipio` cargada en 4,84 s |
| Provincias y comunidades autónomas (API JSON del INE) | 52 provincias en 2,07 s, 19 comunidades autónomas en 856 ms |
| Grandes Áreas Urbanas (Ministerio de Transportes) | 86 áreas en 375 ms |
| Pertenencia de cada municipio a un área (`pointInPolygon`, centroide frente a los polígonos) | 756 municipios dentro de un área, calculado en 8,97 s (96 MB de memoria) |
| Parque de contadores generado (ASOF JOIN sobre la población acumulada) | 1 000 000 en 510 ms |
| Reparto del parque | C5 98,7 % (RES 86,8 %, PRO 11,8 %), C4 1,1 %, C2 0,2 % |
| Potencia media | RES 8,8 kVA, PRO C5 19,8 kVA, C4 138 kVA, C2 754 kVA |
| Historial de potencias | 1 028 889 filas, 28 889 cambios en octubre, generado en 266 ms |
| Contadores de los ficheros JSON en el territorio de su destinatario | 20 000 / 20 000 (6 áreas urbanas: Madrid 12 000, Barcelona, Valencia y Sevilla 2 000 cada una, Bilbao y Málaga 1 000) |
| Compresión de `ref.contador` | 26,9 MB → 6,9 MB (×3,9). `segmento` ×33 (LowCardinality), `codigo_ine` ×6,1 |
| Índice disperso: un contador por su clave / fuera de la clave | 8 192 filas leídas en 5 ms / 1 000 000 en 6 ms |

## 02 · Bronze
| Medida | Valor |
|---|---|
| Ficheros recibidos | 1 800 (600 CURVA, 600 ENERGIA, 600 PMAX) |
| JSON bruto | CURVA 1,35 GB, ENERGIA 170 MB, PMAX 147 MB, total 1,66 GB |
| En disco (ZSTD 3) | 112 MB, **ratio ×15** |
| 1.er día de CURVA (20 ficheros) | 901 ms |
| Generación + escritura de CURVA, 580 ficheros | 11,3 s (1,30 GB de JSON, 2,2 GB de memoria) |
| ENERGIA, 600 ficheros / PMAX, 600 ficheros | 3,5 s / 5,4 s |
| Explorar el JSON (JSONExtract, tipo JSON) | de 21 a 263 ms sobre 64 a 600 ficheros |

## 03 · Silver
| Medida | Valor |
|---|---|
| Backfill: puntos extraídos del JSON (3 ARRAY JOIN) | 29,9 M de puntos en 18,2 s (1,65 M puntos/s) |
| Rechazos / energía diaria / PMax | 8 754 en 2,7 s / 625 080 en 797 ms / 600 000 en 852 ms |
| Flujo continuo: 20 ficheros del 31/10, MV en cascada bronze → silver → gold | 996 006 puntos en 5,95 s |
| Compresión de `silver.curva_carga` | 1,06 GB → 45 MB, **ratio ×24, 1,52 bytes por punto** |
| Por columna | `valor_w` 39 MB (×3), `ts` 457 KB (×264, Delta), `id_contador` 473 KB (×511), `magnitud` 38 KB (×790) |
| Reenvío de un fichero y luego corrección | 48 puntos visibles con FINAL, se conserva la versión CORREGIDO |
| Cambio de hora del 25/10 | 50 puntos ese día, 48 los demás |

## 04 · Diccionarios
| Medida | Valor |
|---|---|
| Energía por provincia, 30 M de puntos | dictGet 158 ms (192 MB) · JOIN 278 ms (282 MB). Madrid 10 919 MWh, Barcelona 2 140, Sevilla 1 759 |
| Control de calidad con dictHas sobre 31 M de puntos | 23 ms |
| Memoria de los diccionarios | dict_contador 87 MB (1 M de claves), dict_potencia_asof 345 MB, dict_municipio 4 MB (8 132 claves) |
| Búsqueda aproximada de "Alcala de Enares" | Alcalá de Henares, distancia 0,38, en 4 ms (luego Tórtola de Henares 0,47 y Azuqueca de Henares 0,48) |

## 05 · Gold
| Medida | Valor |
|---|---|
| Backfill del seguimiento de la recogida (AggregatingMergeTree) | 618 163 filas en 5,3 s (3,2 GB de memoria) |
| Trampa de la suma en una MV, tras el reenvío de un fichero | 684 983 kWh en lugar de 646 706 (**+5,9 %**). `uniqExact` sigue siendo correcto |
| Vistas materializadas refrescables | de 0,27 a 0,66 s cada una |
| KPI "99 % de los datos a las 9h" | media 98,4 %, 6 días por debajo del 99 % (de 89,7 a 94,7 %), los demás en ~99,65 % |
| Alertas de exceso de potencia | 257 en el mes, solo C4 (224) y C2 (33), +14,5 % de media |
| Contadores que subieron su potencia | 9 alertas antes del cambio, 3 después |
| Conciliación energía diaria / curva (31 M de puntos) | 237 ms. 97,6 % de los contador-día por debajo del 0,5 %, 1,9 % entre 0,5 y 3 %, 0,45 % por encima |
| Resumen del Área Urbana de Madrid, octubre | 10 846 MWh consumidos, 445 MWh producidos (4,1 %), 11 973 contadores |
| Las otras 5 áreas, octubre | Barcelona 2 140 MWh, Sevilla 1 759, Valencia 1 549, Málaga 968, Bilbao 753 |

Calibración del simulador (verificada sobre los 20 000 contadores y sobre el parque de 1 M):

| Indicador | Simulado | Referencia |
|---|---|---|
| Energía RES / PRO / ENT | 36 / 34,5 / 29,5 % | objetivo ~37 / 34 / 28 % |
| Fin de semana / laborable | 0,71 | objetivo ~0,7 |
| Hogar medio | 12,1 kWh/día | ~4,5 MWh/año |
| Sitio C4 / C2 | 490 kWh/día (carga 15 %) / 4,2 MWh/día (carga 23 %) | |
| Subida a lo largo de octubre | +12 % del 1 al 29 | arranca la calefacción |
| Punta | 19h, 1,95 kW por contador | punta de la tarde |

## 06 · Rendimiento (1 488 millones de puntos)
| Medida | Valor |
|---|---|
| Generación + escritura, 8 lotes de 186 M de puntos | de 7,7 a 8,4 s por lote, **64 s en total**, ~23 M puntos/s, de 1,1 a 1,2 GB de memoria por lote |
| Almacenamiento | 34,4 GB en bruto → 1,95 GB, **ratio ×17,6, 1,41 bytes por punto** |
| Por columna | `valor_w` 1,14 GB (×3), `id_contador` 8,6 MB (×806), `ts` 4,8 MB (×723), `magnitud` 2,4 MB (×364) |
| Un año de curvas para 3,5 M de contadores (61 mil M de puntos) | ~80 GB estimados |

| Consulta | Antes | Después | Filas leídas antes → después |
|---|---|---|---|
| Curva de un contador en el mes (índice primario) | | **de 5 a 55 ms** (264 ms en frío) | 16 384 de 1,488 mil M (2 gránulos de 181 405) |
| Energía por provincia (3 mil M de dictGet, escaneo completo) | 5,72 s | | 1,488 mil M, 16,6 GB leídos |
| Misma consulta, **3 réplicas** (`enable_parallel_replicas = 1`) | 5,72 s | **3,12 s** (×1,8) | 1,488 mil M (repartidas entre 3 réplicas) |
| Punta nacional, **proyección** | 2,54 s | **34 ms** (×75) | 1,488 mil M → 22 290 |
| Consumo de España por día, misma proyección | más de 1 s | **6 ms** | 1,488 mil M → 22 290 |
| Puntos > 100 kW, **índice de salto minmax** | 736 ms | **121 ms** (×6,1) | 1,488 mil M → 22,6 M (1,5 % de los gránulos) |
| Energía por provincia, **caché de consultas** | 5,25 s | **1 ms** | 1,488 mil M → 0 |

La punta nacional cae el 30/10 a las 19h: 1 947 MW para el millón de contadores. En la energía por provincia,
Madrid (138 GWh) y Barcelona (107 GWh) van muy por delante de Valencia (49 GWh).

| Operación sobre la tabla cargada (ejecución anterior, réplicas de 64 GB) | Duración | Consecuencia |
|---|---|---|
| `MATERIALIZE PROJECTION` (1 500 millones de filas) | 22 s | cabe en la consola, pero es una reescritura |
| `MATERIALIZE INDEX` (1 500 millones de filas) | **109 s** | supera el límite de 60 s de la consola → índice declarado en el DDL |

## 07 · Operación
| Medida | Valor |
|---|---|
| Reconstrucción de octubre desde bronze, deduplicada (argMax) | 30,9 M de filas en 8,2 s (12,5 GB de memoria) |
| Control antes de publicar | 199 ms sobre 62,8 M de filas, prod deduplicada = reconstrucción |
| `REPLACE PARTITION` (cambio atómico) | 219 ms |
| Refresco de `energia_municipio_dia` tras publicar | 1,27 s |
| `EXCHANGE TABLES` | 4 ms |
| `DELETE` ligero de un contador (RGPD) | 7,05 s |
| `ALTER UPDATE` puntual sobre un referencial de 1 M de filas | 1,03 s |

## 08 · Dashboards, API, Agents
| Medida | Valor |
|---|---|
| 5 paneles del dashboard, filtrados por entidad local (gold) | de 6 a 28 ms cada uno (ejecución anterior) |
| Curva del Área Urbana de Madrid del 15/10 | punta de 21,9 MW a las 19h, producción por encima de 3 MW a mediodía |
| Vista parametrizada para la API | 96 filas para un día de Madrid (48 medias horas, CONS y PROD). De 3 a 30 ms y ~8 200 filas leídas (ejecución anterior) |
| Documentación del esquema para el agente (COMMENT) | unos 75 ms por ALTER, solo metadatos |
| Resumen por área para el agente | Madrid 10 846 MWh, cobertura solar 4,1 %, 140 alertas. Sevilla tiene la mejor cobertura (5,5 %) |
| Preguntas y peticiones al agente | 2 preguntas, 6 dashboards, 3 ejercicios de data science, respuestas esperadas verificadas en el servicio (ver el [README del módulo 08](08_dashboards_agente/README.md)) |
