# Resultados medidos · Workshop ClickHouse Energía

Medidas del 8 de octubre de 2026, ejecución completa desde cero (`./run_all.sh`, 3 min 30 en total) en el servicio de pruebas:
**ClickHouse Cloud 26.6, AWS eu-central-1, 3 réplicas de 64 GB (16 vCPU cada una)**, la configuración
recomendada a los participantes. Duraciones leídas en `system.query_log` (tiempo de servidor). Los datos son simulados
y deterministas: volúmenes, filas leídas y resultados son idénticos para cada participante.
Las mismas cifras aparecen como comentario (`Medido`) bajo cada instrucción de los ficheros SQL.

> Órdenes de magnitud para las slides
> - **1 500 millones** de puntos de curva generados y escritos en **67 s** (8 lotes de 8,2 a 8,7 s, ~22 M de puntos/s), **1,41 bytes por punto**
> - La curva de un contador en un mes: **16 384 filas leídas de 1 500 millones**, de 5 a 55 ms
> - **3 réplicas** sobre el mismo escaneo de 1 500 millones de filas: **5,8 s → 2,2 s**, sin cambiar el SQL
> - Una proyección: la punta nacional pasa de **1,3 s a 33 ms** (×39), **83 000 veces menos filas leídas**
> - El JSON bruto comprimido **×15**, las curvas tipadas **×18 a ×24**
> - Un panel de dashboard sobre gold: **de 2 a 30 ms**

---

## 00 · Primeros pasos
| Medida | Valor |
|---|---|
| 1 millón de medidas JSON generadas con un SELECT | 266 ms |
| 10 millones (variante propuesta, ejecución anterior) | 2,35 s, 569 MB de JSON |

## 01 · Fundamentos y datos de referencia
| Medida | Valor |
|---|---|
| Municipios leídos en directo de geo.api.gouv.fr | 34 969 municipios, 68,95 M de habitantes, cargados en 471 ms |
| Parque de contadores generado (ASOF JOIN sobre la población acumulada) | 1 000 000 en 532 ms |
| Reparto del parque | C5 98,7 % (RES 86,8 %, PRO 11,8 %), C4 1,1 %, C2 0,2 % |
| Potencia media | RES 8,8 kVA, PRO C5 19,8 kVA, C4 138 kVA, C2 754 kVA |
| Historial de potencias | 1 028 889 filas, 28 889 cambios en octubre, generado en 258 ms |
| Contadores de los ficheros JSON en el territorio de su destinatario | 20 000 / 20 000 (6 metrópolis) |
| Compresión de `ref.contador` | 26,9 MB → 7,1 MB (×3,8). `segmento` ×33 (LowCardinality), `codigo_insee` ×5,5 |
| Índice disperso: un contador por su clave / fuera de la clave | 8 192 filas leídas en 4 ms / 1 000 000 en 7 ms |

## 02 · Bronze
| Medida | Valor |
|---|---|
| Ficheros recibidos | 1 800 (600 CURVA, 600 ENERGIA, 600 PMAX) |
| JSON bruto | CURVA 1,40 GB, ENERGIA 171 MB, PMAX 145 MB, total 1,71 GB |
| En disco (ZSTD 3) | 116 MB, **ratio ×15** |
| 1.er día de CURVA (20 ficheros) | 697 ms |
| Generación + escritura de CURVA, 580 ficheros | 11,3 s (1,30 GB de JSON, 2,2 GB de memoria) |
| ENERGIA, 600 ficheros / PMAX, 600 ficheros | 3,5 s / 5,4 s |
| Explorar el JSON (JSONExtract, tipo JSON) | de 21 a 215 ms sobre 64 a 600 ficheros |

## 03 · Silver
| Medida | Valor |
|---|---|
| Backfill: puntos extraídos del JSON (3 ARRAY JOIN) | 29,9 M de puntos en 18,1 s (1,65 M puntos/s) |
| Rechazos / energía diaria / PMax | 8 754 en 2,7 s / 625 080 en 755 ms / 600 000 en 675 ms |
| Flujo continuo: 20 ficheros del 31/10, MV en cascada bronze → silver → gold | 996 328 puntos en 5,95 s |
| Compresión de `silver.curva_carga` | 1,06 GB → 45 MB, **ratio ×24, 1,52 bytes por punto** |
| Por columna | `valor_w` 39 MB (×3), `ts` 458 KB (×264, Delta), `id_contador` 473 KB (×511), `magnitud` 38 KB (×790) |
| Reenvío de un fichero y luego corrección | 48 puntos visibles con FINAL, se conserva la versión CORREGIDO |
| Cambio de hora del 25/10 | 50 puntos ese día, 48 los demás |

## 04 · Diccionarios
| Medida | Valor |
|---|---|
| Energía por departamento, 30 M de puntos | dictGet 271 ms (175 MB) · JOIN 282 ms (282 MB) |
| Control de calidad con dictHas sobre 31 M de puntos | 22 ms |
| Memoria de los diccionarios | dict_contador 87 MB (1 M de claves), dict_potencia_asof 345 MB, dict_municipio 28 MB |
| Búsqueda aproximada de "Rueil Malmaizon" | Rueil-Malmaison, distancia 0,23, en 9 ms |

## 05 · Gold
| Medida | Valor |
|---|---|
| Backfill del seguimiento de la recogida (AggregatingMergeTree) | 618 163 filas en 5,2 s (3,2 GB de memoria) |
| Trampa de la suma en una MV, tras el reenvío de un fichero | 684 983 kWh en lugar de 646 706 (**+5,9 %**). `uniqExact` sigue siendo correcto |
| Vistas materializadas refrescables | de 0,29 a 0,70 s cada una |
| KPI "99 % de los datos a las 9h" | media 98,4 %, 6 días por debajo del 99 % (de 89,7 a 94,7 %), los demás en ~99,65 % |
| Alertas de exceso de potencia | 257 en el mes, solo C4 (224) y C2 (33), +14,5 % de media |
| Contadores que subieron su potencia | 9 alertas antes del cambio, 3 después |
| Conciliación energía diaria / curva (31 M de puntos) | 235 ms. 97,6 % de los contador-día por debajo del 0,5 %, 1,9 % entre 0,5 y 3 %, 0,45 % por encima |
| Resumen Grand Paris, octubre | 10 846 MWh consumidos, 448 MWh producidos (4,1 %), 11 973 contadores |

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
| Generación + escritura, 8 lotes de 186 M de puntos | de 8,2 a 8,7 s por lote, **67 s en total**, ~22 M puntos/s, 1,1 GB de memoria por lote |
| Almacenamiento | 34,4 GB en bruto → 1,95 GB, **ratio ×17,6, 1,41 bytes por punto** |
| Por columna | `valor_w` 1,28 GB (×3), `id_contador` 9,7 MB (×806), `ts` 5,4 MB (×722), `magnitud` 2,5 MB (×387) |
| Un año de curvas para 3,5 M de contadores (61 mil M de puntos) | ~80 GB estimados |

| Consulta | Antes | Después | Filas leídas antes → después |
|---|---|---|---|
| Curva de un contador en el mes (índice primario) | | **de 5 a 55 ms** (250 ms en frío) | 16 384 de 1,488 mil M (2 gránulos de ~180 000) |
| Energía por departamento (3 mil M de dictGet, escaneo completo) | 5,77 s | | 1,488 mil M, 16,6 GB leídos |
| Misma consulta, **3 réplicas** (`enable_parallel_replicas = 1`) | 5,77 s | **2,17 s** (×2,7) | 1,488 mil M (repartidas entre 3 réplicas) |
| Punta nacional, **proyección** | 1,3 s | **33 ms** (×39) | 1,488 mil M → 17 835 |
| Consumo de Francia por día, misma proyección | ~1 s | **7 ms** | 1,488 mil M → 17 835 |
| Puntos > 100 kW, **índice de salto minmax** | 692 ms | **159 ms** (×4,4) | 1,488 mil M → 22,5 M (1,5 % de los gránulos) |
| Energía por departamento, **caché de consultas** | 4,93 s | **1 ms** | 1,488 mil M → 0 |

| Operación sobre la tabla cargada (ejecución anterior, réplicas de 64 GB) | Duración | Consecuencia |
|---|---|---|
| `MATERIALIZE PROJECTION` (1 500 millones de filas) | 22 s | cabe en la consola, pero es una reescritura |
| `MATERIALIZE INDEX` (1 500 millones de filas) | **109 s** | supera el límite de 60 s de la consola → índice declarado en el DDL |

## 07 · Operación
| Medida | Valor |
|---|---|
| Reconstrucción de octubre desde bronze, deduplicada (argMax) | 30,9 M de filas en 8,7 s (12,5 GB de memoria) |
| Control antes de publicar | 221 ms sobre 62,8 M de filas, prod deduplicada = reconstrucción |
| `REPLACE PARTITION` (cambio atómico) | 192 ms |
| `EXCHANGE TABLES` | 15 ms |
| `DELETE` ligero de un contador (RGPD) | 7,1 s |
| `ALTER UPDATE` puntual sobre un referencial de 1 M de filas | 1,0 s |

## 08 · Dashboards, API, Agents
| Medida | Valor |
|---|---|
| 5 paneles del dashboard, filtrados por entidad local (gold) | de 6 a 28 ms cada uno |
| Curva de Grand Paris del 15/10 | punta de 21,9 MW a las 19h, producción máxima 2,3 MW |
| Vista parametrizada para la API | de 3 a 30 ms, ~8 200 filas para un día, 186 para una semana de resumen |
| Documentación del esquema para el agente (COMMENT) | de 67 a 120 ms por tabla, solo metadatos |
| Preguntas y peticiones al agente | 2 preguntas, 6 dashboards, 3 ejercicios de data science, respuestas esperadas verificadas en el servicio (ver el [README del módulo 08](08_dashboards_agente/README.md)) |
