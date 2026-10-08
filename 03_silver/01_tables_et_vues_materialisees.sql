-- =====================================================================
--  MODULE 3 · Silver : des mesures typées, propres, dédupliquées
-- =====================================================================
--  Bronze (1 ligne = 1 fichier)  ──MV──►  Silver (1 ligne = 1 point)
--  La vue matérialisée (MV) est un TRIGGER sur INSERT : chaque bloc
--  inséré en bronze est transformé et écrit en silver, à la volée.
--  Elle ne recalcule jamais l'existant : elle traite uniquement les nouvelles
--  lignes, au moment de l'INSERT. Le coût est payé une fois, à l'écriture.
-- =====================================================================


-- ÉTAPE 1 · La table des courbes de charge
--  ReplacingMergeTree : pour une même clé (id_prm, grandeur, ts), la ligne
--  avec la version la plus récente gagne. Parfait pour renvois et corrections.
--  Le remplacement se fait pendant les merges en arrière-plan, pas à l'INSERT :
--  entre-temps, les deux versions coexistent sur disque (on le verra en 03).
CREATE OR REPLACE TABLE silver.courbe_charge
(
    id_prm        UInt64,
    grandeur      LowCardinality(String),                        -- CONS / PROD
    ts            DateTime('UTC')      CODEC(Delta, ZSTD(1)),    -- fin d'intervalle, en UTC. Delta stocke l'écart avec la ligne précédente (1800 s) : presque rien
    valeur_w      UInt32               CODEC(T64, ZSTD(1)),      -- puissance moyenne en W. T64 retire les bits de poids fort inutilisés
    pas_min       UInt8,
    etape_metier  LowCardinality(String),                        -- BRUT / CORRIGE
    version       DateTime64(3, 'UTC') CODEC(Delta, ZSTD(1)),    -- arrivée du fichier : la plus récente gagne
    jour          Date MATERIALIZED toDate(ts - 1, 'Europe/Paris') -- calculé à l'insertion : la journée locale (ts - 1 car 00:00 clôt la veille)
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(ts)                -- une partition par mois : peu nombreuses, bornées
ORDER BY (grandeur, id_prm, ts)          -- du moins au plus cardinal : 2 valeurs, puis le PRM, puis le temps
SETTINGS min_bytes_for_wide_part = 0;    -- une colonne = un fichier : on pourra lire la compression par colonne


-- ÉTAPE 2 · Les flux journaliers
--  Même principe : ReplacingMergeTree avec la date d'arrivée comme version.
CREATE OR REPLACE TABLE silver.energie_jour
(
    id_prm        UInt64,
    grandeur      LowCardinality(String),
    jour          Date,
    energie_wh    Decimal(18, 2),                                -- Decimal : pas d'erreur d'arrondi sur les sommes
    etape_metier  LowCardinality(String),
    version       DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(jour)
ORDER BY (id_prm, grandeur, jour);

CREATE OR REPLACE TABLE silver.pmax_jour
(
    id_prm        UInt64,
    jour          Date,
    pmax_va       UInt32,
    ts_pmax       DateTime('UTC'),
    version       DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(jour)
ORDER BY (id_prm, jour);

--  Les rejets : on ne perd rien, on ne bloque rien
--  Une valeur illisible n'arrête pas le chargement : elle part dans cette table,
--  avec le fichier d'origine, pour analyse.
CREATE OR REPLACE TABLE silver.rejets
(
    ingested_at   DateTime64(3, 'UTC'),
    file_name     String,
    code_flux     LowCardinality(String),
    id_prm        String,
    horodatage    String,
    valeur        String,
    motif         LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY (code_flux, ingested_at);


-- ÉTAPE 3 · La MV bronze → silver pour les courbes (CDC)
--  3 ARRAY JOIN en cascade : fichier → mesures → grandeurs → points.
--  Un fichier de 1000 PRM × 48 points produit ainsi ~48 000 lignes silver.
--  "TO silver.courbe_charge" : la MV écrit dans une table qu'on a créée nous-mêmes
--  (on garde la main sur le moteur, la clé et les codecs).
CREATE OR REPLACE MATERIALIZED VIEW silver.mv_cdc_courbe TO silver.courbe_charge AS
SELECT
    toUInt64(m.idPrm)                         AS id_prm,
    g.grandeurMetier                          AS grandeur,
    parseDateTimeBestEffort(p.d, 'UTC')       AS ts,                -- "+01:00" / "+02:00" → UTC
    toUInt32(p.v)                             AS valeur_w,
    toUInt8(extract(m.pas, '\\d+'))           AS pas_min,           -- 'PT30M' → 30
    m.etapeMetier                             AS etape_metier,
    ingested_at                               AS version
FROM bronze.flux_raw
ARRAY JOIN JSONExtract(payload, 'mesures',
    'Array(Tuple(idPrm String, etapeMetier String, pas String, grandeur Array(Tuple(grandeurMetier String, points Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.grandeur AS g
ARRAY JOIN g.points   AS p
WHERE code_flux = 'CDC'
  AND toUInt32OrNull(p.v) IS NOT NULL;   -- toUInt32OrNull renvoie NULL au lieu d'une erreur si la valeur est illisible

--  Une 2e MV sur la même source : elle capture ce que la 1re écarte.
--  Plusieurs MV peuvent lire la même table : chaque INSERT en bronze les déclenche toutes.
CREATE OR REPLACE MATERIALIZED VIEW silver.mv_cdc_rejets TO silver.rejets AS
SELECT
    ingested_at, file_name, code_flux,
    m.idPrm AS id_prm, p.d AS horodatage, p.v AS valeur,
    'valeur non numérique' AS motif
FROM bronze.flux_raw
ARRAY JOIN JSONExtract(payload, 'mesures',
    'Array(Tuple(idPrm String, grandeur Array(Tuple(points Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.grandeur AS g
ARRAY JOIN g.points   AS p
WHERE code_flux = 'CDC'
  AND toUInt32OrNull(p.v) IS NULL;


-- ÉTAPE 4 · Les MV des flux journaliers (ENERGIE, PMAX)
CREATE OR REPLACE MATERIALIZED VIEW silver.mv_energie_jour TO silver.energie_jour AS
SELECT
    toUInt64(m.idPrm)                         AS id_prm,
    g.grandeurMetier                          AS grandeur,
    toDate(p.d)                               AS jour,
    toDecimal64(p.v, 2)                       AS energie_wh,
    m.etapeMetier                             AS etape_metier,
    ingested_at                               AS version
FROM bronze.flux_raw
ARRAY JOIN JSONExtract(payload, 'mesures',
    'Array(Tuple(idPrm String, etapeMetier String, grandeur Array(Tuple(grandeurMetier String, points Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.grandeur AS g
ARRAY JOIN g.points   AS p
WHERE code_flux = 'ENERGIE';

CREATE OR REPLACE MATERIALIZED VIEW silver.mv_pmax_jour TO silver.pmax_jour AS
SELECT
    toUInt64(m.idPrm)                         AS id_prm,
    toDate(m.periode.dateDebut)               AS jour,
    toUInt32(p.v)                             AS pmax_va,
    parseDateTimeBestEffort(p.d, 'UTC')       AS ts_pmax,
    ingested_at                               AS version
FROM bronze.flux_raw
ARRAY JOIN JSONExtract(payload, 'mesures',
    'Array(Tuple(idPrm String, periode Tuple(dateDebut String), grandeur Array(Tuple(points Array(Tuple(d String, v String))))))') AS m
ARRAY JOIN m.grandeur AS g
ARRAY JOIN g.points   AS p
WHERE code_flux = 'PMAX';


-- ÉTAPE 5 · Surprise : silver est vide !
SELECT
    (SELECT count() FROM silver.courbe_charge) AS points_courbe,
    (SELECT count() FROM silver.energie_jour)  AS lignes_energie,
    (SELECT count() FROM silver.pmax_jour)     AS lignes_pmax;
-- Mesuré : 3 ms · 4 lignes lues
-- À observer : une MV ne voit que les INSERT qui arrivent APRÈS sa création.
--    Les fichiers déjà en bronze doivent être "rejoués" : c'est le backfill.
--    C'est voulu : créer une MV sur une table de 1 To ne bloque rien.
