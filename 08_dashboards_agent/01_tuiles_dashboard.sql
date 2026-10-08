-- =====================================================================
--  MODULE 8 · Les tuiles du dashboard "Collectivité", lues dans gold
-- =====================================================================
--  Un dashboard ne doit JAMAIS relire silver : il lit des tables gold
--  petites, pré-agrégées, triées selon ses filtres. Chaque tuile ci-dessous
--  répond en quelques millisecondes, même rafraîchie toutes les 30 s.
--
--  Mode d'emploi : exécutez chaque requête, puis "Save" pour la garder.
--  Le README de ce dossier explique comment en faire un dashboard.
--
--  Les tuiles sont écrites pour la Métropole du Grand Paris (EPCI 200054781,
--  destinataire 488903). Pour un dashboard interactif, remplacez la valeur
--  par un paramètre : {code_epci:String}, {jour:Date} (voir le README).
-- =====================================================================


-- TUILE 1 · Courbe de charge du 15 octobre : consommation vs production
--  Graphique "Line" : X = heure, Y = conso_mw et prod_mw.
--  gold.courbe_epci est triée par (code_epci, grandeur, ts) : le filtre
--  suit l'ORDER BY, on lit 2 × 48 lignes (règle schema-pk-filter-on-orderby).
SELECT
    toTimeZone(ts, 'Europe/Paris')                          AS heure,
    round(sumIf(puissance_kw, grandeur = 'CONS') / 1000, 2) AS conso_mw,
    round(sumIf(puissance_kw, grandeur = 'PROD') / 1000, 2) AS prod_mw
FROM gold.courbe_epci
WHERE code_epci = '200054781'
  AND ts >  toDateTime('2026-10-15', 'Europe/Paris')
  AND ts <= toDateTime('2026-10-16', 'Europe/Paris')
GROUP BY heure
ORDER BY heure;
-- Mesuré : 28 ms · 8 192 lignes lues (112,1 Ko)
-- À observer : la pointe du soir vers 19h-20h, la bosse solaire à midi, très en dessous.
-- sumIf transforme les lignes CONS et PROD en deux colonnes : le format attendu par un graphique.


-- TUILE 2 · Énergie par jour sur le mois
--  Graphique "Bar" : X = jour, Y = conso_mwh (et prod_mwh en 2e série).
SELECT
    jour,
    round(conso_kwh / 1000, 1)          AS conso_mwh,
    round(prod_kwh / 1000, 1)           AS prod_mwh,
    round(100 * taux_couverture, 1)     AS couverture_pct
FROM gold.synthese_collectivite_jour
WHERE id_destinataire = '488903'
ORDER BY jour;
-- Mesuré : 26 ms · 186 lignes lues (6,2 Ko)
-- À observer : les creux du week-end, et la tendance qui monte : octobre se refroidit.


-- TUILE 3 · Top 10 des communes, en énergie consommée sur le mois
--  Graphique "Bar" horizontal ou "Table".
--  Le nom de la commune vient d'un dictionnaire : pas de JOIN.
SELECT
    dictGet('ref.dict_commune', 'nom', code_insee)      AS commune,
    round(sum(energie_kwh) / 1000, 1)                   AS conso_mwh,
    round(sum(nb_prm) / uniqExact(jour))                AS nb_compteurs,     -- une ligne par segment et par jour
    round(sum(energie_kwh) / sum(nb_prm), 1)            AS kwh_par_compteur_et_par_jour
    -- Attention, alias global : "max(nb_prm) AS nb_prm" masquerait la colonne nb_prm dans le calcul suivant
FROM gold.energie_commune_jour
WHERE code_epci = '200054781' AND grandeur = 'CONS'
GROUP BY code_insee
ORDER BY conso_mwh DESC
LIMIT 10;
-- Mesuré : 19 ms · 16 384 lignes lues (384,1 Ko)
-- À observer : Paris en tête (un seul code INSEE, 75056). Puis des communes comme Pantin ou Gagny :
--    peu de compteurs mais un site industriel C2, d'où les kWh par compteur élevés.


-- TUILE 4 · KPI "99 % des données à 9h", dernier jour et tendance
--  4a · Le chiffre du jour (tuile "Big number")
--  argMax(taux, jour) : le taux du jour le plus récent, sans sous-requête.
SELECT
    argMax(taux_donnees_9h_pct, jour)                 AS taux_dernier_jour_pct,
    max(jour)                                         AS dernier_jour,
    countIf(taux_donnees_9h_pct < 99)                 AS jours_sous_la_cible_ce_mois
FROM gold.kpi_completude_jour;
-- Mesuré : 27 ms · 31 lignes lues

--  4b · La tendance (graphique "Line" avec la cible en 2e série)
SELECT jour, taux_donnees_9h_pct, 99 AS cible_pct
FROM gold.kpi_completude_jour
ORDER BY jour;
-- Mesuré : 2 ms · 31 lignes lues


-- TUILE 5 · Les alertes de dépassement du dernier jour connu
--  Graphique "Table", trié par gravité.
--  La sous-requête (SELECT max(jour) …) suit l'actualité : pas de date en dur.
SELECT
    commune,
    segment,
    id_prm,
    kva_souscrit,
    round(pmax_va / 1000, 1)        AS pmax_kva,
    depassement_pct,
    heure_pointe
FROM gold.alertes_pmax
WHERE jour = (SELECT max(jour) FROM gold.alertes_pmax)
  AND code_epci = '200054781'
ORDER BY depassement_pct DESC;
-- Mesuré : 30 ms · 258 lignes lues (10,7 Ko)
--  Toutes collectivités confondues, pour l'exploitant :
SELECT
    dictGet('ref.dict_epci', 'nom', code_epci)  AS epci,
    count()                                     AS alertes,
    round(max(depassement_pct), 1)              AS pire_depassement_pct
FROM gold.alertes_pmax
WHERE jour = (SELECT max(jour) FROM gold.alertes_pmax)
GROUP BY epci
ORDER BY alertes DESC;
-- Mesuré : 6 ms · 258 lignes lues (2,9 Ko)


-- ÉTAPE 6 · Ce que coûtent nos tuiles : le journal des requêtes
SYSTEM FLUSH LOGS;   -- le journal est écrit par paquets toutes les ~7 s : on force l'écriture

SELECT
    round(query_duration_ms)                     AS ms,
    read_rows                                    AS lignes_lues,
    formatReadableSize(read_bytes)               AS lu,
    substring(replaceRegexpAll(query, '\\s+', ' '), 1, 70) AS requete
FROM clusterAllReplicas('default', system.query_log)
WHERE type = 'QueryFinish'
  AND event_time > now() - INTERVAL 10 MINUTE
  AND query_kind = 'Select'
  AND hasAny(tables, ['gold.courbe_epci', 'gold.synthese_collectivite_jour', 'gold.energie_commune_jour',
                      'gold.kpi_completude_jour', 'gold.alertes_pmax'])
  AND query NOT ILIKE '%query_log%'
ORDER BY event_time DESC
LIMIT 10;
-- À observer : quelques millisecondes et quelques milliers de lignes par tuile.
-- C'est tout l'intérêt de gold : le coût est payé une fois, au rafraîchissement.


-- CHECKPOINT MODULE 8 (1/3)
--  Chaque tuile doit renvoyer des données : 96 points de courbe (48 CONS + 48 PROD),
--  31 jours, plus de 100 communes, 31 jours de KPI, au moins une alerte.
SELECT
    if((SELECT count() FROM gold.courbe_epci WHERE code_epci = '200054781'
          AND ts > toDateTime('2026-10-15', 'Europe/Paris') AND ts <= toDateTime('2026-10-16', 'Europe/Paris')) = 96, 'OK', 'KO') AS tuile_courbe,
    if((SELECT count() FROM gold.synthese_collectivite_jour WHERE id_destinataire = '488903') = 31, 'OK', 'KO') AS tuile_energie,
    if((SELECT uniqExact(code_insee) FROM gold.energie_commune_jour WHERE code_epci = '200054781') > 100, 'OK', 'KO') AS tuile_communes,
    if((SELECT count() FROM gold.kpi_completude_jour) = 31, 'OK', 'KO') AS tuile_kpi,
    if((SELECT count() FROM gold.alertes_pmax WHERE jour = (SELECT max(jour) FROM gold.alertes_pmax)) > 0, 'OK', 'KO') AS tuile_alertes
SETTINGS select_sequential_consistency = 1;
