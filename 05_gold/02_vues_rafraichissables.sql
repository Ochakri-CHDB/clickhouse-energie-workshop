-- =====================================================================
--  MODULE 5 · Gold (2/4) : les KPIs consolidés, rafraîchis
-- =====================================================================
--  Une vue matérialisée RAFRAÎCHISSABLE recalcule sa requête selon un
--  planning et remplace atomiquement le résultat. Elle lit silver FINAL :
--  doublons et corrections sont donc toujours bien pris en compte.
--
--     silver FINAL ──(toutes les 10 min)──► gold.energie_commune_jour
--                                              │ DEPENDS ON
--                                              ▼
--                                    gold.synthese_collectivite_jour
--
--  MV incrémentale ou rafraîchissable ?
--    · incrémentale : temps réel, mais ne voit que les INSERT (piège de la somme)
--    · rafraîchissable : recalcule tout, juste avec FINAL et les jointures,
--      au prix d'un léger retard (règle query-mv-refreshable).
-- =====================================================================


-- ÉTAPE 1 · L'énergie par commune, par jour, par segment
--  La table cible est triée comme le dashboard la filtre : par EPCI, puis commune.
CREATE OR REPLACE TABLE gold.energie_commune_jour
(
    jour          Date,
    code_insee    String,
    code_epci     LowCardinality(String),
    code_dept     LowCardinality(String),
    segment       LowCardinality(String),
    grandeur      LowCardinality(String),
    energie_kwh   Float64,
    nb_prm        UInt32,
    puissance_max_w UInt32
)
ENGINE = MergeTree
ORDER BY (code_epci, code_insee, grandeur, jour);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_energie_commune_jour
REFRESH EVERY 10 MINUTE
TO gold.energie_commune_jour
AS
SELECT
    jour,
    dictGet('ref.dict_prm', 'code_insee', id_prm)                         AS code_insee,
    dictGet('ref.dict_commune', 'code_epci', code_insee)                  AS code_epci,
    dictGet('ref.dict_commune', 'code_dept', code_insee)                  AS code_dept,
    dictGet('ref.dict_prm', 'segment', id_prm)                            AS segment,
    grandeur,
    sum(valeur_w * pas_min / 60 / 1000)                                   AS energie_kwh,
    uniqExact(id_prm)                                                     AS nb_prm,
    max(valeur_w)                                                         AS puissance_max_w
FROM silver.courbe_charge FINAL
GROUP BY jour, code_insee, code_epci, code_dept, segment, grandeur;

--  Le premier rafraîchissement démarre tout de suite. Suivons-le dans
--  system.view_refreshes (statut, durée, lignes écrites, prochaine exécution) :
SELECT view, status, last_success_time, last_refresh_time, next_refresh_time, read_rows, written_rows
FROM system.view_refreshes
WHERE database = 'gold';

--  On attend la fin de ce 1er calcul avant de brancher d'autres vues sur la table.
--  Attention : sans cette attente, sur un service à plusieurs répliques, l'étape 3
--  échoue avec "has been changed by another replica".
SYSTEM WAIT VIEW gold.rmv_energie_commune_jour;
-- Mesuré : 695 ms


-- ÉTAPE 2 · La courbe de charge agrégée par EPCI (pour le dashboard)
--  30 millions de points silver deviennent quelques milliers de lignes :
--  une courbe par territoire et par grandeur.
CREATE OR REPLACE TABLE gold.courbe_epci
(
    code_epci     LowCardinality(String),
    grandeur      LowCardinality(String),
    ts            DateTime('UTC'),
    puissance_kw  Float64,
    nb_prm        UInt32
)
ENGINE = MergeTree
ORDER BY (code_epci, grandeur, ts);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_courbe_epci
REFRESH EVERY 10 MINUTE
TO gold.courbe_epci
AS
SELECT
    dictGet('ref.dict_commune', 'code_epci', dictGet('ref.dict_prm', 'code_insee', id_prm)) AS code_epci,
    grandeur,
    ts,
    sum(valeur_w) / 1000                                                                    AS puissance_kw,
    count()                                                                                 AS nb_prm
FROM silver.courbe_charge FINAL
GROUP BY code_epci, grandeur, ts;


-- ÉTAPE 3 · Une vue qui DÉPEND d'une autre : la synthèse par collectivité
--  DEPENDS ON : elle attend que l'énergie par commune soit rafraîchie.
--  C'est la réponse SQL aux "sémaphores" entre chaînes de traitement.
CREATE OR REPLACE TABLE gold.synthese_collectivite_jour
(
    id_destinataire  String,
    collectivite     String,
    jour             Date,
    conso_kwh        Float64,
    prod_kwh         Float64,
    taux_couverture  Float64,         -- production / consommation
    nb_prm           UInt32
)
ENGINE = MergeTree
ORDER BY (id_destinataire, jour);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_synthese_collectivite
REFRESH EVERY 10 MINUTE
DEPENDS ON gold.rmv_energie_commune_jour
TO gold.synthese_collectivite_jour
AS
SELECT
    d.id_destinataire,
    d.nom                                                 AS collectivite,
    e.jour,
    sumIf(e.energie_kwh, e.grandeur = 'CONS')             AS conso_kwh,
    sumIf(e.energie_kwh, e.grandeur = 'PROD')             AS prod_kwh,
    round(prod_kwh / conso_kwh, 4)                        AS taux_couverture,
    sumIf(e.nb_prm, e.grandeur = 'CONS')                  AS nb_prm
FROM gold.energie_commune_jour AS e
INNER JOIN ref.destinataire AS d ON d.code_epci = e.code_epci
GROUP BY d.id_destinataire, d.nom, e.jour;


-- ÉTAPE 4 · Forcer un rafraîchissement (au lieu d'attendre 10 min)
--  SYSTEM REFRESH lance le calcul, SYSTEM WAIT attend qu'il soit terminé.
--  Le résultat remplace l'ancien d'un coup : un dashboard ne voit jamais un état partiel.
SYSTEM REFRESH VIEW gold.rmv_energie_commune_jour;
SYSTEM WAIT VIEW gold.rmv_energie_commune_jour;
-- Mesuré : 629 ms
SYSTEM REFRESH VIEW gold.rmv_synthese_collectivite;
SYSTEM WAIT VIEW gold.rmv_synthese_collectivite;
-- Mesuré : 289 ms
SYSTEM REFRESH VIEW gold.rmv_courbe_epci;
SYSTEM WAIT VIEW gold.rmv_courbe_epci;
-- Mesuré : 615 ms

SELECT view, status, last_success_time, round(last_success_duration_ms / 1000, 2) AS duree_s, written_rows
FROM system.view_refreshes
WHERE database = 'gold';

SELECT collectivite, round(sum(conso_kwh) / 1000) AS conso_mwh, round(sum(prod_kwh) / 1000) AS prod_mwh,
       round(100 * sum(prod_kwh) / sum(conso_kwh), 1) AS couverture_pct, max(nb_prm) AS nb_prm
FROM gold.synthese_collectivite_jour
GROUP BY collectivite
ORDER BY conso_mwh DESC;
-- Mesuré : 35 ms · 186 lignes lues (7,9 Ko)
