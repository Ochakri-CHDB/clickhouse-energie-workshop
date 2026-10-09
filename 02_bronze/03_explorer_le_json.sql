-- =====================================================================
--  MODULE 2 · Explorer le JSON brut, sans rien charger ailleurs
-- =====================================================================


-- ÉTAPE 1 · Les fonctions JSON lisent directement le texte
--  JSONExtract* parcourt le texte à la lecture, sans aucune préparation.
--  Pratique pour explorer, mais à chaque requête on reparse tout le JSON :
--  c'est pour ça qu'on passe en silver, avec des colonnes typées.
SELECT
    file_name,
    JSONExtractString(payload, 'header', 'codeFlux')        AS code_flux_source,
    JSONExtractString(payload, 'header', 'idDestinataire')  AS destinataire,
    JSONLength(payload, 'mesures')                          AS nb_mesures
FROM bronze.flux_raw
WHERE code_flux = 'CDC'
LIMIT 5;
-- Mesuré : 80 ms · 64 fichiers lus (148,1 Mo de JSON) · 316,2 Mo de mémoire


-- ÉTAPE 2 · Le type JSON natif : ClickHouse découvre la structure tout seul
--  payload::JSON convertit le texte vers le type JSON : chaque chemin devient
--  une sous-colonne typée. Utile quand le schéma change souvent (règle
--  schema-json-when-to-use). Ici le format source est stable : on préférera
--  des colonnes classiques en silver.
SELECT JSONAllPathsWithTypes(payload::JSON) AS structure_detectee
FROM bronze.flux_raw
WHERE code_flux = 'PMAX'
LIMIT 1;
-- Mesuré : 215 ms · 600 fichiers lus (144,9 Mo de JSON) · 406,1 Mo de mémoire

--  On navigue avec des points, comme en JavaScript.
--  .:`Array(JSON)` précise le type attendu pour un tableau d'objets.
SELECT
    j.header.codeFlux                                        AS code_flux,
    arrayJoin(j.mesures.:`Array(JSON)`).idPrm                AS id_prm
FROM (SELECT payload::JSON AS j FROM bronze.flux_raw WHERE code_flux = 'PMAX' LIMIT 1)
LIMIT 5;
-- Mesuré : 75 ms · 600 fichiers lus (144,9 Mo de JSON) · 406,2 Mo de mémoire


-- ÉTAPE 3 · Extraction typée : la clé du passage en silver
--  On décrit la forme attendue, ClickHouse la remplit en une passe.
--  Puis deux ARRAY JOIN déplient les tableaux : fichier → mesures → grandeurs.
--  C'est exactement la requête que la vue matérialisée exécutera au module 3.
SELECT
    m.idPrm, m.etapeMetier, g.grandeurMetier, length(g.points) AS nb_points
FROM
(
    SELECT JSONExtract(payload, 'mesures',
        'Array(Tuple(idPrm String, etapeMetier String, grandeur Array(Tuple(grandeurMetier String, points Array(Tuple(d String, v String))))))') AS mesures
    FROM bronze.flux_raw
    WHERE code_flux = 'CDC'
    LIMIT 1
)
ARRAY JOIN mesures AS m
ARRAY JOIN m.grandeur AS g
LIMIT 10;
-- Mesuré : 21 ms · 64 fichiers lus (148,1 Mo de JSON) · 305,8 Mo de mémoire


-- ÉTAPE 4 · Combien coûtent nos INSERT ? (le journal des requêtes)
--  system.query_log garde une ligne par requête : durée, lignes, mémoire.
--  Dans Cloud, chaque réplique a son propre journal : clusterAllReplicas()
--  les interroge toutes.
SELECT
    event_time,
    query_duration_ms / 1000                       AS secondes,
    written_rows                                   AS fichiers_ecrits,
    formatReadableSize(written_bytes)              AS octets_ecrits,
    formatReadableSize(memory_usage)               AS memoire_max,
    substring(query, position(query, 'FROM numbers'), 30) AS plage
FROM clusterAllReplicas('default', system.query_log)
WHERE type = 'QueryFinish'
  AND query_kind = 'Insert'
  AND has(tables, 'bronze.flux_raw')
  AND event_date = today()
ORDER BY event_time;
-- À observer : la mémoire maximale de chaque INSERT. Elle reste de l'ordre de
-- 2 Go car max_block_size = 2 ne garde que 2 fichiers en mémoire à la fois.
