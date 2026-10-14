#!/usr/bin/env bash
# =====================================================================
#  Ejecuta todo el workshop de una vez en un servicio ClickHouse Cloud
#  (también sirve como "recuperación" completa para un participante).
#
#  Requisito previo: el cliente de ClickHouse
#      curl https://clickhouse.com/ | sh        # crea ./clickhouse
#
#  Uso:
#      export CH_HOST=xxxx.eu-central-1.aws.clickhouse.cloud
#      export CH_PASSWORD='...'                  # nunca en un fichero versionado
#      ./run_all.sh            # todo, desde cero (reset incluido)
#      ./run_all.sh 03_silver  # retomar a partir de un módulo (sin reset)
#      ./run_all.sh 05_gold/03 # o a partir de un fichero concreto
#      ./run_all.sh 01 04      # recuperación: del módulo 01 al módulo 04 incluido
# =====================================================================
set -euo pipefail

: "${CH_HOST:?Define CH_HOST}"
: "${CH_PASSWORD:?Define CH_PASSWORD}"
CH_USER="${CH_USER:-default}"
if [ -z "${CLICKHOUSE_BIN:-}" ]; then [ -x ./clickhouse ] && CLICKHOUSE_BIN=./clickhouse || CLICKHOUSE_BIN=clickhouse; fi
CLIENT="$CLICKHOUSE_BIN client --host $CH_HOST --secure --user $CH_USER --password $CH_PASSWORD"
DESDE="${1:-}"
HASTA="${2:-}"          # opcional: parar después de este módulo (recuperación "hasta")

FICHEROS=(
  reset.sql
  00_introduccion/01_primeros_pasos.sql
  01_fundamentos/01_configuracion_y_referenciales.sql
  02_bronze/01_simulador.sql
  02_bronze/02_ingesta_bronze.sql
  02_bronze/03_explorar_json.sql
  03_silver/01_tablas_y_vistas_materializadas.sql
  03_silver/02_backfill_y_flujo_continuo.sql
  03_silver/03_duplicados_y_correcciones.sql
  03_silver/04_cambio_de_hora.sql
  04_diccionarios/01_diccionarios.sql
  05_gold/01_mv_incremental_recogida.sql
  05_gold/02_vistas_refrescables.sql
  05_gold/03_kpi_9h_alertas_conciliacion.sql
  05_gold/04_formas_contadores.sql
  06_rendimiento/01_cambio_de_escala.sql
  06_rendimiento/02_consultas_y_optimizaciones.sql
  06_rendimiento/03_sql_avanzado.sql
  07_operacion/01_reproceso_y_publicacion_atomica.sql
  07_operacion/02_ttl_borrados_seguridad.sql
  07_operacion/03_observabilidad.sql
)
# El módulo 08 se hace en la consola, siguiendo 08_dashboards_agente/README.md

mkdir -p logs
iniciado=0; [ -z "$DESDE" ] && iniciado=1
for f in "${FICHEROS[@]}"; do
  if [ $iniciado -eq 0 ]; then
    [[ "$f" == "$DESDE"* ]] && iniciado=1 || continue
  fi
  [ "$f" == "reset.sql" ] && [ -n "$DESDE" ] && continue
  if [ -n "$HASTA" ] && [[ "$f" > "$HASTA" ]] && [[ "$f" != "$HASTA"* ]]; then break; fi
  echo "-> $f"
  t0=$(date +%s)
  if $CLIENT --multiquery --time --format PrettyCompactMonoBlock < "$f" > "logs/$(basename "$f" .sql).log" 2>&1; then
    echo "   OK en $(( $(date +%s) - t0 )) s"
  else
    echo "   ERROR, ver logs/$(basename "$f" .sql).log"
    tail -20 "logs/$(basename "$f" .sql).log"
    exit 1
  fi
done
echo "Terminado. Resultados detallados en ./logs/"
