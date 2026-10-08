# Module 8 · Dashboards, API et ClickHouse Agents

Gold est prêt : petites tables, triées selon les filtres du front, rafraîchies toutes les 10 minutes. On les expose de trois façons, toutes depuis la console Cloud :

| Pour qui | Quoi | Fichier |
|---|---|---|
| L'exploitant, le chef de projet | Un dashboard de 5 tuiles | `01_tuiles_dashboard.sql` |
| Le portail d'une collectivité | Une API HTTPS sans SQL côté client | `02_vue_parametree_api.sql` |
| Tout le monde | Un agent qui répond en français | `03_questions_agent.sql` |

Durée : 40 min. Exécutez d'abord les 3 fichiers SQL dans la console (Cmd+Entrée) : tous les checkpoints doivent afficher `OK`.

> Les noms de boutons ci-dessous viennent de la documentation ClickHouse Cloud (octobre 2026). Dashboards et ClickHouse Agents sont en **bêta** : un libellé peut avoir bougé. Le principe ne change pas.

---

## 1. Le dashboard « Collectivité » (20 min)

### Enregistrer les requêtes
Pour chaque tuile de `01_tuiles_dashboard.sql` :
1. Nouvel onglet de requête, collez la requête de la tuile, exécutez-la.
2. **Save**, avec un nom parlant : `tuile_courbe_cons_prod`, `tuile_energie_jour`, `tuile_top_communes`, `tuile_kpi_9h`, `tuile_kpi_9h_tendance`, `tuile_alertes`.

### Créer le dashboard
1. Panneau **Dashboards** dans la barre latérale, puis **New Dashboard**. Nom : `Énergie · Grand Paris`.
2. Pour chaque tuile, ajoutez une visualisation, choisissez la requête enregistrée, puis le type et les axes :

| Tuile | Type | Axe X | Axe Y |
|---|---|---|---|
| Courbe CONS vs PROD | Line | `heure` | `conso_mw`, `prod_mw` |
| Énergie par jour | Bar | `jour` | `conso_mwh` (et `prod_mwh`) |
| Top communes | Bar horizontal ou Table | `commune` | `conso_mwh` |
| KPI 9h (chiffre) | Table | | `taux_dernier_jour_pct` |
| KPI 9h (tendance) | Line | `jour` | `taux_donnees_9h_pct`, `cible_pct` |
| Alertes du jour | Table | | toutes les colonnes |

### Le rendre interactif
Remplacez la valeur en dur par un paramètre de requête, puis réenregistrez :
```sql
WHERE code_epci = {code_epci:String}
  AND ts >  toDateTime({jour:Date}, 'Europe/Paris')
  AND ts <= toDateTime({jour:Date} + 1, 'Europe/Paris')
```
Le paramètre devient un filtre du dashboard. Avec **Global Filters** (ruban du haut), un seul filtre `code_epci` pilote toutes les tuiles. Valeurs à essayer : `200054781` (Grand Paris), `200046977` (Lyon), `243100518` (Toulouse).

Partage : un collègue doit avoir accès aux **requêtes enregistrées** sous-jacentes, pas seulement au dashboard.

Mesuré sur le service de test (3 × 64 Go) : chaque tuile répond en 2 à 30 ms et lit entre 31 et 16 384 lignes.

---

## 2. Le Query API endpoint pour le front (15 min)

Le front n'envoie que des paramètres. Le SQL reste dans ClickHouse, versionné avec le reste.

### Prérequis
- Une **clé API** ClickHouse Cloud (Organization → API Keys) avec le rôle d'organisation **Member** et l'accès service **Query Endpoints**.
- Un rôle **Admin** dans la console pour configurer l'endpoint.

### Créer l'endpoint
1. Nouvel onglet, collez (sans les `--`) la requête de l'étape 3 de `02_vue_parametree_api.sql` :
   ```sql
   SELECT *
   FROM gold.api_courbe_collectivite(
       id_destinataire = {id_destinataire:String},
       debut           = {debut:Date},
       fin             = {fin:Date})
   ```
2. La console détecte les 3 paramètres. Testez avec `488903`, `2026-10-15`, `2026-10-15`, puis **Save** (`api_courbe_collectivite`).
3. **Share**, puis **API Endpoint** :
   - clé API : celle créée plus haut ;
   - **rôle de base de données** : choisissez le rôle personnalisé `role_grand_paris` (module 7). Les row policies s'appliquent à travers la vue : ce front ne verra jamais une autre métropole, quels que soient les paramètres envoyés ;
   - **CORS** : le domaine du front.
4. Notez l'ID de l'endpoint affiché.

### L'appeler
```bash
curl -X POST "https://console-api.clickhouse.cloud/.api/query-endpoints/<ID>/run?format=JSONEachRow" \
  --user "<keyId>:<keySecret>" \
  -H "Content-Type: application/json" \
  -H "x-clickhouse-endpoint-version: 2" \
  -d '{"queryVariables": {"id_destinataire": "488903", "debut": "2026-10-15", "fin": "2026-10-15"}}'
```
La version 2 de l'endpoint accepte tous les formats ClickHouse et renvoie un flux NDJSON. Délai par défaut : 30 s (`request_timeout`).

Essayez `"id_destinataire": "488904"` avec le rôle `role_grand_paris` : réponse vide. La sécurité est dans la base, pas dans le front.

Mesuré (même requête, client natif) : 3 à 30 ms, ~8 200 lignes lues pour une journée de courbe, 186 pour une semaine de synthèse.

---

## 3. ClickHouse Agents (15 min)

### Préparer le terrain
`03_questions_agent.sql`, étape 1, pose des `COMMENT` sur les tables et colonnes gold. C'est la première chose que lit un agent (règle `agent-discovery-schema`). Sans eux, il devine que `ts` est en heure locale, que `488903` est un code postal…

### Créer l'agent
1. Barre latérale du service : **ClickHouse agents**, puis **Launch ClickHouse agents**.
2. **Create New Agent** :
   - **Name** : `Assistant Énergie`
   - **Description** : `Répond aux questions métier sur la collecte des compteurs d'octobre (base gold).`
   - **Instructions** (à coller) :
     ```
     Tu es l'assistant data d'un gestionnaire de réseau de distribution d'électricité. Tu réponds en français à des questions
     métier sur la collecte des données de comptage d'octobre 2026.
     - Utilise UNIQUEMENT les tables de la base gold et ref.destinataire. Lis d'abord les
       commentaires des tables et des colonnes, et leur clé de tri.
     - Filtre toujours sur le début de la clé de tri et ajoute un LIMIT.
     - ts est en UTC et marque la FIN d'une demi-heure : convertis avec
       toTimeZone(ts, 'Europe/Paris').
     - Les noms de communes et d'EPCI se lisent avec dictGet('ref.dict_commune', 'nom', code_insee)
       et dictGet('ref.dict_epci', 'nom', code_epci).
     - Donne les chiffres clés avec leur unité, puis la requête SQL utilisée.
     ```
   - **Model** : le modèle proposé par défaut.
3. Enregistrez, ouvrez une conversation, choisissez l'agent.

### Poser les 10 questions
Les questions sont dans `03_questions_agent.sql` (étape 2), chacune avec la requête attendue et le résultat attendu (commentaire `Résultat attendu`). Posez-les telles quelles, puis comparez.

Ce qui distingue une bonne réponse :
- les bons chiffres (le résultat de la requête attendue) ;
- un filtre sur la clé de tri et un `LIMIT` (règle `agent-query-safety`) ;
- les pièges évités : l'heure UTC (Q3), l'identifiant de collectivité à chercher (Q2), le total de compteurs à additionner sur les segments (Q4).


### En production
Créez un rôle dédié à l'agent : lecture seule, gold uniquement, avec un profil de réglages qui borne chaque requête (exemple commenté à l'étape 3 de `03_questions_agent.sql`). Pendant le workshop, l'agent tourne avec vos droits.
