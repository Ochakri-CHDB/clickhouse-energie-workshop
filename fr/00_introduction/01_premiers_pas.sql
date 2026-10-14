-- =====================================================================
--  MODULE 0 · Premiers pas : de numbers() à un vrai fichier de comptage
-- =====================================================================
--  Idée clé : en ClickHouse, un SELECT peut FABRIQUER de la donnée.
--  On part de rien et on construit, étape par étape, un fichier d'énergie journalière
--  au même format que ceux que vous recevez du gestionnaire de réseau.
--
--  Mode d'emploi : placez le curseur dans une requête et faites
--  Cmd + Maj + Entrée pour l'exécuter seule. En bas de la console, la
--  console affiche la durée, le nombre de lignes lues et le volume lu :
--  ce sont les trois chiffres à regarder tout au long du workshop.
-- =====================================================================


-- ÉTAPE 1 · numbers() est une "table function" : elle génère des lignes
--  Une table function s'utilise après FROM comme une table, mais elle
--  calcule ses lignes à la volée. numbers(10) renvoie les entiers 0 à 9.
--  On s'en sert pour simuler des millions de lignes sans rien stocker.
SELECT number
FROM numbers(10);
-- Mesuré : 1 ms · 10 lignes lues


-- ÉTAPE 2 · On applique des fonctions sur chaque ligne
--  cityHash64 donne toujours le même résultat pour la même entrée : c'est
--  un "hasard" reproductible, identique chez tous les participants.
--  randCanonical, lui, change à chaque exécution.
SELECT
    number,
    toDate('2026-10-01') + number              AS jour,
    cityHash64(number) % 100                   AS hasard_deterministe,
    round(80000 + 60000 * randCanonical(), 2)  AS energie_wh
FROM numbers(10);
-- Mesuré : 2 ms · 10 lignes lues


-- ÉTAPE 3 · Un identifiant PRM réaliste à 14 chiffres
--  Un PRM tient dans un UInt64 (8 octets). leftPad le remet au format
--  texte à 14 chiffres, comme dans les fichiers du gestionnaire de réseau.
SELECT leftPad(toString(10000000000000 + number * 4093 + cityHash64(number) % 4093), 14, '0') AS idPrm
FROM numbers(5);
-- Mesuré : 1 ms · 5 lignes lues


-- ÉTAPE 4 · Une mesure d'énergie journalière : un tuple nommé devient un objet JSON
--  tuple(valeur AS nom, ...) crée une structure ; toJSONString la convertit
--  en objet JSON dont les clés sont les noms. Un tableau [...] devient une
--  liste JSON. Le réglage enable_named_columns_in_function_tuple garde les noms.
SELECT toJSONString(tuple(
    leftPad(toString(10000000000000 + 4093), 14, '0')  AS idPrm,
    'BRUT'                                              AS etapeMetier,
    tuple('2026-10-01' AS dateDebut, '2026-10-02' AS dateFin) AS periode,
    'GLOBALE'                                           AS typeValeur,
    'DIFF.INDEX'                                        AS modeCalcul,
    'P1D'                                               AS pas,
    [tuple('EA' AS grandeurPhysique, 'CONS' AS grandeurMetier, 'Wh' AS unite,
           [tuple('2026-10-01' AS d, '190205.98' AS v)] AS points)] AS grandeur
)) AS mesure_json
SETTINGS enable_named_columns_in_function_tuple = 1;
-- Mesuré : 2 ms · 1 ligne lue


-- ÉTAPE 5 · Un fichier complet : un header + 1000 mesures
--  arrayMap(i -> ..., range(1000)) joue le rôle d'une boucle : il applique
--  la fonction à chaque élément du tableau 0..999 et renvoie le tableau
--  des résultats. Une seule ligne de résultat = un fichier entier.
SELECT toJSONString(tuple(
    tuple('PORTAIL DONNEES' AS siDemandeur, 'COLLECTIVITE' AS typeDestinataire,
          '488903' AS idDestinataire, 'NRJJ' AS codeFlux, 'RECURRENT' AS modePublication,
          'JSON' AS format) AS header,
    arrayMap(i -> tuple(
        leftPad(toString(10000000000000 + i * 4093 + cityHash64(i) % 4093), 14, '0') AS idPrm,
        'BRUT' AS etapeMetier,
        tuple('2026-10-01' AS dateDebut, '2026-10-02' AS dateFin) AS periode,
        'P1D' AS pas,
        [tuple('EA' AS grandeurPhysique, 'CONS' AS grandeurMetier, 'Wh' AS unite,
               [tuple('2026-10-01' AS d, toString(round(80000 + 60000 * (cityHash64(i) % 1000) / 1000, 2)) AS v)] AS points)] AS grandeur
    ), range(1000)) AS mesures
)) AS fichier_energie_jour
SETTINGS enable_named_columns_in_function_tuple = 1;
-- Mesuré : 4 ms · 1 ligne lue
-- À observer : copiez le résultat dans un visualiseur JSON. On retrouve
-- exactement la structure du format source : header, puis mesures > grandeur > points.


-- ÉTAPE 6 · Le teaser : 1 MILLION de mesures JSON. Combien de temps ?
--  Chaque ligne fabrique et sérialise un petit objet JSON. ClickHouse
--  découpe numbers() en blocs et les traite sur tous les cœurs en parallèle.
SELECT
    count()                                   AS nb_mesures,
    formatReadableSize(sum(length(json)))     AS volume_json
FROM
(
    SELECT toJSONString(tuple(
        leftPad(toString(10000000000000 + number * 4093 + cityHash64(number) % 4093), 14, '0') AS idPrm,
        'BRUT' AS etapeMetier,
        toString(round(80000 + 60000 * (cityHash64(number) % 1000) / 1000, 2)) AS v
    )) AS json
    FROM numbers(1000000)
)
SETTINGS enable_named_columns_in_function_tuple = 1;
-- Mesuré : 266 ms · 1 M lignes lues (7,6 Mo)
-- À observer : la durée en bas de la console. Remplacez 1000000 par 10000000 :
-- le temps est à peu près multiplié par 10, la vitesse en lignes/s reste stable.
