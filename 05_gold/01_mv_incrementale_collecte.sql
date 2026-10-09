-- =====================================================================
--  MODULE 5 · Gold (1/4) : le suivi de collecte, en temps réel
-- =====================================================================
--  bronze ──MV──► silver ──MV──► gold      (MV en CASCADE)
--  On compte, pour chaque PRM et chaque jour, les points reçus, et ceux
--  reçus AVANT 9h. Agrégation à l'insertion : AggregatingMergeTree.
--  Gold reçoit des agrégats tout prêts : le KPI se lit dans une petite table
--  au lieu de recompter des millions de points (règle query-mv-incremental).
-- =====================================================================


-- ÉTAPE 1 · Une table d'agrégats : elle stocke des ÉTATS, pas des valeurs
--  Un état est un calcul "en cours" (par exemple l'ensemble des horodatages vus).
--  Deux états se fusionnent sans rien perdre : c'est ce que font les merges.
--  SimpleAggregateFunction suffit pour min et max, qui se fusionnent trivialement.
CREATE OR REPLACE TABLE gold.collecte_prm_jour
(
    jour               Date,
    id_prm             UInt64,
    points_recus       AggregateFunction(uniqExact, DateTime('UTC')),
    points_avant_9h    AggregateFunction(uniqExactIf, DateTime('UTC'), UInt8),
    premiere_arrivee   SimpleAggregateFunction(min, DateTime64(3, 'UTC')),
    derniere_arrivee   SimpleAggregateFunction(max, DateTime64(3, 'UTC'))
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(jour)
ORDER BY (jour, id_prm);


-- ÉTAPE 2 · La MV branchée sur silver (déclenchée par la MV bronze → silver)
--  uniqExact est IDEMPOTENT : un fichier renvoyé ne compte pas deux fois.
--  Le suffixe -State produit l'état au lieu du résultat final.
CREATE OR REPLACE MATERIALIZED VIEW gold.mv_collecte TO gold.collecte_prm_jour AS
SELECT
    jour,
    id_prm,
    uniqExactState(ts)                                                                  AS points_recus,
    uniqExactIfState(ts, toUInt8(version < toDateTime(jour + 1, 'Europe/Paris') + INTERVAL 9 HOUR)) AS points_avant_9h,
    min(version)                                                                        AS premiere_arrivee,
    max(version)                                                                        AS derniere_arrivee
FROM silver.courbe_charge
WHERE grandeur = 'CONS'
GROUP BY jour, id_prm;


-- ÉTAPE 3 · Backfill depuis silver (la MV ne voit que le futur, souvenez-vous)
INSERT INTO gold.collecte_prm_jour
SELECT
    jour, id_prm,
    uniqExactState(ts),
    uniqExactIfState(ts, toUInt8(version < toDateTime(jour + 1, 'Europe/Paris') + INTERVAL 9 HOUR)),
    min(version), max(version)
FROM silver.courbe_charge
WHERE grandeur = 'CONS'
GROUP BY jour, id_prm;
-- Mesuré : 5,22 s · 29,8 M lignes lues (653,8 Mo) · 618 163 lignes écrites · 3,2 Go de mémoire


-- ÉTAPE 4 · Lire des états : le suffixe -Merge
--  uniqExactMerge fusionne les états de toutes les parts et renvoie le nombre final.
--  Toujours avec un GROUP BY : plusieurs lignes peuvent exister pour un même PRM-jour.
SELECT
    jour,
    uniqExactMerge(points_recus)     AS points,
    uniqExactIfMerge(points_avant_9h) AS points_avant_9h,
    min(premiere_arrivee)            AS premiere_arrivee
FROM gold.collecte_prm_jour
WHERE id_prm = sim_id_prm(42)
GROUP BY jour
ORDER BY jour
LIMIT 10;
-- Mesuré : 58 ms · 253 952 lignes lues (62,5 Mo) · 241,6 Mo de mémoire


-- ÉTAPE 5 · L'expérience du doublon : une SOMME par MV, est-ce sûr ?
--  On crée une MV qui somme l'énergie par jour, puis on renvoie un fichier.
CREATE OR REPLACE TABLE gold.energie_naive
(
    jour        Date,
    energie_kwh SimpleAggregateFunction(sum, Float64)
)
ENGINE = AggregatingMergeTree
ORDER BY jour;

CREATE OR REPLACE MATERIALIZED VIEW gold.mv_energie_naive TO gold.energie_naive AS
SELECT jour, sum(valeur_w * pas_min / 60 / 1000) AS energie_kwh
FROM silver.courbe_charge
WHERE grandeur = 'CONS'
GROUP BY jour;

INSERT INTO gold.energie_naive
SELECT jour, sum(valeur_w * pas_min / 60 / 1000) FROM silver.courbe_charge FINAL WHERE grandeur = 'CONS' GROUP BY jour;
-- Mesuré : 298 ms · 30,4 M lignes lues (810,1 Mo) · 31 lignes écrites · 363,7 Mo de mémoire

--  On renvoie un fichier déjà reçu (le lot 3 du 20 octobre)
INSERT INTO bronze.flux_raw
SELECT replaceOne(file_name, '_488903_', '_488903_RENVOI_'), code_flux, ingested_at + INTERVAL 1 DAY, payload
FROM bronze.flux_raw
WHERE file_name LIKE 'GRD_CDC_30MIN_PUB_100383_488903_2%';
-- Mesuré : 205 ms · 102 106 lignes lues (20,1 Mo) · 51 149 lignes écrites · 96,8 Mo de mémoire

SELECT
    (SELECT round(sum(energie_kwh)) FROM gold.energie_naive WHERE jour = '2026-10-20')                         AS somme_par_mv,
    (SELECT round(sum(valeur_w * pas_min / 60 / 1000)) FROM silver.courbe_charge FINAL WHERE grandeur = 'CONS' AND jour = '2026-10-20') AS somme_reelle,
    (SELECT sum(n) FROM (SELECT uniqExactMerge(points_recus) AS n FROM gold.collecte_prm_jour WHERE jour = '2026-10-20' GROUP BY id_prm)) AS points_mv_uniq,
    (SELECT count() FROM silver.courbe_charge FINAL WHERE grandeur = 'CONS' AND jour = '2026-10-20')           AS points_reels;
-- Mesuré : 355 ms · 61,1 M lignes lues (1,5 Go) · 355 Mo de mémoire
-- À observer : la somme est fausse d'environ 6 % (le fichier renvoyé est compté
--    2 fois), uniqExact reste juste.
--    Règle : sum en MV incrémentale seulement si la source n'a jamais de doublons.
--    Sinon : vue matérialisée RAFRAÎCHISSABLE sur silver FINAL (fichier suivant).

--  On supprime l'expérience : elle ne sert plus.
DROP VIEW gold.mv_energie_naive;
DROP TABLE gold.energie_naive;
