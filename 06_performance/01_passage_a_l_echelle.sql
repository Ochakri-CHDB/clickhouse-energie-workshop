-- =====================================================================
--  MODULE 6 · Passage à l'échelle : 1 million de compteurs, 1,5 milliard de points
-- =====================================================================
--  Jusqu'ici : 20 000 PRM. On passe au parc complet du simulateur :
--  1 000 000 de PRM × 31 jours × 48 demi-heures = 1 488 000 000 points.
--  On écrit directement en silver (sans passer par le JSON) pour mesurer
--  la vitesse brute d'écriture et de lecture de ClickHouse.
--
--  La console abandonne une instruction au-delà de ~60 s. On insère donc
--  en 8 lots de 125 000 PRM (186 M de points chacun), une instruction par lot.
-- =====================================================================


-- ÉTAPE 1 · La table (même modèle que silver.courbe_charge)
--  On y déclare dès maintenant deux accélérateurs, mesurés au fichier suivant :
--    · une PROJECTION : une copie pré-agrégée par horodatage, que ClickHouse
--      tient à jour à chaque INSERT, comme un index qui contiendrait déjà les sommes ;
--    · un INDEX DE SAUT minmax : pour chaque granule (8 192 lignes), le min et le
--      max de valeur_w. Une requête "valeur_w > X" saute les granules dont le max
--      est inférieur à X sans les lire (règle query-index-skipping-indices).
--  Les déclarer AVANT de charger coûte un peu de temps à l'insertion.
--  Les ajouter APRÈS (ALTER … MATERIALIZE) réécrit toute la table : voir 02.
CREATE OR REPLACE TABLE silver.courbe_charge_xl
(
    id_prm    UInt64,
    grandeur  LowCardinality(String),
    ts        DateTime('UTC') CODEC(Delta, ZSTD(1)),
    valeur_w  UInt32          CODEC(T64, ZSTD(1)),
    INDEX idx_valeur valeur_w TYPE minmax GRANULARITY 1,
    PROJECTION p_courbe_nationale (SELECT ts, sum(valeur_w), count() GROUP BY ts)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (grandeur, id_prm, ts);   -- du moins au plus cardinal : 2 valeurs, puis le PRM, puis le temps


-- ÉTAPE 2 · Le générateur, rangé dans une vue paramétrée
--  Point n° k : PRM n° k / 1488, demi-heure n° k % 1488.
--  numbers_mt est la version parallèle de numbers() : les blocs de nombres
--  sont produits et transformés sur tous les cœurs de la réplique en même temps.
CREATE OR REPLACE VIEW simulateur.points_xl AS
WITH
    sim_id_prm(intDiv(number, 1488))                                                        AS id,
    toDateTime('2026-10-01 00:30:00', 'Europe/Paris') + toIntervalSecond(1800 * (number % 1488)) AS t,
    dictGet('simulateur.dict_prm', ('profil', 'puissance_kva'), id)                         AS a
SELECT
    id                              AS id_prm,
    'CONS'                          AS grandeur,
    t                               AS ts,
    sim_conso_w(id, a.1, a.2, t)    AS valeur_w
FROM numbers_mt({debut:UInt64} * 1488, {nb:UInt64} * 1488);


-- ÉTAPE 3 · 1,5 milliard de points, en 8 INSERT … SELECT
--  Gros lots = peu de parts = peu de merges (règle insert-batch-size).
--  max_insert_threads = 8 : 8 flux d'écriture en parallèle sur la réplique.
--  Un INSERT s'exécute sur UNE réplique : sa vitesse dépend des cœurs de cette réplique.
INSERT INTO silver.courbe_charge_xl SELECT * FROM simulateur.points_xl(debut = 0,      nb = 125000) SETTINGS max_insert_threads = 8;
-- Mesuré : 8,38 s · 186 M lignes lues (1,4 Go) · 186 M lignes écrites · 1,1 Go de mémoire
INSERT INTO silver.courbe_charge_xl SELECT * FROM simulateur.points_xl(debut = 125000, nb = 125000) SETTINGS max_insert_threads = 8;
-- Mesuré : 8,3 s · 186 M lignes lues (1,4 Go) · 186 M lignes écrites · 1,2 Go de mémoire
INSERT INTO silver.courbe_charge_xl SELECT * FROM simulateur.points_xl(debut = 250000, nb = 125000) SETTINGS max_insert_threads = 8;
-- Mesuré : 8,7 s · 186 M lignes lues (1,4 Go) · 186 M lignes écrites · 1,1 Go de mémoire
INSERT INTO silver.courbe_charge_xl SELECT * FROM simulateur.points_xl(debut = 375000, nb = 125000) SETTINGS max_insert_threads = 8;
-- Mesuré : 8,31 s · 186 M lignes lues (1,4 Go) · 186 M lignes écrites · 1,2 Go de mémoire
INSERT INTO silver.courbe_charge_xl SELECT * FROM simulateur.points_xl(debut = 500000, nb = 125000) SETTINGS max_insert_threads = 8;
-- Mesuré : 8,18 s · 186 M lignes lues (1,4 Go) · 186 M lignes écrites · 1,2 Go de mémoire
INSERT INTO silver.courbe_charge_xl SELECT * FROM simulateur.points_xl(debut = 625000, nb = 125000) SETTINGS max_insert_threads = 8;
-- Mesuré : 8,66 s · 186 M lignes lues (1,4 Go) · 186 M lignes écrites · 1,1 Go de mémoire
INSERT INTO silver.courbe_charge_xl SELECT * FROM simulateur.points_xl(debut = 750000, nb = 125000) SETTINGS max_insert_threads = 8;
-- Mesuré : 8,23 s · 186 M lignes lues (1,4 Go) · 186 M lignes écrites · 1,1 Go de mémoire
INSERT INTO silver.courbe_charge_xl SELECT * FROM simulateur.points_xl(debut = 875000, nb = 125000) SETTINGS max_insert_threads = 8;
-- Mesuré : 8,22 s · 186 M lignes lues (1,4 Go) · 186 M lignes écrites · 1,1 Go de mémoire
-- À observer : en bas de la console, les lignes/s de chaque lot. Chaque point est
-- calculé (dictGet + sim_conso_w), trié selon l'ORDER BY, compressé puis écrit sur S3.


-- ÉTAPE 4 · Ce que ça pèse
SELECT
    formatReadableQuantity(sum(rows))                                AS points,
    formatReadableSize(sum(data_uncompressed_bytes))                 AS brut,
    formatReadableSize(sum(data_compressed_bytes))                   AS sur_disque,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio,
    round(sum(data_compressed_bytes) / sum(rows), 2)                 AS octets_par_point
FROM system.parts
WHERE database = 'silver' AND table = 'courbe_charge_xl' AND active
SETTINGS select_sequential_consistency = 1;
-- À observer : environ 1,4 octet par point. Un point "brut" (8 + 1 + 4 + 4 octets)
-- en pèse 17 : la compression divise par plus de 10.

--  Colonne par colonne : ici les parts dépassent 1 Go, elles sont "wide"
--  (une colonne = un fichier) et system.parts_columns donne leur taille.
SELECT
    column,
    formatReadableSize(sum(column_data_compressed_bytes))   AS sur_disque,
    round(sum(column_data_uncompressed_bytes) / sum(column_data_compressed_bytes), 1) AS ratio
FROM system.parts_columns
WHERE database = 'silver' AND table = 'courbe_charge_xl' AND active
  AND NOT startsWith(column, '_')          -- colonnes techniques internes
GROUP BY column
ORDER BY sum(column_data_compressed_bytes) DESC;
-- À observer : ts (Delta) et grandeur (LowCardinality) ne coûtent presque rien,
-- id_prm non plus car les lignes sont triées par PRM. Le gros, c'est la mesure,
-- qui contient le bruit réel de la consommation et se compresse peu.

--  À l'échelle d'un grand territoire (3,5 M de PRM × 365 jours × 48 points ≈ 61 milliards) :
SELECT formatReadableSize(61e9 * (
    SELECT sum(data_compressed_bytes) / sum(rows) FROM system.parts
    WHERE database = 'silver' AND table = 'courbe_charge_xl' AND active)) AS estimation_un_an_de_courbes;
-- À observer : moins de 100 Go pour une année complète de courbes pour 3,5 M de compteurs.


-- CHECKPOINT
--  1 488 000 000 points attendus (8 lots de 186 000 000).
SELECT
    if((SELECT count() FROM silver.courbe_charge_xl) = 1488000000, 'OK', 'KO') AS points_xl
SETTINGS select_sequential_consistency = 1;
