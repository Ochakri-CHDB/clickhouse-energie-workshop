#!/usr/bin/env bash
# =====================================================================
#  Exécute tout le workshop d'un coup sur un service ClickHouse Cloud
#  (sert aussi de "rattrapage" complet pour un participant).
#
#  Prérequis : le client ClickHouse
#      curl https://clickhouse.com/ | sh        # crée ./clickhouse
#
#  Usage :
#      export CH_HOST=xxxx.eu-central-1.aws.clickhouse.cloud
#      export CH_PASSWORD='...'                  # jamais dans un fichier versionné
#      ./run_all.sh            # tout, depuis zéro (reset inclus)
#      ./run_all.sh 03_silver  # reprendre à partir d'un module (sans reset)
#      ./run_all.sh 05_gold/03 # ou à partir d'un fichier précis
#      ./run_all.sh 01 04      # rattrapage : du module 01 au module 04 inclus
# =====================================================================
set -euo pipefail

: "${CH_HOST:?Définissez CH_HOST}"
: "${CH_PASSWORD:?Définissez CH_PASSWORD}"
CH_USER="${CH_USER:-default}"
if [ -z "${CLICKHOUSE_BIN:-}" ]; then [ -x ./clickhouse ] && CLICKHOUSE_BIN=./clickhouse || CLICKHOUSE_BIN=clickhouse; fi
CLIENT="$CLICKHOUSE_BIN client --host $CH_HOST --secure --user $CH_USER --password $CH_PASSWORD"
DEPART="${1:-}"
FIN="${2:-}"          # facultatif : s'arrêter après ce module (rattrapage "jusqu'à")

FICHIERS=(
  reset.sql
  00_introduction/01_premiers_pas.sql
  01_fondamentaux/01_setup_et_referentiels.sql
  02_bronze/01_simulateur.sql
  02_bronze/02_ingestion_bronze.sql
  02_bronze/03_explorer_le_json.sql
  03_silver/01_tables_et_vues_materialisees.sql
  03_silver/02_backfill_et_flux_continu.sql
  03_silver/03_doublons_et_corrections.sql
  03_silver/04_changement_d_heure.sql
  04_dictionnaires/01_dictionnaires.sql
  05_gold/01_mv_incrementale_collecte.sql
  05_gold/02_vues_rafraichissables.sql
  05_gold/03_kpi_9h_alertes_reconciliation.sql
  06_performance/01_passage_a_l_echelle.sql
  06_performance/02_requetes_et_optimisations.sql
  06_performance/03_sql_avance.sql
  07_exploitation/01_rejeu_et_publication_atomique.sql
  07_exploitation/02_ttl_suppressions_securite.sql
  07_exploitation/03_observabilite.sql
  08_dashboards_agent/01_vue_parametree_api.sql
  08_dashboards_agent/02_questions_agent.sql
)

mkdir -p logs
demarre=0; [ -z "$DEPART" ] && demarre=1
for f in "${FICHIERS[@]}"; do
  if [ $demarre -eq 0 ]; then
    [[ "$f" == "$DEPART"* ]] && demarre=1 || continue
  fi
  [ "$f" == "reset.sql" ] && [ -n "$DEPART" ] && continue
  if [ -n "$FIN" ] && [[ "$f" > "$FIN" ]] && [[ "$f" != "$FIN"* ]]; then break; fi
  echo "-> $f"
  debut=$(date +%s)
  if $CLIENT --multiquery --time --format PrettyCompactMonoBlock < "$f" > "logs/$(basename "$f" .sql).log" 2>&1; then
    echo "   OK en $(( $(date +%s) - debut )) s"
  else
    echo "   ECHEC, voir logs/$(basename "$f" .sql).log"
    tail -20 "logs/$(basename "$f" .sql).log"
    exit 1
  fi
done
echo "Terminé. Résultats détaillés dans ./logs/"
