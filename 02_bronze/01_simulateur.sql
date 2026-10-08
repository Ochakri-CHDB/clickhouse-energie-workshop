-- =====================================================================
--  MODULE 2 · Le simulateur de flux de comptage (à exécuter tel quel)
-- =====================================================================
--  On ne peut pas partager de vraies données. On les SIMULE donc avec
--  des fonctions SQL (UDF) qui reproduisent des comportements réels :
--    · résidentiel : pointe du matin, grosse pointe du soir
--    · tertiaire   : plateau 8h-19h en semaine, creux le week-end
--    · solaire     : courbe en cloche, météo différente par département
--    · industrie   : talon élevé, tourne aussi le week-end
--    · octobre     : il fait de plus en plus froid, la conso monte
--  Ordres de grandeur visés (parc français, octobre) : un foyer ~12 kWh/jour,
--  un site C2 chargé à ~25 % de sa puissance, week-end ≈ 0,7 × semaine,
--  énergie RES / PRO / ENT ≈ 37 / 34 / 28 %.
--  Tout est déterministe : chacun obtient exactement les mêmes chiffres.
-- =====================================================================


-- Les UDF : une fonction = une expression SQL réutilisable
--  Une UDF SQL n'est pas du code externe : c'est une expression que ClickHouse
--  recopie dans la requête au moment de l'exécuter. Aucun coût d'appel, et
--  elle profite du calcul vectorisé comme n'importe quelle fonction native.
--  Toutes les fonctions du simulateur commencent par sim_.
CREATE OR REPLACE FUNCTION sim_id_prm AS (n) ->
    toUInt64(10000000000000 + n * 4093 + cityHash64(n) % 4093);

CREATE OR REPLACE FUNCTION sim_alea AS (a, b, c) ->
    (cityHash64(a, b, c) % 1000000) / 1000000.;                -- "aléa" déterministe entre 0 et 1

CREATE OR REPLACE FUNCTION sim_heure_locale AS (ts) ->
    toHour(ts - 900, 'Europe/Paris') + toMinute(ts - 900, 'Europe/Paris') / 60;   -- milieu de l'intervalle

CREATE OR REPLACE FUNCTION sim_heure_utc AS (ts) ->
    toHour(ts - 900, 'UTC') + toMinute(ts - 900, 'UTC') / 60;

--  sim_conso_w : la puissance moyenne (W) d'un PRM sur une demi-heure.
--  = niveau (part de la puissance souscrite) × forme de la journée × saison × bruit.
CREATE OR REPLACE FUNCTION sim_conso_w AS (id, profil, kva, ts) ->
    toUInt32(round(
        kva * 1000 * multiIf(profil = 'RES', 0.10,                                  -- niveau : part de la puissance souscrite
                             profil = 'ENT', 0.29,                                  --   industrie (C2) : forte utilisation
                             kva > 36,       0.24,                                  --   PME, tertiaire (C4)
                                             0.13)                                  --   petit professionnel (C5)
        * multiIf(
            profil = 'RES',                                                       -- foyer : pointes matin et soir
                (0.30 + 0.55 * exp(-pow(sim_heure_locale(ts) - 7.5, 2) / 1.5)
                      + 1.00 * exp(-pow(sim_heure_locale(ts) - 20.0, 2) / 3.0)
                      + 0.15 * exp(-pow(sim_heure_locale(ts) - 13.0, 2) / 2.0))
                * if(toDayOfWeek(ts, 0, 'Europe/Paris') >= 6, 1.10, 1.0),         -- un peu plus le week-end
            toDayOfWeek(ts, 0, 'Europe/Paris') >= 6,
                if(profil = 'ENT', 0.55, 0.30),                                   -- week-end : l'industrie tourne en partie
            if(profil = 'ENT', 0.55, 0.30)
                + if(profil = 'ENT', 0.65, 0.90)
                  / ((1 + exp(-2 * (sim_heure_locale(ts) - 8))) * (1 + exp(2 * (sim_heure_locale(ts) - 19)))))  -- plateau 8h-19h
        * (1 + if(profil = 'RES', 0.008, 0.003) * toDayOfMonth(ts, 'Europe/Paris'))  -- octobre se refroidit : le chauffage des foyers pèse le plus
        * (0.75 + 0.50 * sim_alea(id, ts, 'bruit'))                               -- bruit
    ));

--  sim_prod_w : la production solaire = puissance crête × soleil × météo du jour.
CREATE OR REPLACE FUNCTION sim_prod_w AS (id, code_dept, kwc, ts) ->
    toUInt32(round(
        kwc * 850
        * greatest(0, sin(pi() * (sim_heure_utc(ts) - 6.4) / 10.4))   -- le soleil (heure solaire ≈ UTC)
        * (0.25 + 0.75 * sim_alea(code_dept, toDate(ts), 'meteo'))     -- nuages du jour, par département
        * (0.90 + 0.20 * sim_alea(id, ts, 'bruit'))
    ));

CREATE OR REPLACE FUNCTION sim_iso AS (ts) ->                       -- format source : 2026-10-25T02:30:00+01:00
    concat(substring(formatDateTime(ts, '%Y-%m-%dT%H:%i:%S%z', 'Europe/Paris'), 1, 22), ':',
           substring(formatDateTime(ts, '%Y-%m-%dT%H:%i:%S%z', 'Europe/Paris'), 23, 2));

CREATE OR REPLACE FUNCTION sim_points_du_jour AS (jour) ->        -- fins d'intervalles 30 min, heure locale
    arrayMap(x -> toDateTime(x, 'UTC'),
             range(toUInt32(toDateTime(jour, 'Europe/Paris')) + 1800,
                   toUInt32(toDateTime(jour + 1, 'Europe/Paris')) + 1, 1800));


-- Le dictionnaire du simulateur : caractéristiques de chaque PRM en mémoire
--  Pour générer une courbe, il faut le profil, la puissance et les panneaux
--  de chaque PRM. Un dictionnaire charge ces infos en RAM une fois, puis
--  dictGet les lit en temps constant, sans jointure (détails au module 4).
CREATE OR REPLACE DICTIONARY simulateur.dict_prm
(
    id_prm         UInt64,
    profil         String,
    puissance_kva  UInt16,
    kwc_pv         Float32,
    code_dept      String,
    fin_ancienne   Date,                -- dernier jour de l'ancienne puissance (1970-01-01 si jamais changée)
    kva_ancien     UInt16
)
PRIMARY KEY id_prm
SOURCE(CLICKHOUSE(
    QUERY 'SELECT p.id_prm, p.profil, p.puissance_kva, p.kwc_pv, c.code_dept, h.valid_to, h.puissance_kva
           FROM ref.prm AS p
           INNER JOIN ref.commune AS c USING (code_insee)
           LEFT JOIN (SELECT id_prm, valid_to, puissance_kva FROM ref.prm_history WHERE valid_to < ''2099-01-01'') AS h USING (id_prm)'
    USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(HASHED())
LIFETIME(0);


-- Les 3 générateurs de fichiers, sous forme de VUES PARAMÉTRÉES
--  Fichier n° k = journée (k / 20) du mois d'octobre, lot (k % 20) de 1000 PRM.
--  Chaque lot appartient à une métropole (sim_destinataire, module 1).
--  Usage : SELECT * FROM simulateur.fichiers_cdc(debut = 0, nb = 20)  → le 1er octobre
--
--  Piège évité : en ClickHouse un alias est GLOBAL dans la requête. Écrire
--  'CONS' AS grandeurMetier puis 'PROD' AS grandeurMetier fait que le 2e alias
--  reprend la valeur du 1er. On construit donc des tuples SANS alias, puis on
--  les convertit d'un coup (CAST) vers un type nommé : les noms deviennent les
--  clés du JSON.
--
--  Une vue paramétrée est une requête enregistrée avec des paramètres
--  ({debut:UInt32}, {nb:UInt32}). On l'appelle comme une table function.

CREATE OR REPLACE VIEW simulateur.fichiers_cdc AS
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
FROM numbers({debut:UInt32}, {nb:UInt32});

CREATE OR REPLACE VIEW simulateur.fichiers_energie AS
WITH
    toDate('2026-10-01') + intDiv(number, 20)                                  AS jour,
    number % 20                                                                 AS lot,
    toDateTime64(toDateTime(jour + 1, 'Europe/Paris'), 3, 'UTC') + toIntervalSecond(25200 + lot * 120) AS arrivee,
    sim_points_du_jour(jour)                                                    AS horodatages,
    arrayMap(n -> sim_id_prm(n), range(lot * 1000, lot * 1000 + 1000))          AS ids,
    arrayMap(id -> dictGet('simulateur.dict_prm', ('profil', 'puissance_kva', 'kwc_pv', 'code_dept'), id), ids) AS attrs
SELECT
    concat('GRD_ENERGIE_JOUR_PUB_', toString(200000 + number), '_', sim_destinataire(lot), '_', formatDateTime(arrivee, '%Y%m%d%H%i%S'), '.zip') AS file_name,
    'ENERGIE'   AS code_flux,
    arrivee AS ingested_at,
    toJSONString(CAST((
        ('PORTAIL DONNEES', 'COLLECTIVITE', sim_destinataire(lot), 'NRJJ', toString(200000 + number), 'RECURRENT', 'JSON'),
        arrayMap((id, a) -> (
            leftPad(toString(id), 14, '0'),
            'BRUT',
            (toString(jour), toString(jour + 1)),
            'GLOBALE', 'DIFF.INDEX', 'P1D',
            arrayConcat(
                -- l'énergie vient des index : complète même quand la courbe a des trous
                [('EA', 'CONS', 'Wh', [(toString(jour),
                    toString(round(arraySum(arrayMap(t -> sim_conso_w(id, a.1, a.2, t), horodatages)) / 2
                                   * (0.998 + 0.004 * sim_alea(id, jour, 'index')), 2)))])],
                if(a.3 > 0,
                   [('EA', 'PROD', 'Wh', [(toString(jour),
                       toString(round(arraySum(arrayMap(t -> sim_prod_w(id, a.4, a.3, t), horodatages)) / 2, 2)))])],
                   []))
        ), ids, attrs)
    ), 'Tuple(header Tuple(siDemandeur String, typeDestinataire String, idDestinataire String, codeFlux String, idPublication String, modePublication String, format String),
              mesures Array(Tuple(idPrm String, etapeMetier String, periode Tuple(dateDebut String, dateFin String),
                                  typeValeur String, modeCalcul String, pas String,
                                  grandeur Array(Tuple(grandeurPhysique String, grandeurMetier String, unite String,
                                                       points Array(Tuple(d String, v String)))))))')) AS payload
FROM numbers({debut:UInt32}, {nb:UInt32});

CREATE OR REPLACE VIEW simulateur.fichiers_pmax AS
WITH
    toDate('2026-10-01') + intDiv(number, 20)                                  AS jour,
    number % 20                                                                 AS lot,
    toDateTime64(toDateTime(jour + 1, 'Europe/Paris'), 3, 'UTC') + toIntervalSecond(27000 + lot * 120) AS arrivee,
    sim_points_du_jour(jour)                                                    AS horodatages,
    arrayMap(n -> sim_id_prm(n), range(lot * 1000, lot * 1000 + 1000))          AS ids,
    arrayMap(id -> dictGet('simulateur.dict_prm', ('profil', 'puissance_kva', 'kwc_pv', 'code_dept', 'fin_ancienne', 'kva_ancien'), id), ids) AS attrs
SELECT
    concat('GRD_PMAX_JOUR_PUB_', toString(300000 + number), '_', sim_destinataire(lot), '_', formatDateTime(arrivee, '%Y%m%d%H%i%S'), '.zip') AS file_name,
    'PMAX'   AS code_flux,
    arrivee AS ingested_at,
    toJSONString(CAST((
        ('PORTAIL DONNEES', 'COLLECTIVITE', sim_destinataire(lot), 'PMAXJ', toString(300000 + number), 'RECURRENT', 'JSON'),
        arrayMap((id, a) -> (
            leftPad(toString(id), 14, '0'),
            'BRUT',
            (toString(jour), toString(jour + 1)),
            'P1D',
            [('PMA', 'CONS', 'VA', [(
                -- l'instant de la pointe du jour
                sim_iso(arraySort(t -> -sim_conso_w(id, a.1, a.2, t), horodatages)[1]),
                -- la puissance souscrite EN VIGUEUR ce jour-là : a.6 avant le changement, a.2 après
                toString(toUInt32(multiIf(
                    -- C4 / C2 : dépassements possibles (et facturés). ~3 % des jours,
                    -- ~25 % avant une hausse de puissance (le client a augmenté parce qu'il dépassait)
                    if(jour <= a.5, a.6, a.2) > 36 AND sim_alea(id, jour, 'pic') < if(jour <= a.5, 0.25, 0.03),
                        if(jour <= a.5, a.6, a.2) * 1000 * (1.02 + 0.25 * sim_alea(id, jour, 'amplitude')),
                    if(jour <= a.5, a.6, a.2) > 36,
                        arrayMax(arrayMap(t -> sim_conso_w(id, a.1, a.2, t), horodatages)) * 1.15,
                    -- C5 : le disjoncteur du compteur coupe, la PMax ne dépasse jamais la puissance souscrite
                    least(arrayMax(arrayMap(t -> sim_conso_w(id, a.1, a.2, t), horodatages)) * 1.25,
                          if(jour <= a.5, a.6, a.2) * 980))))
            )])]
        ), ids, attrs)
    ), 'Tuple(header Tuple(siDemandeur String, typeDestinataire String, idDestinataire String, codeFlux String, idPublication String, modePublication String, format String),
              mesures Array(Tuple(idPrm String, etapeMetier String, periode Tuple(dateDebut String, dateFin String), pas String,
                                  grandeur Array(Tuple(grandeurPhysique String, grandeurMetier String, unite String,
                                                       points Array(Tuple(d String, v String)))))))')) AS payload
FROM numbers({debut:UInt32}, {nb:UInt32});


-- Testons : la courbe d'un résidentiel et d'un PRM avec panneaux solaires
--  bar() dessine une barre de texte proportionnelle à la valeur : un graphique
--  directement dans le résultat.
--  À observer : la pointe du matin vers 7h-8h, la grosse pointe du soir vers
--  19h-21h, et la production qui ne vaut quelque chose qu'en milieu de journée.
SELECT
    sim_iso(ts)                                                         AS horodatage,
    sim_conso_w(sim_id_prm(1), 'RES', 9, ts)                            AS conso_w,
    sim_prod_w(sim_id_prm(1), '92', 6, ts)                              AS prod_w,
    bar(conso_w, 0, 3000, 30)                                           AS graphe_conso
FROM (SELECT arrayJoin(sim_points_du_jour(toDate('2026-10-15'))) AS ts);
-- Mesuré : 11 ms · 1 ligne lue

-- Le jour du changement d'heure (25 octobre) compte 50 demi-heures
--  sim_points_du_jour calcule les horodatages à partir de minuit heure de Paris :
--  le 25 octobre, la nuit dure une heure de plus, donc 2 points de plus.
SELECT jour, length(sim_points_du_jour(jour)) AS nb_points
FROM (SELECT toDate('2026-10-24') + number AS jour FROM numbers(3));
-- Mesuré : 2 ms · 3 lignes lues
