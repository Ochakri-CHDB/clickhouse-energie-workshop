-- =====================================================================
--  MODULE 3 · Backfill de l'historique, puis flux continu
-- =====================================================================


-- ÉTAPE 1 · Backfill : on rejoue bronze dans les MV, en un INSERT … SELECT
--  On exécute nous-mêmes la requête de la MV, sur tout l'historique bronze.
--  Attention : il faut le faire APRÈS avoir créé la MV, sinon les fichiers
--  arrivés entre-temps seraient perdus. Ici bronze ne reçoit rien pendant l'opération.
INSERT INTO silver.courbe_charge
SELECT
    toUInt64(m.idPrm), g.grandeurMetier, parseDateTimeBestEffort(p.d, 'UTC'), toUInt32(p.v),
    toUInt8(extract(m.pas, '\\d+')), m.etapeMetier, ingested_at
FROM bronze.flux_raw
ARRAY JOIN JSONExtract(payload, 'mesures',
    'Array(Tuple(idPrm String, etapeMetier String, pas String, grandeur Array(Tuple(grandeurMetier String, points Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.grandeur AS g
ARRAY JOIN g.points   AS p
WHERE code_flux = 'CDC' AND toUInt32OrNull(p.v) IS NOT NULL
SETTINGS max_block_size = 4;
-- Mesuré : 18,1 s · 600 fichiers lus (1,3 Go de JSON) · 29,9 M lignes écrites · 1,7 Go de mémoire
-- À observer : ~30 millions de points extraits du JSON. Regardez la vitesse en lignes/s
-- en bas de la console : tout le parsing JSON se fait dans la base.

INSERT INTO silver.rejets
SELECT ingested_at, file_name, code_flux, m.idPrm, p.d, p.v, 'valeur non numérique'
FROM bronze.flux_raw
ARRAY JOIN JSONExtract(payload, 'mesures', 'Array(Tuple(idPrm String, grandeur Array(Tuple(points Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.grandeur AS g
ARRAY JOIN g.points   AS p
WHERE code_flux = 'CDC' AND toUInt32OrNull(p.v) IS NULL
SETTINGS max_block_size = 4;
-- Mesuré : 2,67 s · 600 fichiers lus (1,3 Go de JSON) · 8 754 lignes écrites · 1 018,2 Mo de mémoire

INSERT INTO silver.energie_jour
SELECT toUInt64(m.idPrm), g.grandeurMetier, toDate(p.d), toDecimal64(p.v, 2), m.etapeMetier, ingested_at
FROM bronze.flux_raw
ARRAY JOIN JSONExtract(payload, 'mesures', 'Array(Tuple(idPrm String, etapeMetier String, grandeur Array(Tuple(grandeurMetier String, points Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.grandeur AS g
ARRAY JOIN g.points   AS p
WHERE code_flux = 'ENERGIE';
-- Mesuré : 755 ms · 600 fichiers lus (168,3 Mo de JSON) · 625 080 lignes écrites · 327,4 Mo de mémoire

INSERT INTO silver.pmax_jour
SELECT toUInt64(m.idPrm), toDate(m.periode.dateDebut), toUInt32(p.v), parseDateTimeBestEffort(p.d, 'UTC'), ingested_at
FROM bronze.flux_raw
ARRAY JOIN JSONExtract(payload, 'mesures', 'Array(Tuple(idPrm String, periode Tuple(dateDebut String), grandeur Array(Tuple(points Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.grandeur AS g
ARRAY JOIN g.points   AS p
WHERE code_flux = 'PMAX';
-- Mesuré : 675 ms · 600 fichiers lus (144,9 Mo de JSON) · 600 000 lignes écrites · 407,3 Mo de mémoire

SELECT
    (SELECT count() FROM silver.courbe_charge) AS points_courbe,
    (SELECT count() FROM silver.energie_jour)  AS lignes_energie,
    (SELECT count() FROM silver.pmax_jour)     AS lignes_pmax,
    (SELECT count() FROM silver.rejets)        AS rejets;
-- Mesuré : 4 ms · 5 lignes lues


-- ÉTAPE 2 · Le flux continu : le 31 octobre arrive
--  On insère SEULEMENT en bronze. Regardez silver se remplir tout seul.
--  La chaîne complète se déclenche : bronze → MV → silver → MV (module 5) → gold.
SELECT count() AS points_avant FROM silver.courbe_charge WHERE jour = '2026-10-31';
-- Mesuré : 65 ms · 29,9 M lignes lues (57,1 Mo)

INSERT INTO bronze.flux_raw
SELECT * FROM simulateur.fichiers_cdc(debut = 600, nb = 20)
SETTINGS max_block_size = 2;
-- Mesuré : 5,95 s · 100 fichiers lus (183,8 Mo de JSON) · 996 328 lignes écrites · 306,1 Mo de mémoire

SELECT count() AS points_apres FROM silver.courbe_charge WHERE jour = '2026-10-31';
-- Mesuré : 65 ms · 25 M lignes lues (47,8 Mo)
-- À observer : le nombre de points du 31 passe de 0 à ~1 million, sans aucun job.
-- C'est exactement ce que fera ClickPipes : il insère en bronze, les MV propagent.


-- ÉTAPE 3 · Ce que la compression fait aux courbes
--  À observer : bronze (JSON) pèse des dizaines de kilo-octets par fichier, silver
--  environ 1,5 octet par point. Le format colonnaire typé est le vrai gain.
SELECT
    table,
    formatReadableQuantity(sum(rows))                                AS lignes,
    formatReadableSize(sum(data_uncompressed_bytes))                 AS brut,
    formatReadableSize(sum(data_compressed_bytes))                   AS sur_disque,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes)) AS ratio,
    round(sum(data_compressed_bytes) / sum(rows), 2)                 AS octets_par_point
FROM system.parts
WHERE database IN ('bronze', 'silver') AND active
GROUP BY table
ORDER BY sum(data_compressed_bytes) DESC;

--  Par colonne (tailles lisibles grâce à min_bytes_for_wide_part = 0, voir module 1).
--  À observer : ts et id_prm ne coûtent presque rien grâce au tri et aux codecs ;
--  valeur_w, qui contient le "bruit" des mesures, pèse le plus.
SELECT name, type, compression_codec,
       formatReadableSize(data_compressed_bytes) AS sur_disque,
       round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio
FROM system.columns
WHERE database = 'silver' AND table = 'courbe_charge';


-- CHECKPOINT
--  Plus de 28 M de points, 600 000 PMax (20 000 PRM × 30 jours) et le 31 arrivé par le flux.
SELECT
    if((SELECT count() FROM silver.courbe_charge) > 28000000, 'OK', 'KO') AS courbes,
    if((SELECT count() FROM silver.energie_jour)  > 600000,   'OK', 'KO') AS energie,
    if((SELECT count() FROM silver.pmax_jour)     = 600000,   'OK', 'KO') AS pmax,
    if((SELECT count() FROM silver.courbe_charge WHERE jour = '2026-10-31') > 900000, 'OK', 'KO') AS flux_continu
SETTINGS select_sequential_consistency = 1;   -- lire la dernière version, quelle que soit la réplique
