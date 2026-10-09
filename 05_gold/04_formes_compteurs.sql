-- =====================================================================
--  MODULE 5 · Gold (4/4) : la forme de consommation de chaque compteur
-- =====================================================================
--  Une table de "features" pour la data science (module 8, agent + Run Code).
--  Chaque compteur est résumé par sa forme moyenne : 24 valeurs pour un jour
--  de semaine et 24 pour un jour de week-end, divisées par sa consommation
--  moyenne (1 = la moyenne du compteur). 30 M de points deviennent 20 000 lignes.
--
--  Bonne pratique : on prépare les données dans ClickHouse (rapide, au plus
--  près des données), et on n'envoie au modèle Python que le petit résultat.
-- =====================================================================


-- ÉTAPE 1 · La table : une ligne par compteur, les formes dans des tableaux
--  Array(Float32) : 24 valeurs dans une seule colonne, lisibles d'un bloc.
--  ORDER BY (segment, profil, id_prm) : on échantillonne souvent par segment.
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
ORDER BY (segment, profil, id_prm);


-- ÉTAPE 2 · Le calcul, en une requête
--  La sous-requête fait la moyenne par compteur, type de jour et heure locale.
--  groupArrayIf rassemble les 24 heures d'un type de jour dans un tableau,
--  arraySort((x, h) -> h, ...) les remet dans l'ordre des heures,
--  et arrayMap divise chaque valeur par la moyenne du compteur.
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
-- Mesuré : 817 ms · 30,1 M lignes lues (744,7 Mo) · 19 999 lignes écrites · 544,1 Mo de mémoire


-- ÉTAPE 3 · Des commentaires pour l'agent (module 8)
ALTER TABLE gold.profil_prm
    MODIFY COMMENT 'Forme de consommation moyenne de chaque compteur en octobre 2026, pour la data science. Une ligne par compteur.';
-- Mesuré : 74 ms
ALTER TABLE gold.profil_prm
    COMMENT COLUMN segment       'C5 (jusqu''à 36 kVA), C4 (36 à 250 kVA), C2 (raccordé en HTA)',
    COMMENT COLUMN profil        'Profil déclaré : RES (résidentiel), PRO (professionnel), ENT (entreprise, industrie)',
    COMMENT COLUMN conso_moy_w   'Puissance moyenne du compteur sur le mois, en W',
    COMMENT COLUMN forme_semaine '24 valeurs, de 0h à 23h (heure de Paris), jour de semaine, divisées par conso_moy_w',
    COMMENT COLUMN forme_weekend '24 valeurs, de 0h à 23h (heure de Paris), jour de week-end, divisées par conso_moy_w';
-- Mesuré : 79 ms


-- ÉTAPE 4 · Les formes moyennes par profil
SELECT profil, count() AS compteurs, arrayMap(x -> round(x, 1), any(forme_semaine)) AS exemple_semaine
FROM gold.profil_prm
GROUP BY profil;
-- Mesuré : 8 ms · 19 999 lignes lues (2 Mo)
-- À observer : la pointe du soir des foyers (RES), le plateau 8h-19h des
-- professionnels (PRO), le talon élevé de l'industrie (ENT).

--  L'échantillon que l'agent utilisera : 30 compteurs par segment, en une requête
SELECT segment, profil, count() AS compteurs
FROM (SELECT segment, profil FROM gold.profil_prm ORDER BY cityHash64(id_prm) LIMIT 30 BY segment)
GROUP BY segment, profil
ORDER BY segment, profil;
-- Mesuré : 4 ms · 19 999 lignes lues (195,4 Ko)
-- À observer : LIMIT 30 BY segment garde 30 lignes par valeur de segment.
-- Le segment C5 mélange foyers et petits professionnels.


-- CHECKPOINT MODULE 5 (4/4)
--  Une ligne par compteur des fichiers JSON (20 000, ou 19 999 si le module 7 a déjà
--  supprimé un compteur), avec 24 valeurs par forme.
SELECT
    if((SELECT count() FROM gold.profil_prm) >= 19999, 'OK', 'KO') AS formes,
    if((SELECT min(length(forme_semaine)) FROM gold.profil_prm) = 24, 'OK', 'KO') AS longueur_24
SETTINGS select_sequential_consistency = 1;
