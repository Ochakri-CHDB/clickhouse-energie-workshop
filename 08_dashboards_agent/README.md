# Module 8 · Dashboards, API et ClickHouse Agents

Gold est prêt : petites tables, triées selon les filtres, rafraîchies toutes les 10 minutes. On les expose de trois façons, toutes depuis la console Cloud :

| Pour qui | Quoi | Où |
|---|---|---|
| L'exploitant, le chef de projet | Un dashboard de 5 tuiles, filtrable par collectivité et par jour | ce README, partie 1 |
| Le portail d'une collectivité | Une API HTTPS sans SQL côté client | partie 2 |
| Tout le monde | Un agent qui répond en français et construit des dashboards | partie 3 |

Durée : 1 h. Tout se fait dans la console Cloud, en suivant les étapes ci-dessous : il n'y a pas de fichier SQL à exécuter dans ce module. Prérequis : les modules 00 à 07 ont tourné sur votre service.

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

Le portail n'envoie que des paramètres (une collectivité, deux dates). Le SQL reste dans ClickHouse. On transforme une requête enregistrée en adresse HTTPS appelable avec une clé API.

Légende : **[testé]** vérifié sur un service et un endpoint réels, **[console]** à faire dans l'interface.

### Étape 1 · Créer les deux vues de l'API [testé]
Une **vue paramétrée** est une requête enregistrée dans la base, avec des paramètres `{nom:Type}`. On l'appelle comme une table : `SELECT * FROM gold.api_courbe_collectivite(id_destinataire = '488903', …)`. Le portail ne verra jamais que ces paramètres.

Prérequis : les modules 00 à 07 ont tourné sur **ce même service** (les vues lisent les tables gold).

Dans la console SQL, collez ce bloc et exécutez tout (Cmd+Entrée) :
```sql
-- La courbe de charge d'une collectivité, entre deux dates
CREATE OR REPLACE VIEW gold.api_courbe_collectivite AS
SELECT
    toTimeZone(ts, 'Europe/Paris')   AS heure,
    grandeur,
    round(puissance_kw, 1)           AS puissance_kw,
    nb_prm
FROM gold.courbe_epci
WHERE code_epci IN (SELECT code_epci FROM ref.destinataire WHERE id_destinataire = {id_destinataire:String})
  AND ts >  toDateTime({debut:Date}, 'Europe/Paris')
  AND ts <= toDateTime({fin:Date} + 1, 'Europe/Paris')
ORDER BY grandeur, ts;

-- La synthèse jour par jour d'une collectivité
CREATE OR REPLACE VIEW gold.api_synthese_collectivite AS
SELECT
    jour,
    collectivite,
    round(conso_kwh / 1000, 2)        AS conso_mwh,
    round(prod_kwh / 1000, 2)         AS prod_mwh,
    round(100 * taux_couverture, 2)   AS couverture_pct,
    nb_prm
FROM gold.synthese_collectivite_jour
WHERE id_destinataire = {id_destinataire:String}
  AND jour BETWEEN {debut:Date} AND {fin:Date}
ORDER BY jour;

-- Le rôle du module 7 doit pouvoir lire le petit référentiel utilisé par la vue
GRANT SELECT ON ref.destinataire TO role_grand_paris;
```
Si la console ouvre un panneau **Query Variables**, laissez-le vide : les paramètres ne servent qu'à l'appel de la vue.

Vérifiez :
```sql
SELECT name FROM system.tables WHERE database = 'gold' AND name LIKE 'api_%';
```
Attendu : `api_courbe_collectivite` et `api_synthese_collectivite`.

Si vous voyez plus tard `Unknown table function gold.api_courbe_collectivite (UNKNOWN_FUNCTION)`, c'est que la vue n'existe pas sur le service où vous êtes : refaites cette étape sur ce service.

### Étape 2 · Récupérer les valeurs à passer [testé]
L'identifiant de chaque collectivité :
```sql
SELECT id_destinataire, nom FROM ref.destinataire ORDER BY id_destinataire;
```
| id_destinataire | nom |
|---|---|
| 488903 | Métropole du Grand Paris |
| 488904 | Métropole de Lyon |
| 488905 | Métropole Européenne de Lille |
| 488906 | Toulouse Métropole |
| 488907 | Bordeaux Métropole |
| 488908 | Nantes Métropole |

Les dates disponibles :
```sql
SELECT min(jour) AS premier_jour, max(jour) AS dernier_jour FROM gold.synthese_collectivite_jour;
```
Attendu : du `2026-10-01` au `2026-10-31`.

### Étape 3 · Écrire et tester la requête de l'endpoint [testé]
1. Nouvel onglet dans la console SQL. Collez :
   ```sql
   SELECT *
   FROM gold.api_courbe_collectivite(
       id_destinataire = {id_destinataire:String},
       debut           = {debut:Date},
       fin             = {fin:Date})
   ```
2. Le panneau **Query Variables** s'ouvre à droite avec trois champs. Saisissez `488903`, `2026-10-15`, `2026-10-15`.
3. Exécutez (Cmd+Entrée). Attendu : **96 lignes** (48 demi-heures × CONS et PROD), pointe à ~21,9 MW vers 19h.
4. Cliquez sur **Save** et nommez la requête `api_courbe_collectivite`.

### Étape 4 · Créer la clé API [testé]
1. Dans le menu de gauche de l'organisation, ouvrez **API Keys**, puis cliquez sur **New API Key**.
2. Nom : `portail-collectivites`. Rôle d'organisation : **Member**. Accès au service : **Query Endpoints** sur votre service. Choisissez une date d'expiration.
3. Facultatif : dans **Allow access to this API Key**, limitez aux adresses IP du portail.
4. Cliquez sur **Generate API Key**. L'écran suivant affiche le **Key ID** et le **Key secret** : copiez-les tout de suite dans un coffre de mots de passe. Ils ne seront plus jamais affichés.

### Étape 5 · Créer l'endpoint [testé]
1. Rouvrez la requête enregistrée `api_courbe_collectivite`.
2. Cliquez sur **Share**, puis **API Endpoint**.
3. Choisissez la clé API de l'étape 4.
4. Choisissez le **rôle de base de données** qui exécutera la requête : **Read only**, ou le rôle `role_grand_paris` du module 7 pour que l'endpoint ne voie que le Grand Paris.
5. **CORS** : le domaine du portail (laissez vide pour un test en ligne de commande).
6. Validez. La console affiche l'**adresse d'appel**, de la forme `https://queries.clickhouse.cloud/run/<identifiant>`. Copiez-la.

### Étape 6 · Appeler l'endpoint [testé]
Dans un terminal, mettez les valeurs dans des variables (jamais dans un fichier versionné) :
```bash
export KEY_ID='<Key ID de l étape 4>'
export KEY_SECRET='<Key secret de l étape 4>'
export ENDPOINT='https://queries.clickhouse.cloud/run/<identifiant de l étape 5>'
```
Appel en GET, les paramètres dans l'adresse :
```bash
curl -s --user "$KEY_ID:$KEY_SECRET" \
  "$ENDPOINT?format=JSONEachRow&param_id_destinataire=488903&param_debut=2026-10-15&param_fin=2026-10-15"
```
Appel en POST, les paramètres dans le corps :
```bash
curl -s --user "$KEY_ID:$KEY_SECRET" -X POST -H "Content-Type: application/json" \
  "$ENDPOINT?format=JSONEachRow" \
  -d '{"queryVariables": {"id_destinataire": "488903", "debut": "2026-10-15", "fin": "2026-10-15"}}'
```

Résultats obtenus sur un endpoint réel :

| Appel | Résultat |
|---|---|
| GET ou POST, Grand Paris (`488903`), le 15 octobre | HTTP 200, **96 lignes** (48 demi-heures × CONS et PROD), ~1 s |
| GET, Grand Paris, du 13 au 19 octobre | HTTP 200, **672 lignes** (7 jours × 96) |
| GET ou POST, Lyon (`488904`), endpoint créé avec le rôle `role_grand_paris` | HTTP 200, **0 ligne** : la row policy cache tout ce qui n'est pas le Grand Paris |

Pièges rencontrés :
- **`401 Unauthorized`** (et `Key is not found` sur l'API Cloud) : la clé est mal copiée. Le Key secret commence par `4b1d` : vérifiez que ce début n'a pas sauté au copier-coller. Pour tester la clé seule : `curl --user "$KEY_ID:$KEY_SECRET" https://api.clickhouse.cloud/v1/organizations` doit renvoyer votre organisation.
- **Pas d'espace ni de caractère en trop dans l'adresse** : `param_id_destinataire=488903`, et non `param_id_destinataire= 488903` ; `param_fin=2026-10-15`, et non `param_fin=<2026-10-15`. Les `<…>` des exemples sont à remplacer en entier.
- `404` : l'identifiant de l'endpoint est faux. `400` : un paramètre est mal formé (date au format AAAA-MM-JJ).

### Étape 7 · Voir les appels côté serveur [testé]
Chaque endpoint s'exécute sous un utilisateur dédié nommé `queryEndpoint:<identifiant>` :
```sql
SYSTEM FLUSH LOGS;
SELECT event_time, user, round(query_duration_ms) AS ms, read_rows
FROM clusterAllReplicas('default', system.query_log)
WHERE type = 'QueryFinish' AND user LIKE 'queryEndpoint:%' AND event_date = today()
ORDER BY event_time DESC
LIMIT 10;
```
À observer : quelques millisecondes et ~8 200 lignes lues par appel.

### Plan B · Tester sans clé API, en HTTPS direct [testé]
Pour vérifier la requête avant d'avoir une clé, l'interface HTTPS du service accepte les mêmes paramètres (`param_<nom>`). C'est un test : ne mettez jamais le mot de passe `default` dans un portail.
```bash
curl --user "default:$CH_PASSWORD" \
  "https://$CH_HOST:8443/?param_id_destinataire=488903&param_debut=2026-10-15&param_fin=2026-10-15&default_format=JSONEachRow" \
  --data-binary "SELECT * FROM gold.api_courbe_collectivite(id_destinataire = {id_destinataire:String}, debut = {debut:Date}, fin = {fin:Date}) LIMIT 3"
```

Mesuré (même requête, client natif et HTTPS direct) : 3 à 30 ms, ~8 200 lignes lues pour une journée de courbe.

---

## 3. ClickHouse Agents (35 min)

Un agent ne devine pas le métier : il lit le schéma. On documente donc gold, on crée l'agent avec les bons outils, puis on lui pose 10 questions, on lui fait construire 6 dashboards et on lui confie 3 exercices de data science.

### Étape 1 · Documenter gold pour l'agent [testé]
Un agent commence par lire les tables, leurs colonnes et leurs **commentaires** (règle `agent-discovery-schema`). Sans commentaires, il devine que `ts` est en heure locale ou que `488903` est un code postal. Ces commandes ne touchent que les métadonnées : instantané, aucune donnée réécrite.

Dans la console SQL, collez ce bloc et exécutez tout (Cmd+Entrée) :
```sql
ALTER TABLE gold.synthese_collectivite_jour
    MODIFY COMMENT 'Synthèse quotidienne par collectivité destinataire des flux de comptage (6 métropoles). Une ligne par collectivité et par jour d''octobre 2026. Énergies en kWh.';
ALTER TABLE gold.synthese_collectivite_jour
    COMMENT COLUMN id_destinataire 'Identifiant du destinataire (488903 = Métropole du Grand Paris, voir ref.destinataire)',
    COMMENT COLUMN jour            'Journée locale (Europe/Paris)',
    COMMENT COLUMN conso_kwh       'Énergie consommée sur le territoire ce jour, en kWh',
    COMMENT COLUMN prod_kwh        'Énergie produite (photovoltaïque) sur le territoire ce jour, en kWh',
    COMMENT COLUMN taux_couverture 'prod_kwh / conso_kwh, entre 0 et 1',
    COMMENT COLUMN nb_prm          'Nombre de compteurs (PRM) ayant remonté une courbe ce jour';

ALTER TABLE gold.courbe_epci
    MODIFY COMMENT 'Courbe de charge agrégée par EPCI, pas 30 min. ts = FIN de l''intervalle, en UTC : convertir avec toTimeZone(ts, ''Europe/Paris''). Filtrer sur code_epci puis ts (clé de tri).';
ALTER TABLE gold.courbe_epci
    COMMENT COLUMN code_epci    'Code SIREN de l''EPCI (200054781 = Métropole du Grand Paris). Libellé : dictGet(''ref.dict_epci'', ''nom'', code_epci)',
    COMMENT COLUMN grandeur     'CONS = consommation, PROD = production',
    COMMENT COLUMN ts           'Fin de l''intervalle de 30 min, UTC',
    COMMENT COLUMN puissance_kw 'Puissance moyenne sur l''intervalle, somme des compteurs, en kW',
    COMMENT COLUMN nb_prm       'Nombre de points (compteurs) agrégés';

ALTER TABLE gold.energie_commune_jour
    MODIFY COMMENT 'Énergie par commune, jour, segment (C5, C4, C2) et grandeur (CONS, PROD). Libellé de commune : dictGet(''ref.dict_commune'', ''nom'', code_insee).';
ALTER TABLE gold.energie_commune_jour
    COMMENT COLUMN segment     'C5 = particuliers et petits pros (≤ 36 kVA), C4 = PME/tertiaire (36 à 250 kVA), C2 = industriels HTA',
    COMMENT COLUMN energie_kwh 'Énergie du jour en kWh',
    COMMENT COLUMN nb_prm      'Compteurs de ce segment dans la commune ce jour (additionner les segments pour le total)';

ALTER TABLE gold.alertes_pmax
    MODIFY COMMENT 'Dépassements de puissance souscrite (flux PMAX). Une ligne par compteur et par jour en dépassement. Seuls les C4 et C2 peuvent dépasser (en C5 le disjoncteur coupe).';
ALTER TABLE gold.alertes_pmax
    COMMENT COLUMN kva_souscrit    'Puissance souscrite EN VIGUEUR ce jour-là, en kVA',
    COMMENT COLUMN pmax_va         'Puissance maximale atteinte dans la journée, en VA',
    COMMENT COLUMN depassement_pct 'Dépassement en % de la puissance souscrite',
    COMMENT COLUMN heure_pointe    'Instant de la pointe, heure de Paris';

ALTER TABLE gold.kpi_completude_jour
    MODIFY COMMENT 'Complétude de la collecte des courbes CDC à 9h le lendemain. Cible : taux_donnees_9h_pct >= 99.';
ALTER TABLE gold.kpi_completude_jour
    COMMENT COLUMN taux_donnees_9h_pct      'Points reçus avant 9h / points attendus, en %. C''est le KPI contractuel',
    COMMENT COLUMN taux_prm_complets_9h_pct 'Part des compteurs dont la journée est complète à 9h, en %';
```

Vérifiez :
```sql
SELECT name, comment FROM system.tables WHERE database = 'gold' AND comment != '' ORDER BY name;
```
Attendu : 5 tables commentées (`alertes_pmax`, `courbe_epci`, `energie_commune_jour`, `kpi_completude_jour`, `synthese_collectivite_jour`).

### Étape 2 · Créer et configurer l'agent [console]
1. Dans la barre latérale du service, cliquez sur **ClickHouse agents**, puis **Launch ClickHouse agents**.
2. Cliquez sur **+ Create New Agent** et remplissez :

| Champ | Valeur |
|---|---|
| Nom | `Assistant Énergie` |
| Description | `Répond aux questions métier et construit des dashboards sur la collecte d'octobre (base gold).` |
| **Model** | un modèle **Claude Sonnet** de la liste (celui proposé par défaut convient). Il faut un modèle capable d'appeler des outils et de produire des artifacts |
| Category | `General` |
| Instructions | onglet **Inline**, collez le texte ci-dessous |
| **Tools** | **+ Add**, puis ajoutez les trois : **ClickHouse** (connecté à votre service, 9 outils : lister les tables, exécuter du SQL…), **Artifacts** (pour construire les dashboards), **Run Code** (calculs et graphiques en Python) |
| Skills | **All** |
| Conversation starters | ajoutez les demandes D1, D2 et D3 de l'étape 5 ci-dessous : elles apparaîtront comme boutons au démarrage d'une conversation |
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

### Étape 3 · Ouvrir une conversation [console]
1. Enregistrez l'agent.
2. En haut de la page, choisissez `Assistant Énergie` dans la liste, puis cliquez sur **Select**.
3. Une conversation s'ouvre. Les conversation starters apparaissent comme boutons.

### Étape 4 · Poser les 10 questions
Copiez chaque question telle quelle dans la conversation. Comparez la réponse au résultat attendu. La requête de vérification (dépliez-la) donne le vrai chiffre si vous voulez le recalculer dans la console SQL.

Ce qui distingue une bonne réponse :
- les bons chiffres ;
- un filtre sur la clé de tri et un `LIMIT` (règle `agent-query-safety`) ;
- les pièges évités : l'heure UTC (Q3), l'identifiant de collectivité à chercher (Q2), le total de compteurs à additionner sur les segments (Q4).

**Q1** · "Combien la Métropole du Grand Paris a-t-elle consommé en octobre, et quelle part a été couverte par la production solaire locale ?"

Attendu : ~10 850 MWh consommés, ~450 MWh produits, couverture ~4,1 %.

<details><summary>Requête de vérification</summary>

```sql
SELECT round(sum(conso_kwh) / 1000) AS conso_mwh,
       round(sum(prod_kwh) / 1000)  AS prod_mwh,
       round(100 * sum(prod_kwh) / sum(conso_kwh), 1) AS couverture_pct
FROM gold.synthese_collectivite_jour
WHERE id_destinataire = '488903';
```
</details>

**Q2** · "Quel jour d'octobre la Métropole de Lyon a-t-elle le plus consommé ?"

Attendu : le 30 octobre, ~80 MWh. Piège : l'agent doit trouver l'id 488904 dans ref.destinataire.

<details><summary>Requête de vérification</summary>

```sql
SELECT jour, round(conso_kwh / 1000, 1) AS conso_mwh
FROM gold.synthese_collectivite_jour
WHERE id_destinataire = (SELECT id_destinataire FROM ref.destinataire WHERE nom = 'Métropole de Lyon')
ORDER BY conso_kwh DESC
LIMIT 1;
```
</details>

**Q3** · "À quelle heure était la pointe de consommation du Grand Paris le 15 octobre, et combien de MW ?"

Attendu : 19h00 (heure de Paris), ~21,9 MW. Piège : ts est en UTC et marque la FIN de la demi-heure.

<details><summary>Requête de vérification</summary>

```sql
SELECT toTimeZone(ts, 'Europe/Paris') AS heure, round(puissance_kw / 1000, 2) AS mw
FROM gold.courbe_epci
WHERE code_epci = '200054781' AND grandeur = 'CONS'
  AND ts > toDateTime('2026-10-15', 'Europe/Paris') AND ts <= toDateTime('2026-10-16', 'Europe/Paris')
ORDER BY puissance_kw DESC
LIMIT 1;
```
</details>

**Q4** · "Quelles sont les 5 communes du Grand Paris qui consomment le plus par compteur ?"

Attendu : Pantin (~223 kWh/compteur/jour), Morangis, Fresnes, Gagny, Bourg-la-Reine. Bonne réponse : l'agent explique que ce sont des communes avec un site industriel (C2).

<details><summary>Requête de vérification</summary>

```sql
SELECT dictGet('ref.dict_commune', 'nom', code_insee) AS commune,
       round(sum(energie_kwh) / sum(nb_prm), 1)       AS kwh_par_compteur_et_par_jour,
       round(sum(nb_prm) / uniqExact(jour))           AS nb_compteurs
FROM gold.energie_commune_jour
WHERE code_epci = '200054781' AND grandeur = 'CONS'
GROUP BY code_insee
HAVING nb_compteurs >= 20                              -- on écarte les communes trop petites
ORDER BY kwh_par_compteur_et_par_jour DESC
LIMIT 5;
```
</details>

**Q5** · "Combien d'alertes de dépassement de puissance le 30 octobre, et sur quels sites ?"

Attendu : 6 alertes, toutes en C4 ; la pire à Paris (+25 %).

<details><summary>Requête de vérification</summary>

```sql
SELECT dictGet('ref.dict_epci', 'nom', code_epci) AS epci, commune, segment, id_prm,
       kva_souscrit, round(pmax_va / 1000, 1) AS pmax_kva, depassement_pct
FROM gold.alertes_pmax
WHERE jour = '2026-10-30'
ORDER BY depassement_pct DESC
LIMIT 50;
```
</details>

**Q6** · "Quels jours le KPI des 99 % à 9h n'a-t-il pas été atteint ?"

Attendu : 6 jours (10, 16, 19, 22, 25 et 27 octobre), entre 89,7 et 94,7 %. Relance attendue : "Pourquoi ?" → les fichiers arrivés après 9h 1 ou 2 fichiers (lots de 1000 compteurs) arrivés à 14h le lendemain.

<details><summary>Requête de vérification</summary>

```sql
SELECT jour, taux_donnees_9h_pct
FROM gold.kpi_completude_jour
WHERE taux_donnees_9h_pct < 99
ORDER BY jour;
SELECT toDate(ingested_at, 'Europe/Paris') - 1 AS jour, count() AS fichiers_en_retard,
       min(toTimeZone(ingested_at, 'Europe/Paris')) AS premiere_arrivee
FROM bronze.flux_raw
WHERE code_flux = 'CDC' AND toHour(ingested_at, 'Europe/Paris') >= 9
  AND file_name NOT LIKE '%RENVOI%' AND file_name NOT LIKE '%CORRECTION%'
GROUP BY jour
ORDER BY jour;
```
</details>

**Q7** · "Classe les métropoles de la plus solaire à la moins solaire."

Attendu : Toulouse et Nantes en tête (~5,3 %), Lyon dernière (~3,4 %).

<details><summary>Requête de vérification</summary>

```sql
SELECT collectivite, round(100 * sum(prod_kwh) / sum(conso_kwh), 1) AS couverture_pct
FROM gold.synthese_collectivite_jour
GROUP BY collectivite
ORDER BY couverture_pct DESC;
```
</details>

**Q8** · "De combien la consommation de Toulouse baisse-t-elle le week-end ?"

Attendu : ~0,71, soit environ 29 % de moins le week-end.

<details><summary>Requête de vérification</summary>

```sql
SELECT round(avgIf(conso_kwh, toDayOfWeek(jour) >= 6) / avgIf(conso_kwh, toDayOfWeek(jour) <= 5), 2) AS ratio_weekend_semaine
FROM gold.synthese_collectivite_jour
WHERE id_destinataire = '488906';
```
</details>

**Q9** · "Quelle part de la consommation vient des particuliers et petits pros (C5), des PME (C4) et des industriels (C2), métropole par métropole ?"

Attendu : les C5 entre 43 et 62 %. La part C2 varie beaucoup (6 à 39 %) : quelques gros sites suffisent.

<details><summary>Requête de vérification</summary>

```sql
SELECT dictGet('ref.dict_epci', 'nom', code_epci) AS epci,
       round(100 * sumIf(energie_kwh, segment = 'C5') / sum(energie_kwh), 1) AS c5_pct,
       round(100 * sumIf(energie_kwh, segment = 'C4') / sum(energie_kwh), 1) AS c4_pct,
       round(100 * sumIf(energie_kwh, segment = 'C2') / sum(energie_kwh), 1) AS c2_pct
FROM gold.energie_commune_jour
WHERE grandeur = 'CONS'
GROUP BY epci
ORDER BY epci;
```
</details>

**Q10** · "Quels compteurs ont une énergie journalière qui ne colle pas à leur courbe CDC (écart > 3 %) ?"

Attendu : Question plus difficile : la réponse est dans une vue (gold.v_reconciliation), pas une table. des écarts de 7 à 8 % avec 46 points au lieu de 48. Bonne réponse : l'agent relie l'écart aux points manquants de la courbe (l'énergie journalière vient des index, il est complet).

<details><summary>Requête de vérification</summary>

```sql
SELECT jour, id_prm, energie_jour_kwh, round(energie_courbe_kwh, 2) AS energie_courbe_kwh, nb_points, ecart_pct
FROM gold.v_reconciliation
WHERE abs(ecart_pct) > 3
ORDER BY abs(ecart_pct) DESC
LIMIT 20;
```
</details>

### Étape 5 · Lui faire construire des dashboards (le moment fort)
Avec les outils **ClickHouse** et **Artifacts**, l'agent ne se contente plus de répondre : il interroge gold, puis construit une page interactive avec graphiques et chiffres clés, en quelques dizaines de secondes.

Pour chaque demande :
1. Collez-la dans la conversation (ou cliquez le conversation starter).
2. Regardez les requêtes que l'agent exécute : il doit lire les commentaires, puis filtrer sur `code_epci` ou `id_destinataire`.
3. Comparez les chiffres de la page au résultat attendu.
4. Demandez une retouche dans la même conversation : « ajoute un filtre par métropole », « passe la courbe en aires empilées », « exporte en PDF ».

Commencez par **D2** (la carte de chaleur) puis **D1** (le dashboard complet) : ce sont les plus visuels.

Une bonne page : des données réelles (jamais inventées), des unités (MW, MWh, %), des titres en français, et quelques lignes d'analyse sous les graphiques.

**D1** · "Construis un dashboard interactif de la Métropole du Grand Paris pour octobre 2026 : la courbe de charge du 15 octobre (consommation et production), l'énergie jour par jour, le top 10 des communes, le KPI de complétude à 9h et les alertes du dernier jour. Ajoute 3 chiffres clés en haut de page."

Attendu : 5 graphiques et 3 chiffres clés (~10 846 MWh, ~4,1 % de couverture, 98,4 % de KPI moyen). Pour l'essentiel, ce sont les requêtes des tuiles du README de ce dossier.

<details><summary>Requête de vérification</summary>

```sql
SELECT round(sum(conso_kwh) / 1000) AS conso_mwh, round(100 * sum(prod_kwh) / sum(conso_kwh), 1) AS couverture_pct
FROM gold.synthese_collectivite_jour
WHERE id_destinataire = '488903';
```
</details>

**D2** · "Fais une carte de chaleur jour × heure de la consommation du Grand Paris en octobre, puis explique en 3 phrases ce qu'elle montre."

Attendu : 31 lignes × 24 colonnes, de ~8 à ~23 MW. L'analyse doit citer la pointe du soir (19h-20h), les week-ends plus calmes en journée, la hausse en fin de mois.

<details><summary>Requête de vérification</summary>

```sql
SELECT toDate(ts - 1, 'Europe/Paris') AS jour, toHour(ts - 900, 'Europe/Paris') AS heure,
       round(avg(puissance_kw) / 1000, 2) AS conso_mw
FROM gold.courbe_epci
WHERE code_epci = '200054781' AND grandeur = 'CONS'
GROUP BY jour, heure
ORDER BY jour, heure;
```
</details>

**D3** · "Compare les 6 métropoles sur une seule page : consommation, production solaire, taux de couverture et nombre d'alertes du mois. Mets en évidence la plus solaire."

Attendu : un tableau classé et un graphique. Toulouse et Nantes en tête (~5,3 % de couverture), Grand Paris de loin le plus gros consommateur (~10 846 MWh) et le plus d'alertes (140 sur les 257 du mois).

<details><summary>Requête de vérification</summary>

```sql
SELECT s.collectivite,
       round(sum(s.conso_kwh) / 1000)                    AS conso_mwh,
       round(sum(s.prod_kwh) / 1000)                     AS prod_mwh,
       round(100 * sum(s.prod_kwh) / sum(s.conso_kwh), 1) AS couverture_pct,
       any(a.alertes)                                    AS alertes
FROM gold.synthese_collectivite_jour AS s
INNER JOIN ref.destinataire AS d ON d.id_destinataire = s.id_destinataire
LEFT JOIN (SELECT code_epci, count() AS alertes FROM gold.alertes_pmax GROUP BY code_epci) AS a ON a.code_epci = d.code_epci
GROUP BY s.collectivite
ORDER BY couverture_pct DESC;
```
</details>

**D4** · "Prépare le rapport d'exploitation du 30 octobre pour le chef d'équipe : complétude à 9h, fichiers arrivés en retard ce mois-ci, alertes de dépassement du jour, et 3 recommandations. Présente-le comme une page à imprimer."

Attendu : KPI du 30 au-dessus de 99 %, les 6 jours sous la cible avec leurs fichiers en retard (arrivés à 14h), 6 alertes C4 le 30, et des recommandations concrètes (relancer les lots en retard, contacter les sites qui dépassent).

<details><summary>Requête de vérification</summary>

```sql
SELECT jour, taux_donnees_9h_pct FROM gold.kpi_completude_jour WHERE taux_donnees_9h_pct < 99 OR jour = '2026-10-30' ORDER BY jour;
```
</details>

**D5** · "Quels sites dépassent régulièrement leur puissance souscrite ? Montre-les sur un graphique (dépassement moyen et nombre de jours) et dis lesquels devraient augmenter leur puissance."

Attendu : une vingtaine de sites, presque tous C4, avec 3 ou 4 jours de dépassement (Lyon, Vanves, Saint-Maurice et Paris en tête avec 4 jours). Bonne réponse : l'agent rappelle qu'en C5 le disjoncteur coupe avant tout dépassement.

<details><summary>Requête de vérification</summary>

```sql
SELECT id_prm, any(commune) AS commune, any(segment) AS segment, count() AS jours_depassement,
       round(avg(depassement_pct), 1) AS depassement_moyen_pct, max(kva_souscrit) AS kva_souscrit
FROM gold.alertes_pmax
GROUP BY id_prm
HAVING jours_depassement >= 2
ORDER BY jours_depassement DESC, depassement_moyen_pct DESC
LIMIT 20;
```
</details>

**D6** · "Fais une page pour un élu de Lyon : 4 chiffres clés du mois, la courbe d'une journée type de semaine et d'une journée de week-end, le tout lisible par un non-spécialiste."

Attendu : chiffres de la Métropole de Lyon (~2 140 MWh, ~3,4 % solaire), deux courbes comparées (le week-end plus bas en journée), et un texte sans jargon.

<details><summary>Requête de vérification</summary>

```sql
SELECT if(toDayOfWeek(toDate(ts - 1, 'Europe/Paris')) >= 6, 'week-end', 'semaine') AS type_jour,
       toHour(ts - 900, 'Europe/Paris') AS heure,
       round(avg(puissance_kw) / 1000, 2) AS conso_mw
FROM gold.courbe_epci
WHERE code_epci = '200046977' AND grandeur = 'CONS'
GROUP BY type_jour, heure
ORDER BY type_jour, heure;
```
</details>

### Étape 6 · Data science : prévoir et reconstituer des courbes avec Run Code
L'outil **Run Code** donne à l'agent un vrai Python (pandas, scikit-learn) dans un bac à sable. La répartition des rôles est le bon réflexe de data scientist sur ClickHouse :
- **ClickHouse prépare les données** : agrégats, formes de consommation, échantillons. C'est rapide et ça réduit le volume ;
- **Python entraîne le modèle** sur quelques centaines ou milliers de lignes seulement.

Vérifiez d'abord que l'outil **Run Code** est bien dans la liste des outils de l'agent (étape 2).

**6.1 · Préparer les formes de consommation dans gold [testé]**
Pour les exemples 2 et 3, chaque compteur est résumé par sa forme moyenne : 24 valeurs pour un jour de semaine et 24 pour un jour de week-end, divisées par sa consommation moyenne (1 = la moyenne du compteur). Dans la console SQL, collez et exécutez :
```sql
CREATE OR REPLACE TABLE gold.profil_prm
(
    id_prm          UInt64,
    profil          LowCardinality(String),
    segment         LowCardinality(String),
    puissance_kva   UInt16,
    conso_moy_w     Float64,
    forme_semaine   Array(Float32),
    forme_weekend   Array(Float32)
)
ENGINE = MergeTree
ORDER BY (profil, id_prm);

INSERT INTO gold.profil_prm
SELECT
    id_prm,
    dictGet('ref.dict_prm', 'profil', id_prm),
    dictGet('ref.dict_prm', 'segment', id_prm),
    dictGet('ref.dict_prm', 'puissance_kva', id_prm),
    round(avg(conso_w), 1),
    arrayMap(x -> toFloat32(round(x / avg(conso_w), 3)), arraySort((x, h) -> h, groupArrayIf(conso_w, type_jour = 'semaine'), groupArrayIf(heure, type_jour = 'semaine'))),
    arrayMap(x -> toFloat32(round(x / avg(conso_w), 3)), arraySort((x, h) -> h, groupArrayIf(conso_w, type_jour = 'week-end'), groupArrayIf(heure, type_jour = 'week-end')))
FROM
(
    SELECT id_prm,
           if(toDayOfWeek(ts - 1, 0, 'Europe/Paris') >= 6, 'week-end', 'semaine') AS type_jour,
           toHour(ts - 900, 'Europe/Paris') AS heure,
           avg(valeur_w) AS conso_w
    FROM silver.courbe_charge FINAL
    WHERE grandeur = 'CONS'
    GROUP BY id_prm, type_jour, heure
)
GROUP BY id_prm;

ALTER TABLE gold.profil_prm
    MODIFY COMMENT 'Forme de consommation moyenne de chaque compteur en octobre 2026, pour la data science. Une ligne par compteur.';
ALTER TABLE gold.profil_prm
    COMMENT COLUMN profil        'Profil déclaré : RES (résidentiel), PRO (professionnel), ENT (entreprise, industrie)',
    COMMENT COLUMN conso_moy_w   'Puissance moyenne du compteur sur le mois, en W',
    COMMENT COLUMN forme_semaine '24 valeurs, de 0h à 23h (heure de Paris), jour de semaine, divisées par conso_moy_w',
    COMMENT COLUMN forme_weekend '24 valeurs, de 0h à 23h (heure de Paris), jour de week-end, divisées par conso_moy_w';
```
Vérifiez :
```sql
SELECT profil, count() AS compteurs, arrayMap(x -> round(x, 1), any(forme_semaine)) AS exemple_semaine
FROM gold.profil_prm
GROUP BY profil;
```
Attendu : 17 372 RES, 2 587 PRO, 40 ENT. La table se construit en 0,5 à 1,5 s à partir de 30 M de points silver.

**6.2 · Ajouter les consignes de data science à l'agent [console]**
Run Code exécute du Python dans un bac à sable, qui n'a pas vos identifiants ClickHouse. Sans consigne, l'agent écrit un script avec `clickhouse_connect` et vous demande de le lancer vous-même. On lui donne donc la méthode une fois pour toutes, dans ses instructions.

Rouvrez l'agent, onglet **Instructions**, **Inline**, et ajoutez ce bloc à la fin :
```
Data science avec l'outil Run Code :
- Tu exécutes toujours toi-même le code Python dans l'outil Run Code. Ne propose jamais un
  script à lancer, n'utilise jamais clickhouse_connect ni aucune connexion à une base.
- Méthode, toujours la même :
  1. une requête avec l'outil ClickHouse qui renvoie moins de 100 lignes (agrège ou
     échantillonne dans ClickHouse) ;
  2. copie le résultat tel quel dans ton code Python ;
  3. exécute le code dans Run Code et montre les chiffres et un graphique.
- Courbe d'un territoire : une ligne par jour, avec les 48 demi-heures dans un tableau :
  SELECT jour, toDayOfWeek(jour) >= 6 AS week_end,
         arrayMap(x -> x.2, arraySort(groupArray((demi_heure, mw)))) AS conso_mw
  FROM (SELECT toDate(ts - 1800, 'Europe/Paris') AS jour,
               toHour(ts - 1800, 'Europe/Paris') * 2 + intDiv(toMinute(ts - 1800, 'Europe/Paris'), 30) AS demi_heure,
               round(avg(puissance_kw) / 1000, 2) AS mw
        FROM gold.courbe_epci
        WHERE code_epci = '<code EPCI>' AND grandeur = 'CONS'
        GROUP BY jour, demi_heure)
  GROUP BY jour ORDER BY jour
- Formes des compteurs : SELECT profil, arrayMap(x -> round(x, 2), forme_semaine) AS semaine,
  arrayMap(x -> round(x, 2), forme_weekend) AS weekend FROM gold.profil_prm
  ORDER BY cityHash64(id_prm) LIMIT 30 BY profil
- Prévision : HistGradientBoostingRegressor(max_iter=300, learning_rate=0.05, random_state=0)
  avec demi_heure, week_end et jour du mois. Compare toujours son erreur (MAPE) à deux méthodes
  naïves alignées par demi-heure : la veille, et le même jour de la semaine précédente.
- Segmentation : KMeans(n_clusters=3, n_init=10, random_state=0) sur les 48 valeurs de forme
  (semaine puis week-end), puis croise les groupes avec le profil.
- Profilage : sépare 70 % / 30 % (stratifié par profil), forme type = centre du groupe
  KMeans appris sur les 70 %, erreur moyenne en % sur les 30 %, comparée à une courbe plate.
```
Enregistrez l'agent, puis ouvrez une **nouvelle** conversation : les instructions ne s'appliquent qu'aux conversations qui commencent après.

**6.3 · Les trois demandes**
Une phrase suffit : la méthode est dans les instructions.

| | Demande à coller | Résultat attendu |
|---|---|---|
| **ML1 · Prévision** | « Prévois la courbe de charge du Grand Paris pour le samedi 31 octobre à partir du 1er au 30 octobre, et compare à la réalité. » | modèle **~2,3 %** d'erreur, samedi précédent ~3,3 %, veille ~47 %. Pointe réelle à 19h30, 22,0 MW |
| **ML2 · Segmentation** | « Regroupe les compteurs en 3 familles selon la forme de leur consommation et montre-moi chaque famille. » | 3 groupes de 30 qui recoupent **exactement** RES, PRO, ENT : pointe du soir, plateau 8h-19h, talon industriel |
| **ML3 · Profilage** | « Montre-moi qu'on peut reconstituer la courbe d'un compteur à partir de son énergie seule, avec la forme type de sa famille. » | **~2,3 %** d'erreur avec la forme type, contre ~45 % avec une courbe plate |

Les résultats attendus viennent de l'exécution de ces mêmes calculs en Python (scikit-learn 1.9) sur les données du service. L'agent peut trouver des chiffres un peu différents : c'est l'ordre de grandeur qui compte.

À retenir pour ML1 : le modèle bat les deux méthodes naïves parce qu'il sait que demain est un samedi, et qu'il suit la hausse de fin de mois. Avec le `GradientBoostingRegressor` par défaut, on obtient ~8 %, moins bien que le samedi précédent : le choix du modèle compte, d'où la consigne.

À retenir pour ML3 : c'est le principe du **profilage**. Pour un compteur sans courbe de charge, on multiplie son énergie (relevée par index) par la forme type de sa famille.

**Si l'agent n'exécute toujours pas le code** : répondez « exécute-le toi-même avec Run Code, en collant les données dans le code ». Vérifiez aussi que la conversation a bien été ouverte après l'enregistrement des instructions.

Ces résultats sont nets parce que les données sont simulées. Sur des données réelles, la météo, les vacances et les comportements individuels augmentent les erreurs. La méthode, elle, reste la même.

### Étape 7 · En production : un rôle dédié à l'agent
Pendant le workshop, l'agent tourne avec vos droits. En production, on lui donne un rôle en lecture seule sur gold, avec des limites sur chaque requête (règle `agent-query-safety`). À adapter, non exécuté pendant le workshop :
```sql
CREATE SETTINGS PROFILE IF NOT EXISTS profil_agent SETTINGS
    readonly = 2, max_execution_time = 30, max_rows_to_read = 1000000000,
    max_result_rows = 10000, result_overflow_mode = 'break';
CREATE ROLE IF NOT EXISTS role_agent SETTINGS PROFILE 'profil_agent';
GRANT SELECT ON gold.* TO role_agent;
GRANT SELECT ON ref.* TO role_agent;
GRANT dictGet ON ref.* TO role_agent;
```
`readonly = 2` interdit toute écriture, `max_rows_to_read` et `max_execution_time` bornent le coût d'une question mal posée. La possibilité de choisir ce rôle dans la configuration de l'agent n'est pas vérifiée (fonctionnalité en bêta).
