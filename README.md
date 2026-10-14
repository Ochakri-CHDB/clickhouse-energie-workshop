# ClickHouse from zero to advanced · Energy workshop

A 5-hour hands-on workshop on **your own ClickHouse Cloud service**: one day of smart meter data collection,
from JSON files to bronze, silver and gold, then dashboards, an API and an AI agent.
All data is simulated in SQL and deterministic: everyone gets the same numbers.

Choose your language. The three versions are identical: same steps, same data, same results.
Only the comments, the documentation and the names of tables and columns are translated.

| | Language | Start here |
|---|---|---|
| FR | Français | [fr/README.md](fr/README.md) |
| EN | English | [en/README.md](en/README.md) |
| ES | Español | [es/README.md](es/README.md) |

Quick start, from the folder of your language:

```bash
cd en    # or fr, es
export CH_HOST=xxxx.eu-central-1.aws.clickhouse.cloud
export CH_PASSWORD='...'
./run_all.sh
```

`data/` holds the reference files (municipalities, departments, regions, EPCI) shared by the three versions,
used as a fallback if the public geo API does not respond.

---

**FR** · Un workshop pratique de 5 h sur votre propre service ClickHouse Cloud. Commencez par [fr/README.md](fr/README.md).

**ES** · Un taller práctico de 5 h en tu propio servicio ClickHouse Cloud. Empieza por [es/README.md](es/README.md).
