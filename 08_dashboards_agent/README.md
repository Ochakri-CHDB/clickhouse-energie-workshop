# Module 8 · Dashboards, API et ClickHouse Agents

Gold est prêt : petites tables, triées selon les filtres, rafraîchies toutes les 10 minutes. On les expose de trois façons, toutes depuis la console Cloud :

| Pour qui | Quoi | Où |
|---|---|---|
| L'exploitant, le chef de projet | Un dashboard de 5 tuiles, filtrable par collectivité et par jour | ce README, partie 1 |
| Le portail d'une collectivité | Une API HTTPS sans SQL côté client | `01_vue_parametree_api.sql` + partie 2 |
| Tout le monde | Un agent qui répond en français et construit des dashboards | `02_questions_agent.sql` + partie 3 |

Durée : 45 min. Avant de commencer, exécutez `01_vue_parametree_api.sql` et `02_questions_agent.sql` dans la console (Cmd+Entrée) : leurs checkpoints doivent afficher `OK`.

> Les libellés ci-dessous sont ceux de la console ClickHouse Cloud en octobre 2026. Dashboards et ClickHouse Agents sont en **bêta** : un libellé peut avoir bougé, le principe ne change pas.

---

## 1. Le dashboard « Énergie · Métropoles » (20 min)

5 tuiles, toutes filtrables dès leur création :

| # | Tuile | Type | Filtres |
|---|---|---|---|
| 1 | Courbe de charge, consommation et production | Line | collectivité, jour |
| 2 | Carte de chaleur du mois, jour × heure | Heatmap | collectivité |
| 3 | Énergie par jour | Stacked bar | collectivité |
| 4 | Top 10 des communes | Horizontal bar | collectivité |
| 5 | Alertes de dépassement de puissance | Table | collectivité |

Les filtres prennent des valeurs lisibles :
- **collectivite** : un morceau du nom, sans se soucier des majuscules. `Paris`, `Lyon`, `Lille`, `Toulouse`, `Bordeaux` ou `Nantes`.
- **jour** : une date d'octobre 2026 au format AAAA-MM-JJ, par exemple `2026-10-15`.

Comme les 5 tuiles utilisent les **mêmes noms de paramètres**, un seul filtre pilote tout le dashboard.

### Étape 1 · Créer le dashboard
1. Dans la barre latérale du service, cliquez sur **Dashboards**.
2. Cliquez sur **+ New Dashboard**.
3. Nommez-le `Énergie · Métropoles`. Le dashboard vide s'ouvre.

### Étape 2 · Ajouter une tuile (à répéter 5 fois)
1. En haut à droite, cliquez sur **+ New visualization**. Une tuile vide apparaît et le panneau **Edit element** s'ouvre à droite.
2. Onglet **General**, champ **Query** : choisissez **New query**. L'**Inline Editor** s'ouvre.
3. Collez la requête de la tuile (fiches ci-dessous).
4. À droite de l'éditeur, le panneau **Query Parameters** affiche les paramètres détectés. Saisissez les valeurs de test : `collectivite` = `Paris`, et pour la tuile 1 `jour` = `2026-10-15`.
5. Exécutez avec le bouton ▷, vérifiez le résultat, puis enregistrez avec l'icône **disquette**, sous le nom de la tuile.
6. **Visualization type** : choisissez le type indiqué sur la fiche.
7. Onglet **Data** : associez les colonnes aux axes comme indiqué sur la fiche.
8. Donnez un titre à la tuile et fermez le panneau (×). Redimensionnez la tuile par son coin en bas à droite, déplacez-la par la poignée en haut à gauche.

### Les 5 fiches

#### Tuile 1 · Courbe de charge du jour
Type **Line**. Axe X : `heure`. Séries Y : `conso_mw`, `prod_mw`.
```sql
SELECT
    toTimeZone(ts, 'Europe/Paris')                          AS heure,
    round(sumIf(puissance_kw, grandeur = 'CONS') / 1000, 2) AS conso_mw,
    round(sumIf(puissance_kw, grandeur = 'PROD') / 1000, 2) AS prod_mw
FROM gold.courbe_epci
WHERE code_epci IN (SELECT code_epci FROM ref.destinataire
                    WHERE positionCaseInsensitiveUTF8(nom, {collectivite:String}) > 0)
  AND ts >  toDateTime({jour:Date}, 'Europe/Paris')
  AND ts <= toDateTime({jour:Date} + 1, 'Europe/Paris')
GROUP BY heure
ORDER BY heure
```
À observer : la pointe du soir vers 19h (21,9 MW pour Paris le 15), la bosse solaire à midi, très en dessous.

#### Tuile 2 · Carte de chaleur du mois
Type **Heatmap**. Axe X : `heure`. Axe Y : `jour`. Valeur : `conso_mw`.
```sql
SELECT
    toDate(ts - 1, 'Europe/Paris')        AS jour,
    toHour(ts - 900, 'Europe/Paris')      AS heure,
    round(avg(puissance_kw) / 1000, 2)    AS conso_mw
FROM gold.courbe_epci
WHERE code_epci IN (SELECT code_epci FROM ref.destinataire
                    WHERE positionCaseInsensitiveUTF8(nom, {collectivite:String}) > 0)
  AND grandeur = 'CONS'
GROUP BY jour, heure
ORDER BY jour, heure
```
À observer : 31 lignes × 24 colonnes. La pointe du soir forme une bande chaque jour, les week-ends sont plus calmes en journée, et tout s'assombrit en fin de mois (le chauffage démarre). C'est la tuile la plus parlante du dashboard.

#### Tuile 3 · Énergie par jour
Type **Stacked bar**. Axe X : `jour`. Séries Y : `conso_mwh`, `prod_mwh`.
```sql
SELECT
    jour,
    round(conso_kwh / 1000, 1) AS conso_mwh,
    round(prod_kwh / 1000, 1)  AS prod_mwh
FROM gold.synthese_collectivite_jour
WHERE positionCaseInsensitiveUTF8(collectivite, {collectivite:String}) > 0
ORDER BY jour
```
À observer : les creux des week-ends, et la tendance qui monte au fil d'octobre.

#### Tuile 4 · Top 10 des communes
Type **Horizontal bar**. Catégorie : `commune`. Valeur : `conso_mwh`.
```sql
SELECT
    dictGet('ref.dict_commune', 'nom', code_insee) AS commune,
    round(sum(energie_kwh) / 1000, 1)              AS conso_mwh
FROM gold.energie_commune_jour
WHERE code_epci IN (SELECT code_epci FROM ref.destinataire
                    WHERE positionCaseInsensitiveUTF8(nom, {collectivite:String}) > 0)
  AND grandeur = 'CONS'
GROUP BY code_insee
ORDER BY conso_mwh DESC
LIMIT 10
```
À observer : la ville centre en tête, puis des communes qui accueillent un site industriel (C2). Le nom vient d'un dictionnaire, sans JOIN.

#### Tuile 5 · Alertes de dépassement de puissance
Type **Table**. Toutes les colonnes.
```sql
SELECT
    jour,
    commune,
    segment,
    kva_souscrit,
    round(pmax_va / 1000, 1) AS pmax_kva,
    depassement_pct
FROM gold.alertes_pmax
WHERE code_epci IN (SELECT code_epci FROM ref.destinataire
                    WHERE positionCaseInsensitiveUTF8(nom, {collectivite:String}) > 0)
ORDER BY jour DESC, depassement_pct DESC
```
À observer : uniquement des sites C4 et C2 (en C5, le disjoncteur du compteur coupe avant tout dépassement). 140 alertes en octobre pour le Grand Paris, 33 pour Lyon.

### Étape 3 · Brancher les filtres
1. Rouvrez chaque tuile : **trois points** (⋮) en haut à droite, puis **Edit**.
2. Dans les réglages de la visualisation, chaque paramètre de la requête (`collectivite`, `jour`) apparaît avec sa **source de valeur** (value source). Choisissez **filter**.
3. Faites-le sur les 5 tuiles.
4. Cliquez sur l'**entonnoir** dans la barre du haut : le panneau **Global filters** s'ouvre, avec un champ `collectivite` et un champ `jour`.

### Étape 4 · Jouer avec le dashboard
1. Dans **Global filters**, tapez `Paris` et `2026-10-15` : les 5 tuiles affichent le Grand Paris.
2. Remplacez par `Lyon`, puis `Toulouse` : tout le dashboard bascule.
3. Changez la date (`2026-10-25`, le jour du changement d'heure : 50 demi-heures) : seule la courbe de la tuile 1 change.

Chaque changement relance les 5 requêtes. Chacune répond en quelques millisecondes : derrière le nom tapé, elle retrouve le code du territoire dans `ref.destinataire`, puis filtre gold sur le début de sa clé de tri (`code_epci`).

Partage : bouton **Share** en haut. Un collègue doit aussi avoir accès aux **requêtes enregistrées** sous-jacentes.

Mesuré sur le service de test (3 × 64 Go), filtre `Paris` : 6 à 28 ms par tuile.

---

## 2. Le Query API endpoint pour le portail (15 min)

Le portail n'envoie que des paramètres. Le SQL reste dans ClickHouse, versionné avec le reste.

### Prérequis
- Une **clé API** ClickHouse Cloud (Organization → API Keys) avec le rôle d'organisation **Member** et l'accès service **Query Endpoints**.
- Un rôle **Admin** dans la console pour configurer l'endpoint.

### Créer l'endpoint
1. Nouvel onglet, collez (sans les `--`) la requête de l'étape 3 de `01_vue_parametree_api.sql` :
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
   - **rôle de base de données** : choisissez le rôle personnalisé `role_grand_paris` (module 7). Les row policies s'appliquent à travers la vue : ce portail ne verra jamais une autre métropole, quels que soient les paramètres envoyés ;
   - **CORS** : le domaine du portail.
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

Essayez `"id_destinataire": "488904"` avec le rôle `role_grand_paris` : réponse vide. La sécurité est dans la base, pas dans le portail.

Mesuré (même requête, client natif) : 3 à 30 ms, ~8 200 lignes lues pour une journée de courbe, 186 pour une semaine de synthèse.

---

## 3. ClickHouse Agents (15 min)

### Préparer le terrain
`02_questions_agent.sql`, étape 1, pose des `COMMENT` sur les tables et colonnes gold. C'est la première chose que lit un agent (règle `agent-discovery-schema`). Sans eux, il devine que `ts` est en heure locale, que `488903` est un code postal…

### Créer et configurer l'agent
1. Barre latérale du service : **ClickHouse agents**, puis **Launch ClickHouse agents**.
2. **+ Create New Agent**, puis remplissez :

| Champ | Valeur |
|---|---|
| Nom | `Assistant Énergie` |
| Description | `Répond aux questions métier et construit des dashboards sur la collecte d'octobre (base gold).` |
| **Model** | un modèle **Claude Sonnet** de la liste (celui proposé par défaut convient). Il faut un modèle capable d'appeler des outils et de produire des artifacts |
| Category | `General` |
| Instructions | onglet **Inline**, collez le texte ci-dessous |
| **Tools** | **+ Add**, puis ajoutez les trois : **ClickHouse** (connecté à votre service, 9 outils : lister les tables, exécuter du SQL…), **Artifacts** (pour construire les dashboards), **Run Code** (calculs et graphiques en Python) |
| Skills | **All** |
| Conversation starters | ajoutez les demandes D1, D2 et D3 de l'étape 3 de `02_questions_agent.sql` : elles apparaîtront comme boutons au démarrage d'une conversation |
| File context, Support contact | facultatifs |

Sans l'outil **ClickHouse**, l'agent ne voit pas vos données. Sans **Artifacts**, il répond en texte mais ne construit pas de dashboard.

Instructions à coller :
```
Tu es l'assistant data d'un gestionnaire de réseau de distribution d'électricité. Tu réponds
en français à des questions métier sur la collecte des données de comptage d'octobre 2026.
- Utilise UNIQUEMENT les tables de la base gold et ref.destinataire, via l'outil ClickHouse.
  Lis d'abord les commentaires des tables et des colonnes, et leur clé de tri.
- Filtre toujours sur le début de la clé de tri et ajoute un LIMIT.
- ts est en UTC et marque la FIN d'une demi-heure : convertis avec toTimeZone(ts, 'Europe/Paris').
- Les noms de communes et d'EPCI se lisent avec dictGet('ref.dict_commune', 'nom', code_insee)
  et dictGet('ref.dict_epci', 'nom', code_epci).
- Quand on te demande un dashboard, une page ou un rapport : interroge d'abord ClickHouse,
  puis construis un artifact interactif avec les VRAIES valeurs obtenues (jamais de données
  inventées), des titres en français, les unités (MW, MWh, %) et 2 ou 3 phrases d'analyse.
- Sinon, donne les chiffres clés avec leur unité, puis la requête SQL utilisée.
```

3. Enregistrez, ouvrez une conversation, choisissez l'agent (**Select**).

### Poser les 10 questions
Les questions sont dans `02_questions_agent.sql` (étape 2), chacune avec la requête attendue et le résultat attendu (commentaire `Résultat attendu`). Posez-les telles quelles, puis comparez.

Ce qui distingue une bonne réponse :
- les bons chiffres (le résultat de la requête attendue) ;
- un filtre sur la clé de tri et un `LIMIT` (règle `agent-query-safety`) ;
- les pièges évités : l'heure UTC (Q3), l'identifiant de collectivité à chercher (Q2), le total de compteurs à additionner sur les segments (Q4).

### Lui faire construire des dashboards (le moment fort)
L'étape 3 de `02_questions_agent.sql` contient 6 demandes (D1 à D6) : dashboard complet du Grand Paris, carte de chaleur, comparaison des 6 métropoles, rapport d'exploitation, sites qui dépassent, page pour un élu. L'agent interroge gold, puis construit la page en quelques dizaines de secondes.

Pour chaque demande :
1. Collez-la dans la conversation (ou cliquez le conversation starter).
2. Regardez les requêtes que l'agent exécute : il doit lire les commentaires, filtrer sur `code_epci` ou `id_destinataire`.
3. Comparez les chiffres de l'artifact au `Résultat attendu` du fichier.
4. Demandez une retouche dans la même conversation : « ajoute un filtre par métropole », « passe la courbe en aires empilées », « exporte en PDF ».

Commencez par **D2** (la carte de chaleur) puis **D1** (le dashboard complet) : ce sont les plus visuels.

### En production
Créez un rôle dédié à l'agent : lecture seule, gold uniquement, avec un profil de réglages qui borne chaque requête (exemple commenté à l'étape 4 de `02_questions_agent.sql`). Pendant le workshop, l'agent tourne avec vos droits.
