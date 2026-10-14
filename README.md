# ClickHouse from zero to advanced · Energy workshop

A 5-hour hands-on workshop on **your own ClickHouse Cloud service**: one day of smart meter data collection,
from JSON files to bronze, silver and gold, then dashboards, an API and an AI agent.
The meter data is simulated in SQL and deterministic. The geography is real, read live from official open data.

Choose your language. Each version uses the geography of its country; the steps, the pipeline and the
simulated fleet (1 million meters) are the same.

| | Language | Territory | Reference data, read with `url()` | Start here |
|---|---|---|---|---|
| FR | Français | France: 34 969 communes, EPCI, Métropole du Grand Paris | geo.api.gouv.fr | [fr/README.md](fr/README.md) |
| EN | English | England and Wales: 7,588 wards, combined authorities, Greater London | ONS Open Geography Portal, Nomis | [en/README.md](en/README.md) |
| ES | Español | España: 8 132 municipios, Grandes Áreas Urbanas, Madrid | INE, Ministerio de Transportes | [es/README.md](es/README.md) |

The three countries change their clocks on the same night (Sunday 25 October 2026, 01:00 UTC),
so the daylight saving module works the same way everywhere.

Quick start, from the folder of your language:

```bash
cd en    # or fr, es
export CH_HOST=xxxx.eu-central-1.aws.clickhouse.cloud
export CH_PASSWORD='...'
./run_all.sh
```

`data/fr`, `data/uk` and `data/es` hold a copy of each country's reference data,
used as a fallback if a public source does not respond.

---

**FR** · Un workshop pratique de 5 h sur votre propre service ClickHouse Cloud, avec la géographie française. Commencez par [fr/README.md](fr/README.md).

**ES** · Un taller práctico de 5 h en tu propio servicio ClickHouse Cloud, con la geografía de España. Empieza por [es/README.md](es/README.md).
