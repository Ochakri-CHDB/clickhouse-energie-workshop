# Module 8 · Dashboards, API et ClickHouse Agents

Gold est prêt : petites tables, triées selon les filtres du front, rafraîchies toutes les 10 minutes. On les expose de trois façons, toutes depuis la console Cloud :

| Pour qui | Quoi | Fichier |
|---|---|---|
| L'exploitant, le chef de projet | Un dashboard de 8 tuiles, filtrable par collectivité | `01_tuiles_dashboard.sql` |
| Le portail d'une collectivité | Une API HTTPS sans SQL côté client | `02_vue_parametree_api.sql` |
| Tout le monde | Un agent qui répond en français et construit des dashboards | `03_questions_agent.sql` |

Durée : 45 min. Exécutez d'abord les 3 fichiers SQL dans la console (Cmd+Entrée) : tous les checkpoints doivent afficher `OK`.

> Les libellés ci-dessous sont ceux de la console ClickHouse Cloud en octobre 2026. Dashboards et ClickHouse Agents sont en **bêta** : un libellé peut avoir bougé, le principe ne change pas.

---

## 1. Le dashboard « Énergie · Grand Paris » (20 min)

### Étape 1 · Enregistrer chaque requête de tuile
Une tuile de dashboard affiche une **requête enregistrée** (saved query). Pour chaque tuile de `01_tuiles_dashboard.sql` :
1. **SQL console**, ouvrez un nouvel onglet (`+`).
2. Collez la requête de la tuile, exécutez-la (Cmd+Entrée) et vérifiez le résultat.
3. Cliquez sur **Save**, donnez un nom parlant. Les noms proposés :

| Tuile | Nom de la requête |
|---|---|
| 1 | `Courbe de charge du 15 octobre` |
| 2 | `Énergie par jour` |
| 3 | `Top 10 communes` |
| 4a / 4b | `KPI 9h du jour` / `KPI 9h tendance` |
| 5 | `Alertes du dernier jour` |
| 6 | `Carte de chaleur jour × heure` |
| 7 | `Poids des métropoles` |

Astuce : vous pouvez aussi créer la requête directement depuis le dashboard (voir l'étape 3, « New query »).

### Étape 2 · Créer le dashboard
1. Barre latérale : **Dashboards**, puis **+ New Dashboard**.
2. Nom : `Énergie · Grand Paris`. Le dashboard vide s'ouvre.

### Étape 3 · Ajouter une tuile
1. En haut à droite, **+ New visualization**. Une tuile vide apparaît (« New table, Add a query to your dashboard ») et le panneau **Edit element** s'ouvre à droite.
2. Onglet **General**, champ **Query** :
   - soit une requête enregistrée à l'étape 1 dans la liste ;
   - soit **New query** : un **Inline Editor** s'ouvre. Collez la requête, exécutez-la avec le bouton ▷, puis enregistrez-la avec l'icône disquette.
3. **Visualization type** : choisissez le type indiqué dans le tableau ci-dessous. Les types disponibles : Big Stat, Table, Bar Chart, Stacked bar, Horizontal bar, Stacked H. bar, Line, Area, Pie, Doughnut, Scatter, Heatmap.
4. Onglet **Data** : associez les colonnes du résultat aux axes du graphique (axe X, séries Y, ou catégorie et valeur selon le type).
5. Onglet **Advanced** : format des nombres, légende, libellés des axes. Facultatif.
6. Donnez un **titre** à la tuile, fermez le panneau (×). Redimensionnez la tuile avec le coin en bas à droite, déplacez-la avec la poignée en haut à gauche.

| Tuile | Visualization type | Axe X / catégorie | Y / valeur |
|---|---|---|---|
| 1 · Courbe CONS vs PROD | **Line** (ou Area) | `heure` | `conso_mw`, `prod_mw` |
| 2 · Énergie par jour | **Stacked bar** | `jour` | `conso_mwh`, `prod_mwh` |
| 3 · Top 10 communes | **Horizontal bar** | `commune` | `conso_mwh` |
| 4a · KPI du jour | **Big Stat** | | `taux_dernier_jour_pct` |
| 4b · KPI tendance | **Line** | `jour` | `taux_donnees_9h_pct`, `cible_pct` |
| 5 · Alertes du dernier jour | **Table** | | toutes les colonnes |
| 6 · Carte de chaleur | **Heatmap** | `heure` (X), `jour` (Y) | `conso_mw` |
| 7 · Poids des métropoles | **Doughnut** | `collectivite` | `conso_mwh` |

Recommencez pour chaque tuile. Les deux plus spectaculaires à montrer en premier : la **Heatmap** (la pointe du soir apparaît comme une bande, jour après jour) et la **courbe CONS vs PROD**.

### Étape 4 · Rendre le dashboard filtrable
Un filtre de dashboard est un **paramètre de requête** : on remplace une valeur écrite en dur par `{nom:Type}`. Toutes les tuiles qui utilisent le **même nom de paramètre** suivent le même filtre.

On filtre avec des valeurs que tout le monde comprend :

| Filtre | Ce qu'on tape | Exemples |
|---|---|---|
| `collectivite` | un morceau du nom, sans se soucier des majuscules | `Paris`, `Lyon`, `Lille`, `Toulouse`, `Bordeaux`, `Nantes` |
| `jour` | une date au format AAAA-MM-JJ | `2026-10-15` |

Derrière, la requête retrouve le territoire dans `ref.destinataire` (« Paris » → Métropole du Grand Paris) et filtre gold sur son code. On garde donc la vitesse de la clé de tri sans demander de code à personne.

**4.1 · Mettre un paramètre dans chaque requête**
1. Sur la tuile, cliquez sur les **trois points** (⋮) en haut à droite, puis sur le **crayon** à côté de la requête : l'Inline Editor s'ouvre.
2. Remplacez la requête par sa version filtrable (ci-dessous). Dès que vous tapez `{collectivite:String}`, il apparaît dans le panneau **Query Parameters** à droite de l'éditeur.
3. Donnez une valeur de test au paramètre (`Paris`), exécutez (▷), puis **enregistrez** (disquette). La requête enregistrée est mise à jour.

Versions filtrables, testées sur le service pour les 6 métropoles (8 à 30 ms chacune) :

```sql
-- Tuile 1 · courbe d'une collectivité, un jour donné
SELECT toTimeZone(ts, 'Europe/Paris') AS heure,
       round(sumIf(puissance_kw, grandeur = 'CONS') / 1000, 2) AS conso_mw,
       round(sumIf(puissance_kw, grandeur = 'PROD') / 1000, 2) AS prod_mw
FROM gold.courbe_epci
WHERE code_epci IN (SELECT code_epci FROM ref.destinataire
                    WHERE positionCaseInsensitiveUTF8(nom, {collectivite:String}) > 0)
  AND ts >  toDateTime({jour:Date}, 'Europe/Paris')
  AND ts <= toDateTime({jour:Date} + 1, 'Europe/Paris')
GROUP BY heure ORDER BY heure;

-- Tuile 2 · énergie par jour
SELECT jour, round(conso_kwh / 1000, 1) AS conso_mwh, round(prod_kwh / 1000, 1) AS prod_mwh
FROM gold.synthese_collectivite_jour
WHERE positionCaseInsensitiveUTF8(collectivite, {collectivite:String}) > 0
ORDER BY jour;

-- Tuile 3 · top 10 communes
SELECT dictGet('ref.dict_commune', 'nom', code_insee) AS commune, round(sum(energie_kwh) / 1000, 1) AS conso_mwh
FROM gold.energie_commune_jour
WHERE code_epci IN (SELECT code_epci FROM ref.destinataire
                    WHERE positionCaseInsensitiveUTF8(nom, {collectivite:String}) > 0)
  AND grandeur = 'CONS'
GROUP BY code_insee ORDER BY conso_mwh DESC LIMIT 10;

-- Tuile 5 · alertes du mois pour la collectivité (un jour précis est souvent vide)
SELECT jour, commune, segment, kva_souscrit, round(pmax_va / 1000, 1) AS pmax_kva, depassement_pct
FROM gold.alertes_pmax
WHERE code_epci IN (SELECT code_epci FROM ref.destinataire
                    WHERE positionCaseInsensitiveUTF8(nom, {collectivite:String}) > 0)
ORDER BY jour DESC, depassement_pct DESC;

-- Tuile 6 · carte de chaleur
SELECT toDate(ts - 1, 'Europe/Paris') AS jour, toHour(ts - 900, 'Europe/Paris') AS heure,
       round(avg(puissance_kw) / 1000, 2) AS conso_mw
FROM gold.courbe_epci
WHERE code_epci IN (SELECT code_epci FROM ref.destinataire
                    WHERE positionCaseInsensitiveUTF8(nom, {collectivite:String}) > 0)
  AND grandeur = 'CONS'
GROUP BY jour, heure ORDER BY jour, heure;
```

`positionCaseInsensitiveUTF8(nom, 'Paris') > 0` est vrai si « Paris » apparaît dans le nom, quelle que soit la casse. Le nom complet (`Métropole du Grand Paris`) marche aussi. Les tuiles 4 (KPI) et 7 (poids des métropoles) restent globales : pas de paramètre.

**4.2 · Brancher les paramètres sur un filtre global**
1. Rouvrez la tuile (⋮, puis Edit). Dans les réglages de la visualisation, chaque paramètre de la requête apparaît avec sa **source de valeur** (value source).
2. Choisissez le type **filter** pour `collectivite` et pour `jour`.
3. Faites de même sur chaque tuile filtrable.
4. Cliquez sur l'**entonnoir** dans la barre du haut : le panneau **Global filters** s'ouvre, avec un champ `collectivite` et un champ `jour`.
5. Tapez `Paris` et `2026-10-15` : toutes les tuiles se recalculent. Puis `Lyon`, `Toulouse`, `Lille`…

**4.3 · Bonus : choisir la collectivité en cliquant sur son nom**
Plus simple encore pour un public non technique : une tuile liste les métropoles, on clique sur un nom.
1. Ajoutez une tuile **Table** « Choisir une collectivité » avec cette requête :
   ```sql
   SELECT collectivite, round(sum(conso_kwh) / 1000) AS conso_mwh, round(100 * sum(prod_kwh) / sum(conso_kwh), 1) AS couverture_pct
   FROM gold.synthese_collectivite_jour
   GROUP BY collectivite
   ORDER BY conso_mwh DESC;
   ```
2. Dans les réglages des autres tuiles, changez la **value source** du paramètre `collectivite` : au lieu de « filter », choisissez **cette table** et sa colonne `collectivite`.
3. Cliquez sur « Toulouse Métropole » dans la table : courbe, énergie, communes, alertes et heatmap basculent sur Toulouse.

À observer : chaque changement de filtre relance les requêtes, et chacune répond en quelques millisecondes car elle finit par filtrer gold sur le début de sa clé de tri (`code_epci`).

Partage : un collègue doit avoir accès aux **requêtes enregistrées** sous-jacentes, pas seulement au dashboard (bouton **Share** en haut).

Mesuré sur le service de test (3 × 64 Go) : chaque tuile répond en 2 à 30 ms et lit entre 31 et 16 384 lignes.

---

## 2. Le Query API endpoint pour le portail (15 min)

Le portail n'envoie que des paramètres. Le SQL reste dans ClickHouse, versionné avec le reste.

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
`03_questions_agent.sql`, étape 1, pose des `COMMENT` sur les tables et colonnes gold. C'est la première chose que lit un agent (règle `agent-discovery-schema`). Sans eux, il devine que `ts` est en heure locale, que `488903` est un code postal…

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
| Conversation starters | ajoutez les demandes D1, D2 et D3 de l'étape 3 de `03_questions_agent.sql` : elles apparaîtront comme boutons au démarrage d'une conversation |
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
Les questions sont dans `03_questions_agent.sql` (étape 2), chacune avec la requête attendue et le résultat attendu (commentaire `Résultat attendu`). Posez-les telles quelles, puis comparez.

Ce qui distingue une bonne réponse :
- les bons chiffres (le résultat de la requête attendue) ;
- un filtre sur la clé de tri et un `LIMIT` (règle `agent-query-safety`) ;
- les pièges évités : l'heure UTC (Q3), l'identifiant de collectivité à chercher (Q2), le total de compteurs à additionner sur les segments (Q4).

### Lui faire construire des dashboards (le moment fort)
L'étape 3 de `03_questions_agent.sql` contient 6 demandes (D1 à D6) : dashboard complet du Grand Paris, carte de chaleur, comparaison des 6 métropoles, rapport d'exploitation, sites qui dépassent, page pour un élu. L'agent interroge gold, puis construit la page en quelques dizaines de secondes.

Pour chaque demande :
1. Collez-la dans la conversation (ou cliquez le conversation starter).
2. Regardez les requêtes que l'agent exécute : il doit lire les commentaires, filtrer sur `code_epci` ou `id_destinataire`.
3. Comparez les chiffres de l'artifact au `Résultat attendu` du fichier.
4. Demandez une retouche dans la même conversation : « ajoute un filtre par métropole », « passe la courbe en aires empilées », « exporte en PDF ».

Commencez par **D2** (la carte de chaleur) puis **D1** (le dashboard complet) : ce sont les plus visuels.

### En production
Créez un rôle dédié à l'agent : lecture seule, gold uniquement, avec un profil de réglages qui borne chaque requête (exemple commenté à l'étape 4 de `03_questions_agent.sql`). Pendant le workshop, l'agent tourne avec vos droits.
