-- =====================================================================
--  MODULE 8 · Une API pour le portail client : vues paramétrées + Query API
-- =====================================================================
--  Le front d'une collectivité a besoin de 2 appels :
--    · la courbe de charge de son territoire, entre deux dates
--    · la synthèse jour par jour (conso, production, couverture)
--  On les écrit UNE fois, en SQL, sous forme de vues paramétrées.
--  Le front n'envoie que des paramètres : jamais de SQL.
--
--     front ──HTTPS──► Query API endpoint ──► SELECT * FROM gold.api_xxx(...)
--                       (clé API + rôle)            │ row policy
--                                                   ▼
--                                              tables gold
-- =====================================================================


-- ÉTAPE 1 · La courbe de charge d'une collectivité
--  {nom:Type} déclare un paramètre. Le filtre suit l'ORDER BY de gold.courbe_epci
--  (code_epci, grandeur, ts) : quelques centaines de lignes lues.
CREATE OR REPLACE VIEW gold.api_courbe_collectivite AS
SELECT
    toTimeZone(ts, 'Europe/Paris')   AS heure,
    grandeur,
    round(puissance_kw, 1)           AS puissance_kw,
    nb_prm
FROM gold.courbe_epci
WHERE code_epci IN (SELECT code_epci FROM ref.destinataire WHERE id_destinataire = {id_destinataire:String})
  AND ts >  toDateTime({debut:Date}, 'Europe/Paris')        -- fin d'intervalle : 00:30 est le 1er point du jour
  AND ts <= toDateTime({fin:Date} + 1, 'Europe/Paris')
ORDER BY grandeur, ts;

--  On l'appelle comme une fonction, en nommant chaque paramètre.
SELECT *
FROM gold.api_courbe_collectivite(id_destinataire = '488903', debut = '2026-10-15', fin = '2026-10-15')
LIMIT 10;
-- Mesuré : 30 ms · 8 198 lignes lues (144,2 Ko)
-- Attention : dans la console, un panneau "Query variables" peut s'ouvrir : laissez-le vide.


-- ÉTAPE 2 · La synthèse jour par jour
--  BETWEEN sur jour, deuxième colonne de la clé de tri (id_destinataire, jour) :
--  seules les lignes de la période demandée sont lues.
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

SELECT *
FROM gold.api_synthese_collectivite(id_destinataire = '488904', debut = '2026-10-01', fin = '2026-10-07');
-- Mesuré : 8 ms · 186 lignes lues (11,2 Ko)


-- ÉTAPE 3 · La requête à enregistrer pour le Query API endpoint
--  Dans la console : nouvel onglet, collez la requête ci-dessous (SANS la
--  commenter), "Save" sous le nom api_courbe_collectivite, puis
--  "Share" → "API Endpoint". Les paramètres deviennent des queryVariables.
--
--    SELECT *
--    FROM gold.api_courbe_collectivite(
--        id_destinataire = {id_destinataire:String},
--        debut           = {debut:Date},
--        fin             = {fin:Date})
--
--  Appel depuis le front (voir le README pour l'ID et la clé) :
--    curl -X POST 'https://console-api.clickhouse.cloud/.api/query-endpoints/<ID>/run?format=JSONEachRow' \
--      --user '<keyId>:<keySecret>' \
--      -H 'Content-Type: application/json' -H 'x-clickhouse-endpoint-version: 2' \
--      -d '{"queryVariables": {"id_destinataire": "488903", "debut": "2026-10-15", "fin": "2026-10-15"}}'
--
--  La même chose, exécutée ici avec des valeurs fixes :
SELECT grandeur, count() AS points, round(max(puissance_kw) / 1000, 2) AS pointe_mw
FROM gold.api_courbe_collectivite(id_destinataire = '488903', debut = '2026-10-15', fin = '2026-10-15')
GROUP BY grandeur;
-- Mesuré : 8 ms · 8 198 lignes lues (112,2 Ko)


-- ÉTAPE 4 · Sécurité : l'endpoint s'exécute avec un RÔLE de base de données
--  Au moment de créer l'endpoint, choisissez le rôle role_grand_paris (module 7).
--  Une vue "normale" s'exécute avec les droits de l'appelant (SQL SECURITY INVOKER) :
--  les row policies de gold s'appliquent donc aussi à travers la vue.
--  Même si le front envoie id_destinataire = '488904', il ne verra rien hors du Grand Paris.
GRANT SELECT ON ref.destinataire TO role_grand_paris;   -- la vue lit ce petit référentiel
--  (les vues gold.api_* sont déjà couvertes par GRANT SELECT ON gold.*, module 7)

SHOW GRANTS FOR role_grand_paris;


-- ÉTAPE 5 · Ce que voit le serveur : une requête de quelques millisecondes
SYSTEM FLUSH LOGS;

SELECT
    round(query_duration_ms)          AS ms,
    read_rows                         AS lignes_lues,
    formatReadableSize(read_bytes)    AS lu,
    substring(replaceRegexpAll(query, '\\s+', ' '), 1, 80) AS requete
FROM clusterAllReplicas('default', system.query_log)
WHERE type = 'QueryFinish'
  AND query_kind = 'Select'
  AND event_time > now() - INTERVAL 10 MINUTE
  AND query ILIKE '%gold.api_%'
  AND query NOT ILIKE '%query_log%'
ORDER BY event_time DESC
LIMIT 5;
-- À observer : quelques millisecondes par appel. C'est ce que paiera le front à chaque écran.


-- CHECKPOINT MODULE 8 (2/3)
--  Une journée = 96 points, une semaine = 7 jours, un destinataire inconnu = rien.
SELECT
    if((SELECT count() FROM gold.api_courbe_collectivite(id_destinataire = '488903', debut = '2026-10-15', fin = '2026-10-15')) = 96, 'OK', 'KO') AS api_courbe,
    if((SELECT count() FROM gold.api_synthese_collectivite(id_destinataire = '488904', debut = '2026-10-01', fin = '2026-10-07')) = 7, 'OK', 'KO') AS api_synthese,
    if((SELECT count() FROM gold.api_courbe_collectivite(id_destinataire = 'inconnu', debut = '2026-10-15', fin = '2026-10-15')) = 0, 'OK', 'KO') AS destinataire_inconnu_vide
SETTINGS select_sequential_consistency = 1;
