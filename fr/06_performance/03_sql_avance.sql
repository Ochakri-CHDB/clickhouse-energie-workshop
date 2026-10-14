-- =====================================================================
--  MODULE 6 · SQL avancé sur les courbes de charge
-- =====================================================================
--  Sept outils SQL qui reviennent tout le temps sur des séries temporelles.
--  Ils s'exécutent sur silver.courbe_charge (les 20 000 PRM des fichiers JSON).
-- =====================================================================


-- 1 · Moyenne glissante sur 2 heures (window function)
--  OVER (ORDER BY ts ROWS BETWEEN 3 PRECEDING AND CURRENT ROW) : pour chaque
--  ligne, la moyenne de la ligne et des 3 précédentes, soit 4 demi-heures = 2 h.
--  La fenêtre lisse le bruit sans regrouper les lignes.
SELECT
    toTimeZone(ts, 'Europe/Paris')                                         AS heure,
    valeur_w,
    round(avg(valeur_w) OVER (ORDER BY ts ROWS BETWEEN 3 PRECEDING AND CURRENT ROW)) AS moyenne_2h
FROM silver.courbe_charge FINAL
WHERE id_prm = sim_id_prm(7) AND grandeur = 'CONS' AND jour = '2026-10-15'
ORDER BY ts;
-- Mesuré : 12 ms · 49 152 lignes lues (1,3 Mo)


-- 2 · Rendre les TROUS visibles : WITH FILL
--  Prenons un PRM-jour incomplet repéré par le suivi de collecte.
--  ORDER BY … WITH FILL ajoute les lignes manquantes de la série, de FROM à TO,
--  par pas de STEP (1800 s). Les colonnes des lignes ajoutées prennent leur
--  valeur par défaut (0) : on repère les trous grâce à la colonne recu.
WITH (
    SELECT (id_prm, jour) FROM gold.collecte_prm_jour
    GROUP BY id_prm, jour
    HAVING uniqExactMerge(points_recus) BETWEEN 40 AND 47
    ORDER BY jour, id_prm LIMIT 1
) AS cible
SELECT toTimeZone(ts, 'Europe/Paris') AS heure, valeur_w, if(recu = 0, 'manquant', '') AS statut
FROM
(
    SELECT ts, valeur_w, 1 AS recu                    -- les lignes ajoutées par WITH FILL auront recu = 0
    FROM silver.courbe_charge FINAL
    WHERE id_prm = cible.1 AND grandeur = 'CONS' AND jour = cible.2
    ORDER BY ts WITH FILL
        FROM toDateTime(assumeNotNull(cible.2), 'Europe/Paris') + 1800     -- assumeNotNull : WITH FILL veut
        TO   toDateTime(assumeNotNull(cible.2) + 1, 'Europe/Paris') + 1    -- une constante non Nullable
        STEP 1800
);
-- Mesuré : 112 ms · 668 312 lignes lues (78 Mo) · 896,9 Mo de mémoire
-- À observer : la demi-heure manquante apparaît avec valeur_w = 0 et le statut "manquant".


-- 3 · L'heure de pointe de chaque PRM (argMax), en un seul passage
--  argMax(ts, valeur_w) renvoie le ts de la ligne où valeur_w est maximale :
--  pas besoin de sous-requête ni de jointure pour retrouver "l'heure du max".
SELECT
    dictGet('ref.dict_prm', 'profil', id_prm)                AS profil,
    toHour(argMax(ts, valeur_w), 'Europe/Paris')             AS heure_de_pointe,
    count()                                                  AS nb_prm
FROM silver.courbe_charge FINAL
WHERE grandeur = 'CONS' AND jour = '2026-10-15'
GROUP BY id_prm
ORDER BY profil, heure_de_pointe;   -- regroupez visuellement : RES le soir, PRO en journée
-- Mesuré : 183 ms · 30,5 M lignes lues (785,6 Mo) · 347,5 Mo de mémoire


-- 4 · Profil type : semaine vs week-end, par heure locale
--  avgIf(valeur, condition) : une moyenne filtrée. Deux colonnes en un seul scan.
SELECT
    toHour(ts - 900, 'Europe/Paris')                                        AS heure,
    round(avgIf(valeur_w, toDayOfWeek(ts, 0, 'Europe/Paris') <= 5))         AS semaine_w,
    round(avgIf(valeur_w, toDayOfWeek(ts, 0, 'Europe/Paris') >= 6))         AS weekend_w,
    bar(semaine_w, 0, 3000, 25)                                             AS graphe_semaine
FROM silver.courbe_charge FINAL
WHERE grandeur = 'CONS' AND dictGet('ref.dict_prm', 'profil', id_prm) = 'PRO'
GROUP BY heure
ORDER BY heure;
-- Mesuré : 188 ms · 23,4 M lignes lues (552,3 Mo) · 322,9 Mo de mémoire


-- 5 · Distribution par segment : quantiles et facteur de charge
--  quantiles(0.5, 0.9, 0.99) calcule plusieurs percentiles en une passe.
--  Le facteur de charge (moyenne / max) dit si un site consomme régulièrement.
SELECT
    dictGet('ref.dict_prm', 'segment', id_prm)       AS segment,
    quantiles(0.5, 0.9, 0.99)(valeur_w)               AS p50_p90_p99_w,
    round(avg(valeur_w) / max(valeur_w), 3)           AS facteur_de_charge
FROM silver.courbe_charge FINAL
WHERE grandeur = 'CONS'
GROUP BY segment
ORDER BY segment;
-- Mesuré : 234 ms · 30,5 M lignes lues (727,1 Mo) · 402,8 Mo de mémoire


-- 6 · ASOF JOIN : la puissance souscrite "à date", sans dictionnaire
--  Pour chaque PMax, ASOF JOIN prend la ligne d'historique la plus récente dont
--  valid_from est antérieure ou égale au jour. Même résultat que le dictionnaire
--  RANGE_HASHED du module 4, sous forme de jointure.
SELECT
    p.id_prm, p.jour, p.pmax_va, h.puissance_kva AS kva_a_date,
    p.pmax_va > h.puissance_kva * 1000 AS depassement
FROM silver.pmax_jour AS p FINAL
ASOF JOIN ref.prm_history AS h ON p.id_prm = h.id_prm AND p.jour >= h.valid_from
WHERE p.id_prm IN (SELECT id_prm FROM ref.prm_history WHERE valid_to BETWEEN '2026-10-01' AND '2026-10-30' LIMIT 3)
ORDER BY p.id_prm, p.jour
LIMIT 20;
-- Mesuré : 58 ms · 2,1 M lignes lues (22,6 Mo) · 262,8 Mo de mémoire


-- 7 · Autoproduction : à quelle heure la production couvre-t-elle la conso ?
--  sumIf sépare CONS et PROD dans la même requête. On réutilise les alias
--  prod_kw et conso_kw dans le calcul suivant : ClickHouse l'autorise.
SELECT
    toHour(ts - 900, 'Europe/Paris')                             AS heure,
    round(sumIf(valeur_w, grandeur = 'PROD') / 1000)             AS prod_kw,
    round(sumIf(valeur_w, grandeur = 'CONS') / 1000)             AS conso_kw,
    round(100 * prod_kw / conso_kw, 1)                           AS couverture_pct
FROM silver.courbe_charge FINAL
WHERE id_prm IN (SELECT id_prm FROM ref.prm WHERE kwc_pv > 0)
  AND jour = '2026-10-15'
GROUP BY heure
ORDER BY heure;
-- Mesuré : 136 ms · 13,6 M lignes lues (331 Mo) · 365,2 Mo de mémoire
