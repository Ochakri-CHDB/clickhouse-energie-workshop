-- =====================================================================
--  MODULE 1 · Fondamentaux : bases, MergeTree et référentiels
-- =====================================================================
--  On crée les 4 couches du pipeline et les référentiels :
--    ref     → communes (vraies données INSEE), PRM, collectivités
--    bronze  → fichiers JSON bruts, tels que reçus
--    silver  → mesures typées, nettoyées, dédupliquées
--    gold    → KPIs prêts pour les dashboards
--
--  Une "base" ClickHouse est un simple espace de noms : elle ne coûte rien
--  et sert à ranger les tables et à donner des droits par couche.
-- =====================================================================


-- ÉTAPE 1 · Les bases de données (une par couche)
CREATE DATABASE IF NOT EXISTS ref;
CREATE DATABASE IF NOT EXISTS bronze;
CREATE DATABASE IF NOT EXISTS silver;
CREATE DATABASE IF NOT EXISTS gold;
CREATE DATABASE IF NOT EXISTS simulateur;   -- le générateur de données du workshop


-- ÉTAPE 2 · Un utilisateur technique pour les dictionnaires (module 4)
--  Dans la console Cloud, un dictionnaire qui lit une table locale
--  doit déclarer un utilisateur et un mot de passe. On le limite :
--  connexion locale uniquement, lecture seule sur les référentiels.
CREATE USER IF NOT EXISTS dict_reader IDENTIFIED BY 'Dict_Workshop_2026!' HOST LOCAL;
GRANT SELECT ON ref.* TO dict_reader;
GRANT SELECT ON simulateur.* TO dict_reader;


-- ÉTAPE 3 · Les communes françaises, lues EN DIRECT depuis l'API officielle
--  url() lit une ressource HTTP comme une table. Le format JSONEachRow dit
--  à ClickHouse comment découper la réponse : un objet JSON = une ligne.
--  Pas d'ETL, pas de script Python : la base va chercher la donnée elle-même.
SELECT *
FROM url('https://geo.api.gouv.fr/communes?fields=code,nom,codeDepartement,codeRegion,codeEpci,population&format=json', JSONEachRow)
LIMIT 5;
-- Mesuré : 531 ms · 5 lignes lues


-- ÉTAPE 4 · Notre première table MergeTree
--  MergeTree est le moteur de base de ClickHouse. Deux choses à retenir :
--    · ORDER BY fixe l'ordre physique des lignes sur disque ET l'index
--      primaire. On ne peut plus le changer ensuite : on le choisit selon
--      les filtres les plus fréquents (règle schema-pk-plan-before-creation).
--    · chaque colonne est stockée et compressée à part (stockage colonnaire) :
--      une requête ne lit que les colonnes qu'elle utilise.
CREATE OR REPLACE TABLE ref.commune
(
    code_insee   String,
    nom          String,
    code_dept    LowCardinality(String),   -- ~100 valeurs distinctes : stockées une fois, puis des numéros (règle : moins de 10 000 valeurs)
    code_region  LowCardinality(String),
    code_epci    String,                   -- pas de Nullable : '' si absent (règle schema-types-avoid-nullable)
    population   UInt32,                   -- le plus petit type entier qui suffit
    lon          Float32,
    lat          Float32
)
ENGINE = MergeTree
ORDER BY code_insee;

--  On déclare le schéma de la réponse : les champs parfois absents sont lus
--  en Nullable, puis remplacés par une valeur par défaut avec ifNull.
INSERT INTO ref.commune
SELECT
    code, nom, codeDepartement, codeRegion, ifNull(codeEpci, ''), ifNull(population, 0),
    centre.coordinates[1], centre.coordinates[2]
FROM url('https://geo.api.gouv.fr/communes?fields=code,nom,codeDepartement,codeRegion,codeEpci,population,centre&format=json', JSONEachRow,
         'code String, nom String, codeDepartement String, codeRegion String, codeEpci Nullable(String), population Nullable(UInt32), centre Tuple(type String, coordinates Array(Float64))');
-- Mesuré : 471 ms · 34 969 lignes lues (5,9 Mo) · 34 969 lignes écrites
--  Plan B si l'API ne répond pas : le même fichier est dans le repo
--  INSERT INTO ref.commune SELECT * FROM url('https://raw.githubusercontent.com/Ochakri-CHDB/clickhouse-energie-workshop/main/data/communes.csv', CSVWithNames);

CREATE OR REPLACE TABLE ref.departement (code_dept String, nom String, code_region String) ENGINE = MergeTree ORDER BY code_dept;
INSERT INTO ref.departement SELECT code, nom, codeRegion
FROM url('https://geo.api.gouv.fr/departements?fields=code,nom,codeRegion', JSONEachRow, 'code String, nom String, codeRegion String');
-- Mesuré : 314 ms · 101 lignes lues (5 Ko) · 101 lignes écrites

CREATE OR REPLACE TABLE ref.region (code_region String, nom String) ENGINE = MergeTree ORDER BY code_region;
INSERT INTO ref.region SELECT code, nom
FROM url('https://geo.api.gouv.fr/regions?fields=code,nom', JSONEachRow, 'code String, nom String');
-- Mesuré : 121 ms · 18 lignes lues · 18 lignes écrites

CREATE OR REPLACE TABLE ref.epci (code_epci String, nom String) ENGINE = MergeTree ORDER BY code_epci;
INSERT INTO ref.epci SELECT code, nom
FROM url('https://geo.api.gouv.fr/epcis?fields=code,nom', JSONEachRow, 'code String, nom String');
-- Mesuré : 140 ms · 1 255 lignes lues (67 Ko) · 1 255 lignes écrites

SELECT count() AS nb_communes, sum(population) AS population_totale FROM ref.commune;
-- Mesuré : 3 ms · 34 969 lignes lues (136,6 Ko)
-- À observer : environ 35 000 communes et 69 millions d'habitants.


-- ÉTAPE 5 · Les collectivités destinataires des flux
--  Chaque fichier du gestionnaire de réseau est adressé à un destinataire (idDestinataire).
--  On rattache chacun à son EPCI, ce qui permettra de filtrer par territoire.
CREATE OR REPLACE TABLE ref.destinataire
(
    id_destinataire String,
    nom             String,
    code_epci       String
)
ENGINE = MergeTree
ORDER BY id_destinataire;

INSERT INTO ref.destinataire VALUES
    ('488903', 'Métropole du Grand Paris',      '200054781'),
    ('488904', 'Métropole de Lyon',             '200046977'),
    ('488905', 'Métropole Européenne de Lille', '200093201'),
    ('488906', 'Toulouse Métropole',            '243100518'),
    ('488907', 'Bordeaux Métropole',            '243300316'),
    ('488908', 'Nantes Métropole',              '244400404');

--  Les 20 fichiers d'une journée (lots de 1000 PRM) sont répartis entre les
--  6 métropoles, à peu près au prorata de leur population. Une collectivité ne
--  reçoit QUE les compteurs de son territoire : on en tient compte dès le tirage.
--  CREATE FUNCTION crée une fonction SQL (UDF) : une expression nommée,
--  réutilisable dans toutes les requêtes. Ici : numéro de lot → destinataire.
CREATE OR REPLACE FUNCTION sim_destinataire AS (lot) ->
    ['488903', '488903', '488903', '488903', '488903', '488903', '488903', '488903', '488903', '488903',
     '488903', '488903', '488904', '488904', '488905', '488905', '488906', '488906', '488907', '488908'][lot + 1];

SELECT sim_destinataire(lot) AS id_destinataire, count() AS lots, count() * 1000 AS prm
FROM (SELECT number AS lot FROM numbers(20))
GROUP BY id_destinataire
ORDER BY id_destinataire;
-- Mesuré : 3 ms · 20 lignes lues


-- ÉTAPE 6 · Le parc de compteurs : 1 million de PRM générés
--  Chaque PRM est rattaché à une commune, tirée au sort au prorata de
--  sa population. Astuce : un ASOF JOIN sur la population cumulée.
--    · les 20 000 premiers PRM (ceux des fichiers JSON du module 2) sont tirés
--      dans le territoire de leur métropole destinataire ;
--    · les 980 000 autres dans toute la France (le passage à l'échelle du module 6).
--  Répartition calée sur un parc français de distribution : ~98,7 % de C5 (≤ 36 kVA), ~1,1 % de C4
--  (36 à 250 kVA), ~0,2 % de C2 (HTA). Les foyers sont surtout en 6 et 9 kVA.
--
--  Comment marche le tirage au prorata de la population :
--    1. on range les communes et on cumule leur population (fonction de fenêtre) ;
--    2. chaque PRM tire un "ticket" entre 0 et la population totale ;
--    3. ASOF JOIN cherche la PREMIÈRE commune dont le cumul dépasse le ticket.
--  Une grande ville occupe un grand intervalle de cumul : elle est tirée plus souvent.
CREATE OR REPLACE TABLE ref.prm
(
    id_prm             UInt64,                  -- 14 chiffres tiennent dans 8 octets
    code_insee         String,
    segment            LowCardinality(String),  -- C5 / C4 / C2
    profil             LowCardinality(String),  -- RES (résidentiel) / PRO (professionnel) / ENT (entreprise)
    puissance_kva      UInt16,
    tarif              LowCardinality(String),
    kwc_pv             Float32,                 -- puissance photovoltaïque installée (0 = pas de production)
    date_mise_service  Date
)
ENGINE = MergeTree
ORDER BY id_prm
SETTINGS min_bytes_for_wide_part = 0;   -- une colonne = un fichier, pour lire la compression colonne par colonne (étape 8)

INSERT INTO ref.prm
WITH
    zones AS
    (
        -- 'FR' = toute la France, sinon le code de l'EPCI d'une métropole destinataire
        SELECT 'FR' AS zone, code_insee, population FROM ref.commune WHERE population > 0
        UNION ALL
        SELECT code_epci, code_insee, population FROM ref.commune
        WHERE population > 0 AND code_epci IN (SELECT code_epci FROM ref.destinataire)
    ),
    cumul AS
    (
        SELECT zone, code_insee,
               sum(population) OVER (PARTITION BY zone ORDER BY code_insee ROWS UNBOUNDED PRECEDING) AS pop_cumulee
        FROM zones
    ),
    pop_zone AS (SELECT zone, sum(population) AS pop FROM zones GROUP BY zone),
    tirage AS
    (
        SELECT
            z.zone                                                    AS zone,
            n.number                                                  AS n,
            10000000000000 + n.number * 4093 + cityHash64(n.number) % 4093 AS id_prm,
            cityHash64(n.number, 'commune') % z.pop                    AS ticket,
            cityHash64(n.number, 'segment') % 1000                     AS r_seg,
            cityHash64(n.number, 'detail')  % 1000                     AS r_det,
            cityHash64(n.number, 'pv')      % 1000                     AS r_pv
        FROM numbers(1000000) AS n
        LEFT JOIN ref.destinataire AS d ON d.id_destinataire = if(n.number < 20000, sim_destinataire(intDiv(n.number, 1000)), '')
        INNER JOIN pop_zone AS z ON z.zone = if(n.number < 20000, d.code_epci, 'FR')
    )
SELECT
    t.id_prm,
    c.code_insee,
    multiIf(t.r_seg < 987, 'C5', t.r_seg < 998, 'C4', 'C2')                         AS segment,
    multiIf(segment = 'C5' AND t.r_det < 880, 'RES', segment = 'C2', 'ENT', 'PRO')  AS profil,
    multiIf(profil = 'RES', multiIf(t.r_det % 100 < 4, 3, t.r_det % 100 < 44, 6, t.r_det % 100 < 77, 9,
                                    t.r_det % 100 < 90, 12, t.r_det % 100 < 95, 15, t.r_det % 100 < 98, 18,
                                    t.r_det % 100 < 99, 24, 36),                       -- 40 % en 6 kVA, 33 % en 9 kVA
            segment = 'C5', [9, 12, 18, 24, 36][1 + t.r_det % 5],
            segment = 'C4', 37 + t.r_det % 214,
            250 + t.r_det)                                                             AS puissance_kva,
    multiIf(segment = 'C5', ['BASE', 'BASE', 'BASE', 'HPHC', 'HPHC', 'TEMPO'][1 + t.r_det % 6],
            segment = 'C4', ['CU4', 'MU4'][1 + t.r_det % 2],
            'HTA5')                                                                     AS tarif,
    multiIf(profil = 'RES' AND t.r_pv < 40, toFloat32([3, 4.5, 6, 9][1 + t.r_pv % 4]),   -- ~4 % des foyers ont du solaire
            profil = 'PRO' AND t.r_pv < 50, toFloat32(9 + t.r_pv % 27),
            profil = 'ENT' AND t.r_pv < 30, toFloat32(100 + t.r_pv * 3),
            toFloat32(0))                                                               AS kwc_pv,
    toDate('1995-01-01') + cityHash64(t.n, 'date') % 11000                             AS date_mise_service
FROM tirage AS t
ASOF JOIN cumul AS c ON t.zone = c.zone AND t.ticket < c.pop_cumulee;   -- la 1re commune de la zone dont le cumul dépasse le ticket
-- Mesuré : 532 ms · 1,1 M lignes lues (9,5 Mo) · 1 M lignes écrites · 145 Mo de mémoire

SELECT segment, profil, count() AS nb_prm, round(avg(puissance_kva), 1) AS kva_moyen, countIf(kwc_pv > 0) AS nb_avec_pv
FROM ref.prm
GROUP BY segment, profil
ORDER BY nb_prm DESC;
-- Mesuré : 14 ms · 1 M lignes lues (4,1 Mo) · 172,4 Mo de mémoire
-- À observer : un million de lignes générées et jointes en moins d'une seconde.
-- countIf compte seulement les lignes qui vérifient la condition : pas besoin de CASE WHEN.

--  Les 20 000 PRM des fichiers JSON sont bien chez leur destinataire :
SELECT d.nom AS destinataire, count() AS prm
FROM ref.prm AS p
INNER JOIN ref.commune     AS c ON c.code_insee = p.code_insee
INNER JOIN ref.destinataire AS d ON d.code_epci = c.code_epci
WHERE p.id_prm < 10000000000000 + 20000 * 4093
GROUP BY destinataire
ORDER BY prm DESC;
-- Mesuré : 9 ms · 59 551 lignes lues (1 Mo)


-- ÉTAPE 7 · L'historique des puissances souscrites (pour le module 4)
--  ~3 % des PRM ont augmenté leur puissance pendant le mois d'octobre.
--  Une ligne par période de validité [valid_from, valid_to].
--  ARRAY JOIN "déplie" un tableau : une ligne avec un tableau de 2 éléments
--  devient 2 lignes. C'est l'outil central pour lire les JSON de comptage (module 3).
CREATE OR REPLACE TABLE ref.prm_history
(
    id_prm         UInt64,
    valid_from     Date,
    valid_to       Date,
    puissance_kva  UInt16
)
ENGINE = MergeTree
ORDER BY (id_prm, valid_from);

INSERT INTO ref.prm_history
SELECT id_prm, valid_from, valid_to, puissance_kva
FROM
(
    SELECT
        id_prm,
        puissance_kva,
        date_mise_service,
        cityHash64(id_prm, 'chgt') % 100 < 3 AND puissance_kva >= 6 AS a_change,   -- le client a augmenté sa puissance
        toDate('2026-10-05') + cityHash64(id_prm, 'j') % 20 AS date_chgt
    FROM ref.prm
)
ARRAY JOIN
    if(a_change, [date_mise_service, date_chgt], [date_mise_service])                         AS valid_from,
    if(a_change, [date_chgt - 1, toDate('2099-12-31')], [toDate('2099-12-31')])              AS valid_to,
    if(a_change, [toUInt16(if(puissance_kva <= 36, puissance_kva - 3, intDiv(puissance_kva * 2, 3))), puissance_kva], [puissance_kva]) AS puissance_kva;
-- Mesuré : 258 ms · 1 M lignes lues (11,4 Mo) · 1 M lignes écrites · 106,5 Mo de mémoire

SELECT count() AS lignes, uniqExact(id_prm) AS prm, countIf(valid_to < '2099-01-01') AS changements
FROM ref.prm_history;
-- Mesuré : 18 ms · 1 M lignes lues (9,8 Mo) · 93,7 Mo de mémoire


-- ÉTAPE 8 · Sous le capot : parts, compression, index
--  Chaque INSERT écrit une "part" : un petit lot de fichiers immuable, déjà trié.
--  En arrière-plan, ClickHouse fusionne (merge) les parts entre elles, d'où le nom
--  MergeTree. system.parts montre l'état réel du stockage.
SELECT table, count() AS nb_parts, sum(rows) AS lignes,
       formatReadableSize(sum(data_uncompressed_bytes)) AS brut,
       formatReadableSize(sum(data_compressed_bytes))   AS compresse,
       round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio
FROM system.parts
WHERE database = 'ref' AND active
GROUP BY table
ORDER BY lignes DESC;

--  Compression colonne par colonne
--  Attention : dans Cloud, une part de moins de 1 Go est "compacte" (toutes les
--  colonnes dans un seul fichier) et ses tailles par colonne s'affichent à 0.
--  ref.prm est créée avec min_bytes_for_wide_part = 0 pour pouvoir les lire ici.
--  À observer : les colonnes LowCardinality (segment, profil) se compressent
--  bien mieux que les colonnes texte libres.
SELECT name, type,
       formatReadableSize(data_compressed_bytes)   AS compresse,
       formatReadableSize(data_uncompressed_bytes) AS brut,
       round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio
FROM system.columns
WHERE database = 'ref' AND table = 'prm'
ORDER BY data_compressed_bytes DESC;

--  L'index creux : ClickHouse n'indexe pas chaque ligne, mais une ligne sur
--  8192 (un "granule"). L'index tient donc en mémoire, même pour des milliards
--  de lignes. Pour une recherche, il identifie les granules utiles et ne lit qu'eux.
EXPLAIN indexes = 1
SELECT * FROM ref.prm WHERE id_prm = 10000000006899;

--  Comparez : filtre sur la clé (rapide) vs hors clé (scan complet)
SELECT * FROM ref.prm WHERE id_prm = 10000000006899;     -- filtre sur la clé : 1 granule lu
-- Mesuré : 4 ms · 8 192 lignes lues (64 Ko)
SELECT count() FROM ref.prm WHERE code_insee = '92063';  -- Rueil-Malmaison, hors clé : toute la table lue
-- Mesuré : 7 ms · 1 M lignes lues (7,6 Mo)
-- À observer : "rows read" en bas de la console. 8 192 lignes lues pour la première,
-- 1 000 000 pour la seconde. Sur 1 Md de lignes, l'écart serait le même en proportion.


-- CHECKPOINT MODULE 1
--  Chaque colonne doit afficher OK. Un KO : relancez le fichier (il est idempotent).
SELECT
    if((SELECT count() FROM ref.commune) > 34000, 'OK', 'KO') AS communes,
    if((SELECT count() FROM ref.prm) = 1000000,   'OK', 'KO') AS prm,
    if((SELECT count() FROM ref.prm_history) > 1000000, 'OK', 'KO') AS historique,
    if((SELECT count() FROM ref.destinataire) = 6, 'OK', 'KO') AS destinataires,
    if((SELECT count() FROM ref.prm AS p INNER JOIN ref.commune AS c ON c.code_insee = p.code_insee
        WHERE p.id_prm < 10000000000000 + 20000 * 4093
          AND c.code_epci IN (SELECT code_epci FROM ref.destinataire)) = 20000, 'OK', 'KO') AS prm_chez_leur_destinataire
SETTINGS select_sequential_consistency = 1;   -- lire la dernière version, quelle que soit la réplique
