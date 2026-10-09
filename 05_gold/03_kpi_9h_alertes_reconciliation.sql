-- =====================================================================
--  MODULE 5 · Gold (3/3) : complétude à 9h, alertes, réconciliation
-- =====================================================================


-- ÉTAPE 1 · KPI "99 % des données arrivées à 9h"
--  Deux lectures du même suivi de collecte :
--    · taux_donnees_9h_pct : points reçus avant 9h / points attendus sur tout le parc
--      (c'est la cible contractuelle : 99 %)
--    · taux_prm_complets_9h_pct : PRM dont la journée est COMPLÈTE à 9h, plus sévère
--      (un seul point manquant et le PRM ne compte pas)
--  En production : REFRESH EVERY 1 DAY OFFSET 9 HOUR (tous les jours à 9h).
--  La vue lit gold.collecte_prm_jour (petite) et non silver : le calcul est immédiat.
CREATE OR REPLACE TABLE gold.kpi_completude_jour
(
    jour                      Date,
    parc_prm                  UInt32,
    prm_recus                 UInt32,
    points_attendus           UInt64,
    points_recus_9h           UInt64,
    taux_donnees_9h_pct       Float64,
    prm_complets_a_9h         UInt32,
    taux_prm_complets_9h_pct  Float64
)
ENGINE = MergeTree
ORDER BY jour;

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_kpi_completude
REFRESH EVERY 1 DAY OFFSET 9 HOUR
TO gold.kpi_completude_jour
AS
WITH
    (SELECT uniqExact(id_prm) FROM gold.collecte_prm_jour) AS parc,
    par_prm AS
    (
        SELECT
            jour,
            id_prm,
            uniqExactMerge(points_recus)                                                                      AS recus,
            uniqExactIfMerge(points_avant_9h)                                                                 AS avant_9h,
            dateDiff('minute', toDateTime(jour, 'Europe/Paris'), toDateTime(jour + 1, 'Europe/Paris')) / 30   AS attendus
        FROM gold.collecte_prm_jour
        GROUP BY jour, id_prm
    )
SELECT
    jour,
    parc                                                     AS parc_prm,
    count()                                                  AS prm_recus,
    toUInt64(parc * any(attendus))                           AS points_attendus,   -- un PRM muet compte aussi
    sum(avant_9h)                                            AS points_recus_9h,
    round(100 * points_recus_9h / points_attendus, 2)        AS taux_donnees_9h_pct,
    countIf(avant_9h = attendus)                             AS prm_complets_a_9h,
    round(100 * prm_complets_a_9h / parc, 2)                 AS taux_prm_complets_9h_pct
FROM par_prm
GROUP BY jour;

SYSTEM REFRESH VIEW gold.rmv_kpi_completude;
SYSTEM WAIT VIEW gold.rmv_kpi_completude;
-- Mesuré : 655 ms

SELECT jour, taux_donnees_9h_pct, taux_prm_complets_9h_pct,
       if(taux_donnees_9h_pct >= 99, 'OK', 'sous la cible') AS cible_99
FROM gold.kpi_completude_jour
ORDER BY jour;
-- Mesuré : 16 ms · 31 lignes lues
-- À observer : la plupart des jours passent la cible. Ceux en dessous : un ou plusieurs
--    fichiers arrivés l'après-midi (un lot = 1000 PRM, soit 5 % du parc d'un coup).

--  Lesquels ? Les fichiers CDC arrivés après 9h, heure de Paris
SELECT toDate(ingested_at, 'Europe/Paris') - 1 AS jour, file_name, toTimeZone(ingested_at, 'Europe/Paris') AS arrivee
FROM bronze.flux_raw
WHERE code_flux = 'CDC' AND toHour(ingested_at, 'Europe/Paris') >= 9
  AND file_name NOT LIKE '%RENVOI%' AND file_name NOT LIKE '%CORRECTION%'
ORDER BY ingested_at
LIMIT 10;
-- Mesuré : 6 ms · 116 lignes lues (7,7 Ko)


-- ÉTAPE 2 · Les alertes de dépassement de puissance souscrite
--  La puissance de référence est celle EN VIGUEUR le jour du dépassement :
--  dictGet sur le dictionnaire "à date" du module 4, avec le jour en 2e clé.
CREATE OR REPLACE TABLE gold.alertes_pmax
(
    jour             Date,
    id_prm           UInt64,
    commune          String,
    code_epci        LowCardinality(String),
    segment          LowCardinality(String),
    kva_souscrit     UInt16,
    pmax_va          UInt32,
    depassement_pct  Float64,
    heure_pointe     DateTime('Europe/Paris')
)
ENGINE = MergeTree
ORDER BY (jour, id_prm);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_alertes_pmax
REFRESH EVERY 10 MINUTE
TO gold.alertes_pmax
AS
SELECT
    jour,
    id_prm,
    dictGet('ref.dict_commune', 'nom', dictGet('ref.dict_prm', 'code_insee', id_prm))       AS commune,
    dictGet('ref.dict_commune', 'code_epci', dictGet('ref.dict_prm', 'code_insee', id_prm)) AS code_epci,
    dictGet('ref.dict_prm', 'segment', id_prm)                                               AS segment,
    dictGet('ref.dict_puissance_asof', 'puissance_kva', id_prm, jour)                        AS kva_souscrit,
    pmax_va,
    round(100 * (pmax_va / (kva_souscrit * 1000) - 1), 1)                                    AS depassement_pct,
    ts_pmax                                                                                  AS heure_pointe
FROM silver.pmax_jour FINAL
WHERE pmax_va > dictGet('ref.dict_puissance_asof', 'puissance_kva', id_prm, jour) * 1000;

SYSTEM REFRESH VIEW gold.rmv_alertes_pmax;
SYSTEM WAIT VIEW gold.rmv_alertes_pmax;
-- Mesuré : 495 ms

SELECT jour, count() AS nb_alertes, round(avg(depassement_pct), 1) AS depassement_moyen_pct
FROM gold.alertes_pmax
GROUP BY jour
ORDER BY jour;
-- Mesuré : 39 ms · 257 lignes lues (2,5 Ko)

--  Par segment : en C5, le disjoncteur du compteur coupe avant tout dépassement.
--  Les alertes ne concernent donc que les C4 et C2 (dépassements facturés).
SELECT segment, count() AS alertes, uniqExact(id_prm) AS prm, round(avg(depassement_pct), 1) AS depassement_moyen_pct
FROM gold.alertes_pmax
GROUP BY segment;
-- Mesuré : 2 ms · 257 lignes lues (4,3 Ko)

--  Les PRM qui ont augmenté leur puissance en octobre : moins d'alertes après ?
SELECT
    countIf(a.jour <= h.valid_to)  AS alertes_avant_changement,
    countIf(a.jour >  h.valid_to)  AS alertes_apres_changement,
    uniqExact(a.id_prm)            AS prm
FROM gold.alertes_pmax AS a
INNER JOIN (SELECT id_prm, valid_to FROM ref.prm_history WHERE valid_to BETWEEN '2026-10-01' AND '2026-10-30') AS h
    ON h.id_prm = a.id_prm;
-- Mesuré : 12 ms · 1 M lignes lues (9,8 Mo) · 65,8 Mo de mémoire
-- À observer : le client dépassait, il a augmenté sa puissance, les alertes chutent.
--    C'est dict_puissance_asof qui rend ça juste : on compare à la puissance DU JOUR.


-- ÉTAPE 3 · Réconciliation : énergie journalière (index) vs intégrale de la courbe CDC
--  Un écart révèle une courbe incomplète : on sait OÙ et COMBIEN il manque.
--  L'énergie journalière vient des index du compteur, il est complet même si la courbe a des trous.
--  Une vue simple (CREATE VIEW) ne stocke rien : la requête s'exécute à chaque lecture.
CREATE OR REPLACE VIEW gold.v_reconciliation AS
SELECT
    e.jour,
    e.id_prm,
    e.energie_wh / 1000                                          AS energie_jour_kwh,
    c.energie_courbe_kwh,
    c.nb_points,
    round(100 * (1 - c.energie_courbe_kwh / (e.energie_wh / 1000)), 2) AS ecart_pct
FROM silver.energie_jour AS e FINAL
INNER JOIN
(
    SELECT jour, id_prm, sum(valeur_w * pas_min / 60) / 1000 AS energie_courbe_kwh, count() AS nb_points
    FROM silver.courbe_charge FINAL
    WHERE grandeur = 'CONS'
    GROUP BY jour, id_prm
) AS c ON c.jour = e.jour AND c.id_prm = e.id_prm
WHERE e.grandeur = 'CONS';

SELECT
    multiIf(abs(ecart_pct) < 0.5, '1. < 0,5% (normal)', abs(ecart_pct) < 3, '2. 0,5 à 3% (1 point manquant)', '3. > 3% (plusieurs trous)') AS classe_ecart,
    count()                    AS prm_jours,
    round(avg(nb_points), 1)   AS points_moyens
FROM gold.v_reconciliation
GROUP BY classe_ecart
ORDER BY classe_ecart;
-- Mesuré : 235 ms · 31,2 M lignes lues (825,8 Mo) · 446,2 Mo de mémoire
-- À observer : plus de 97 % des PRM-jours collent à moins de 0,5 %. Les autres ont
-- 1 ou 2 points manquants (47 ou 46 points au lieu de 48) : la courbe est à compléter.


-- CHECKPOINT MODULE 5
--  31 jours de KPI, et au moins une alerte et une ligne dans chaque table gold.
SELECT
    if((SELECT count() FROM gold.collecte_prm_jour) > 500000, 'OK', 'KO')          AS collecte,
    if((SELECT count() FROM gold.energie_commune_jour) > 0, 'OK', 'KO')            AS energie,
    if((SELECT count() FROM gold.synthese_collectivite_jour) > 0, 'OK', 'KO')      AS synthese,
    if((SELECT count() FROM gold.kpi_completude_jour) = 31, 'OK', 'KO')            AS kpi_9h,
    if((SELECT count() FROM gold.alertes_pmax) > 0, 'OK', 'KO')                    AS alertes
SETTINGS select_sequential_consistency = 1;   -- lire la dernière version, quelle que soit la réplique
