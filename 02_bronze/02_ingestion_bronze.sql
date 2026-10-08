-- =====================================================================
--  MODULE 2 · Bronze : les fichiers JSON tels qu'ils arrivent
-- =====================================================================
--  Règle d'or du bronze : on stocke le brut, on ne transforme rien.
--  Une ligne = un fichier reçu (1000 PRM, 1 journée).
--  Volume : 20 000 PRM × 31 jours, flux CDC (courbes 30 min), ENERGIE (énergie jour), PMAX (puissance max)
--  Destinataires : les 6 métropoles (12 lots pour le Grand Paris, 2 pour Lyon…)
--
--  Pourquoi garder le brut ? Si une règle de parsing change ou si un bug est
--  corrigé, on peut tout reconstruire depuis bronze (module 7), sans redemander
--  les fichiers au gestionnaire de réseau.
-- =====================================================================


-- ÉTAPE 1 · La table bronze
CREATE OR REPLACE TABLE bronze.flux_raw
(
    file_name    String,
    code_flux    LowCardinality(String),        -- CDC / ENERGIE / PMAX
    ingested_at  DateTime64(3, 'UTC'),          -- heure d'arrivée du fichier
    payload      String CODEC(ZSTD(3))          -- le JSON brut. ZSTD(3) compresse plus fort que le défaut (LZ4) : idéal pour du texte peu relu
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ingested_at)              -- une partition par mois : peu nombreuses, faciles à purger (TTL, module 7)
ORDER BY (code_flux, ingested_at, file_name);   -- on relit bronze par flux puis par date d'arrivée


-- ÉTAPE 2 · Une seule journée de courbes CDC (20 fichiers, ~1 million de points)
--  Ce que fait la requête, de l'intérieur vers l'extérieur :
--    numbers(0, 20)   → 20 fichiers (lots de 1000 PRM)
--    dictGet          → profil, puissance, panneaux solaires de chaque PRM
--    arrayMap         → pour chaque PRM, ses 48 points de la journée
--    CAST + toJSONString → le fichier JSON final, aux noms de champs du format source
INSERT INTO bronze.flux_raw
WITH
    toDate('2026-10-01') + intDiv(number, 20)                                  AS jour,
    number % 20                                                                 AS lot,
    -- arrivée : le lendemain entre 6h et 8h, sauf ~1 % de fichiers en retard (l'après-midi)
    toDateTime64(toDateTime(jour + 1, 'Europe/Paris'), 3, 'UTC')
        + toIntervalSecond(if(sim_alea(jour, lot, 'retard') < 0.01, 50400, 21600 + lot * 300 + cityHash64(jour, lot) % 240)) AS arrivee,
    sim_points_du_jour(jour)                                                    AS horodatages,
    -- ~0,3% des PRM n'ont rien remonté ce jour-là (panne de communication)
    arrayFilter(n -> sim_alea(n, jour, 'panne') >= 0.003, range(lot * 1000, lot * 1000 + 1000)) AS ns,
    arrayMap(n -> sim_id_prm(n), ns)                                            AS ids,
    arrayMap(id -> dictGet('simulateur.dict_prm', ('profil', 'puissance_kva', 'kwc_pv', 'code_dept'), id), ids) AS attrs
SELECT
    concat('GRD_CDC_30MIN_PUB_', toString(100000 + number), '_', sim_destinataire(lot), '_', formatDateTime(arrivee, '%Y%m%d%H%i%S'), '.zip') AS file_name,
    'CDC'   AS code_flux,
    arrivee AS ingested_at,
    toJSONString(CAST((
        ('PORTAIL DONNEES', 'COLLECTIVITE', sim_destinataire(lot), 'CDC30', toString(100000 + number), 'RECURRENT', 'JSON'),
        arrayMap((id, a) -> (
            leftPad(toString(id), 14, '0'),
            'BRUT',
            (toString(jour), toString(jour + 1)),
            'PT30M',
            arrayConcat(
                -- la consommation : ~0,02% de points manquants, ~0,03% de valeurs vides (rejets)
                [('PA', 'CONS', 'W',
                  arrayMap(t -> (sim_iso(t), if(sim_alea(id, t, 'ko') < 0.0003, '', toString(sim_conso_w(id, a.1, a.2, t)))),
                           arrayFilter(t -> sim_alea(id, t, 'trou') >= 0.0002, horodatages)))],
                -- la production, seulement pour les PRM équipés de panneaux
                if(a.3 > 0,
                   [('PA', 'PROD', 'W', arrayMap(t -> (sim_iso(t), toString(sim_prod_w(id, a.4, a.3, t))), horodatages))],
                   []))
        ), ids, attrs)
    ), 'Tuple(header Tuple(siDemandeur String, typeDestinataire String, idDestinataire String, codeFlux String, idPublication String, modePublication String, format String),
              mesures Array(Tuple(idPrm String, etapeMetier String, periode Tuple(dateDebut String, dateFin String), pas String,
                                  grandeur Array(Tuple(grandeurPhysique String, grandeurMetier String, unite String,
                                                       points Array(Tuple(d String, v String)))))))')) AS payload
FROM numbers(0, 20)
SETTINGS max_block_size = 2;   -- 2 fichiers par bloc : chaque fichier pèse ~2 Mo de JSON, on garde la mémoire basse
-- Mesuré : 697 ms · 20 fichiers JSON générés et écrits (46 Mo) · 208,5 Mo de mémoire

--  Qu'avons-nous reçu ? length() donne la taille du JSON en octets.
SELECT code_flux, count() AS fichiers, formatReadableSize(sum(length(payload))) AS volume_json
FROM bronze.flux_raw
GROUP BY code_flux;
-- Mesuré : 6 ms · 20 lignes lues

--  Un fichier, comme dans le bucket S3
SELECT file_name, ingested_at, substring(payload, 1, 600) AS debut_du_json
FROM bronze.flux_raw
LIMIT 1;
-- Mesuré : 13 ms · 5 lignes lues (11,5 Mo)


-- ÉTAPE 3 · Le reste du mois : jours 2 à 30 (580 fichiers, ~28 millions de points)
--  La requête de l'étape 2 est rangée dans une VUE PARAMÉTRÉE (simulateur.fichiers_cdc).
--  On l'appelle comme une fonction. Le jour 31 est gardé pour le module 3.
--  Un seul INSERT de 580 fichiers plutôt que 580 petits INSERT : chaque INSERT
--  crée une part, et peu de grosses parts coûtent moins cher à fusionner
--  (règle insert-batch-size).
INSERT INTO bronze.flux_raw
SELECT * FROM simulateur.fichiers_cdc(debut = 20, nb = 580)
SETTINGS max_block_size = 2;
-- Mesuré : 11,32 s · 580 fichiers générés et écrits (1,30 Go de JSON) · 2,2 Go de mémoire
-- À observer : la durée couvre la génération ET l'écriture de ~1,3 Go de JSON.


-- ÉTAPE 4 · Les flux journaliers : ENERGIE (énergie) et PMAX (puissance max)
INSERT INTO bronze.flux_raw
SELECT * FROM simulateur.fichiers_energie(debut = 0, nb = 600)
SETTINGS max_block_size = 4;
-- Mesuré : 3,51 s · 600 fichiers ENERGIE (168 Mo de JSON) · 769,9 Mo de mémoire

INSERT INTO bronze.flux_raw
SELECT * FROM simulateur.fichiers_pmax(debut = 0, nb = 600)
SETTINGS max_block_size = 4;
-- Mesuré : 5,39 s · 600 fichiers PMAX (145 Mo de JSON) · 445,6 Mo de mémoire


-- ÉTAPE 5 · Bilan de l'ingestion
SELECT
    code_flux,
    count()                                                        AS fichiers,
    min(ingested_at)                                               AS premier,
    max(ingested_at)                                               AS dernier,
    formatReadableSize(sum(length(payload)))                       AS json_brut
FROM bronze.flux_raw
GROUP BY code_flux
ORDER BY code_flux;
-- Mesuré : 58 ms · 1 800 lignes lues (29,9 Ko)

--  Combien ça pèse vraiment sur disque ? (compression ZSTD du JSON)
--  À observer : le JSON est très répétitif (mêmes clés, mêmes dates) : il se
--  compresse d'un facteur 10 à 15.
SELECT
    formatReadableSize(sum(data_uncompressed_bytes))                 AS brut,
    formatReadableSize(sum(data_compressed_bytes))                   AS sur_disque,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes)) AS ratio
FROM system.parts
WHERE database = 'bronze' AND table = 'flux_raw' AND active;

--  Les parts créées par nos INSERT
--  Le nom d'une part (202610_0_5_1) donne la partition, la plage de blocs et le
--  niveau de fusion. Relancez la requête dans une minute : les merges en arrière-plan
--  en auront réduit le nombre.
SELECT partition, name, rows, formatReadableSize(bytes_on_disk) AS taille, modification_time
FROM system.parts
WHERE database = 'bronze' AND table = 'flux_raw' AND active
ORDER BY modification_time;


-- CHECKPOINT MODULE 2
--  600 fichiers par flux : 20 lots × 30 jours (le 31 arrive au module 3).
SELECT
    if(countIf(code_flux = 'CDC') = 600, 'OK', 'KO') AS cdc_600_fichiers,
    if(countIf(code_flux = 'ENERGIE') = 600, 'OK', 'KO') AS energie_600_fichiers,
    if(countIf(code_flux = 'PMAX') = 600, 'OK', 'KO') AS pmax_600_fichiers
FROM bronze.flux_raw
SETTINGS select_sequential_consistency = 1;   -- lire la dernière version, quelle que soit la réplique
