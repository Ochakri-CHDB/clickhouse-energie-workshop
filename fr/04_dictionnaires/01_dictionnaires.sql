-- =====================================================================
--  MODULE 4 · Dictionnaires : les référentiels en mémoire
-- =====================================================================
--  Un dictionnaire = une table clé → valeurs chargée en RAM.
--  dictGet() remplace une jointure : une recherche en O(1) par ligne.
--  Pourquoi c'est mieux qu'un JOIN répété ? Un JOIN reconstruit une table de
--  hachage à CHAQUE requête. Le dictionnaire la construit une fois, la garde
--  en mémoire et la recharge selon LIFETIME (règle query-join-use-dictionaries).
--  Il n'utilise pas la mémoire de la requête, ce qui protège les gros scans.
-- =====================================================================


-- ÉTAPE 1 · Le dictionnaire des communes (clé texte : COMPLEX_KEY_HASHED)
--  SOURCE dit où lire les données, LAYOUT comment les ranger en mémoire,
--  LIFETIME quand les recharger. Dans Cloud, la source CLICKHOUSE doit déclarer
--  un utilisateur : on utilise dict_reader, en lecture seule (module 1).
CREATE OR REPLACE DICTIONARY ref.dict_commune
(
    code_insee   String,
    nom          String,
    code_dept    String,
    code_region  String,
    code_epci    String,
    population   UInt32
)
PRIMARY KEY code_insee
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'commune' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 3600 MAX 7200);          -- rechargé toutes les 1 à 2 h


-- ÉTAPE 2 · Le dictionnaire des PRM (clé numérique : HASHED, le plus rapide)
CREATE OR REPLACE DICTIONARY ref.dict_prm
(
    id_prm         UInt64,
    code_insee     String,
    segment        String,
    profil         String,
    puissance_kva  UInt16,
    tarif          String,
    kwc_pv         Float32
)
PRIMARY KEY id_prm
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'prm' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(HASHED_ARRAY())                -- variante de HASHED, plus économe quand il y a beaucoup d'attributs
LIFETIME(MIN 3600 MAX 7200);


-- ÉTAPE 3 · La puissance souscrite "à date" (RANGE_HASHED)
--  Pour une clé ET une date, il trouve la ligne valide à ce moment-là.
--  Exactement ce qu'il faut pour comparer une PMax à la puissance souscrite
--  le jour de la mesure, et non à la puissance actuelle.
CREATE OR REPLACE DICTIONARY ref.dict_puissance_asof
(
    id_prm         UInt64,
    valid_from     Date,
    valid_to       Date,
    puissance_kva  UInt16
)
PRIMARY KEY id_prm
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'prm_history' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(RANGE_HASHED())
RANGE(MIN valid_from MAX valid_to)
LIFETIME(MIN 3600 MAX 7200);

--  Libellés des EPCI et départements
CREATE OR REPLACE DICTIONARY ref.dict_epci (code_epci String, nom String)
PRIMARY KEY code_epci
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'epci' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED()) LIFETIME(86400);

CREATE OR REPLACE DICTIONARY ref.dict_departement (code_dept String, nom String, code_region String)
PRIMARY KEY code_dept
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'departement' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED()) LIFETIME(86400);


-- ÉTAPE 4 · Utilisation : un PRM, toute sa fiche, en une ligne
--  Les dictGet s'enchaînent : PRM → commune → département. Aucun JOIN.
SELECT
    sim_id_prm(42)                                                              AS id_prm,
    dictGet('ref.dict_prm', 'segment', id_prm)                                  AS segment,
    dictGet('ref.dict_prm', 'puissance_kva', id_prm)                            AS kva_actuel,
    dictGet('ref.dict_prm', 'code_insee', id_prm)                               AS code_insee,
    dictGet('ref.dict_commune', 'nom', code_insee)                              AS commune,
    dictGet('ref.dict_departement', 'nom', dictGet('ref.dict_commune', 'code_dept', code_insee)) AS departement,
    dictGet('ref.dict_epci', 'nom', dictGet('ref.dict_commune', 'code_epci', code_insee))       AS epci;
-- Mesuré : 3 ms · 1 ligne lue


-- ÉTAPE 5 · La puissance qui change dans le temps
--  Prenons un PRM qui a changé de puissance en octobre
SELECT id_prm, valid_from, valid_to, puissance_kva
FROM ref.prm_history
WHERE id_prm IN (SELECT id_prm FROM ref.prm_history WHERE valid_to = '2026-10-14' LIMIT 1)
ORDER BY valid_from;
-- Mesuré : 9 ms · 991 232 lignes lues (9,5 Mo)

SELECT
    jour,
    dictGet('ref.dict_puissance_asof', 'puissance_kva', p.id_prm, jour) AS kva_a_date
FROM (SELECT id_prm FROM ref.prm_history WHERE valid_to = '2026-10-14' LIMIT 1) AS p
CROSS JOIN (SELECT toDate('2026-10-12') + number AS jour FROM numbers(5)) AS j;
-- Mesuré : 8 ms · 983 045 lignes lues (9,4 Mo)
-- À observer : le 15, la nouvelle puissance s'applique. Indispensable pour les
-- alertes de dépassement du module 5.


-- ÉTAPE 6 · Dictionnaire vs JOIN : même résultat, comparez les temps
--  Énergie du mois par département. sum(valeur_w) * 0.5 : une puissance moyenne
--  sur une demi-heure × 0,5 h = une énergie en Wh.
SELECT
    dictGet('ref.dict_commune', 'code_dept', dictGet('ref.dict_prm', 'code_insee', id_prm)) AS dept,
    round(sum(valeur_w) * 0.5 / 1e6) AS mwh
FROM silver.courbe_charge
WHERE grandeur = 'CONS'
GROUP BY dept
ORDER BY mwh DESC
LIMIT 10;
-- Mesuré : 271 ms · 29,8 M lignes lues (369,5 Mo) · 174,9 Mo de mémoire

SELECT
    c.code_dept AS dept,
    round(sum(s.valeur_w) * 0.5 / 1e6) AS mwh
FROM silver.courbe_charge AS s
INNER JOIN ref.prm     AS p ON p.id_prm = s.id_prm
INNER JOIN ref.commune AS c ON c.code_insee = p.code_insee
WHERE s.grandeur = 'CONS'
GROUP BY dept
ORDER BY mwh DESC
LIMIT 10;
-- Mesuré : 282 ms · 30,8 M lignes lues (385,1 Mo) · 282,1 Mo de mémoire
-- À observer : même résultat. Comparez la durée et la mémoire en bas de la console :
-- le JOIN doit d'abord charger ref.prm et ref.commune en mémoire, le dictionnaire non.


-- ÉTAPE 7 · Qualité : y a-t-il des PRM inconnus du référentiel ?
--  dictHas renvoie 0 si la clé est absente : un contrôle de qualité en une ligne.
SELECT count() AS points_prm_inconnus
FROM silver.courbe_charge
WHERE NOT dictHas('ref.dict_prm', id_prm);
-- Mesuré : 22 ms · 31 M lignes lues (236,8 Mo)


-- ÉTAPE 8 · Ce que ça coûte en mémoire
--  À observer : quelques dizaines de Mo pour 1 million de PRM. Le dictionnaire
--  "à date" est plus gros car il range des intervalles par clé.
SELECT name, status, type, element_count, formatReadableSize(bytes_allocated) AS memoire, loading_duration
FROM system.dictionaries
WHERE database = 'ref';


-- POUR ALLER PLUS LOIN · Rapprochement flou d'adresses (cas BAN)
--  ngramDistance mesure la ressemblance de deux textes (0 = identiques) :
--  il retrouve "Rueil-Malmaison" malgré la faute de frappe.
SELECT nom, code_insee, round(ngramDistanceCaseInsensitiveUTF8(replaceAll(nom, '-', ' '), 'Rueil Malmaizon'), 3) AS distance
FROM ref.commune
ORDER BY distance ASC
LIMIT 3;
-- Mesuré : 9 ms · 61 746 lignes lues (995,3 Ko)


-- CHECKPOINT
SELECT
    if((SELECT element_count FROM system.dictionaries WHERE database = 'ref' AND name = 'dict_prm') = 1000000, 'OK', 'KO') AS dict_prm,
    if((SELECT status FROM system.dictionaries WHERE database = 'ref' AND name = 'dict_puissance_asof') = 'LOADED', 'OK', 'KO') AS dict_asof,
    if(dictGet('ref.dict_commune', 'nom', '92063') = 'Rueil-Malmaison', 'OK', 'KO') AS dict_commune
SETTINGS select_sequential_consistency = 1;   -- lire la dernière version, quelle que soit la réplique
