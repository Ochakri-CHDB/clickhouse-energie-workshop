-- =====================================================================
--  MODULE 8 · ClickHouse Agents : préparer gold, puis 10 questions métier
-- =====================================================================
--  Un agent ne devine pas le métier : il lit le schéma. Plus le schéma
--  parle, meilleures sont ses requêtes (règle agent-discovery-schema :
--  bases → tables → colonnes ET commentaires → clés de tri → échantillon).
--
--  1. On documente les tables gold avec des COMMENT (métadonnées, instantané).
--  2. On pose les 10 questions dans ClickHouse Agents (voir le README).
--  3. On compare la réponse de l'agent à la requête attendue ci-dessous.
-- =====================================================================


-- ÉTAPE 1 · Des commentaires que l'agent lira dans system.tables / system.columns
--  MODIFY COMMENT et COMMENT COLUMN ne touchent que les métadonnées : instantané,
--  aucune donnée réécrite. Les commentaires survivent aux rafraîchissements des vues.
ALTER TABLE gold.synthese_collectivite_jour
    MODIFY COMMENT 'Synthèse quotidienne par collectivité destinataire des flux de comptage (6 métropoles). Une ligne par collectivité et par jour d''octobre 2026. Énergies en kWh.';
-- Mesuré : 99 ms
ALTER TABLE gold.synthese_collectivite_jour
    COMMENT COLUMN id_destinataire 'Identifiant du destinataire (488903 = Métropole du Grand Paris, voir ref.destinataire)',
    COMMENT COLUMN jour            'Journée locale (Europe/Paris)',
    COMMENT COLUMN conso_kwh       'Énergie consommée sur le territoire ce jour, en kWh',
    COMMENT COLUMN prod_kwh        'Énergie produite (photovoltaïque) sur le territoire ce jour, en kWh',
    COMMENT COLUMN taux_couverture 'prod_kwh / conso_kwh, entre 0 et 1',
    COMMENT COLUMN nb_prm          'Nombre de compteurs (PRM) ayant remonté une courbe ce jour';
-- Mesuré : 67 ms

ALTER TABLE gold.courbe_epci
    MODIFY COMMENT 'Courbe de charge agrégée par EPCI, pas 30 min. ts = FIN de l''intervalle, en UTC : convertir avec toTimeZone(ts, ''Europe/Paris''). Filtrer sur code_epci puis ts (clé de tri).';
-- Mesuré : 79 ms
ALTER TABLE gold.courbe_epci
    COMMENT COLUMN code_epci    'Code SIREN de l''EPCI (200054781 = Métropole du Grand Paris). Libellé : dictGet(''ref.dict_epci'', ''nom'', code_epci)',
    COMMENT COLUMN grandeur     'CONS = consommation, PROD = production',
    COMMENT COLUMN ts           'Fin de l''intervalle de 30 min, UTC',
    COMMENT COLUMN puissance_kw 'Puissance moyenne sur l''intervalle, somme des compteurs, en kW',
    COMMENT COLUMN nb_prm       'Nombre de points (compteurs) agrégés';
-- Mesuré : 120 ms

ALTER TABLE gold.energie_commune_jour
    MODIFY COMMENT 'Énergie par commune, jour, segment (C5, C4, C2) et grandeur (CONS, PROD). Libellé de commune : dictGet(''ref.dict_commune'', ''nom'', code_insee).';
-- Mesuré : 72 ms
ALTER TABLE gold.energie_commune_jour
    COMMENT COLUMN segment     'C5 = particuliers et petits pros (≤ 36 kVA), C4 = PME/tertiaire (36 à 250 kVA), C2 = industriels HTA',
    COMMENT COLUMN energie_kwh 'Énergie du jour en kWh',
    COMMENT COLUMN nb_prm      'Compteurs de ce segment dans la commune ce jour (additionner les segments pour le total)';
-- Mesuré : 77 ms

ALTER TABLE gold.alertes_pmax
    MODIFY COMMENT 'Dépassements de puissance souscrite (flux PMAX). Une ligne par compteur et par jour en dépassement. Seuls les C4 et C2 peuvent dépasser (en C5 le disjoncteur coupe).';
-- Mesuré : 82 ms
ALTER TABLE gold.alertes_pmax
    COMMENT COLUMN kva_souscrit    'Puissance souscrite EN VIGUEUR ce jour-là, en kVA',
    COMMENT COLUMN pmax_va         'Puissance maximale atteinte dans la journée, en VA',
    COMMENT COLUMN depassement_pct 'Dépassement en % de la puissance souscrite',
    COMMENT COLUMN heure_pointe    'Instant de la pointe, heure de Paris';
-- Mesuré : 75 ms

ALTER TABLE gold.kpi_completude_jour
    MODIFY COMMENT 'Complétude de la collecte des courbes CDC à 9h le lendemain. Cible : taux_donnees_9h_pct >= 99.';
-- Mesuré : 80 ms
ALTER TABLE gold.kpi_completude_jour
    COMMENT COLUMN taux_donnees_9h_pct      'Points reçus avant 9h / points attendus, en %. C''est le KPI contractuel',
    COMMENT COLUMN taux_prm_complets_9h_pct 'Part des compteurs dont la journée est complète à 9h, en %';
-- Mesuré : 32 ms

--  Ce que voit l'agent quand il explore :
SELECT name AS table_gold, comment
FROM system.tables
WHERE database = 'gold' AND comment != ''
ORDER BY name;


-- ÉTAPE 2 · Les 10 questions et la requête attendue
--  Posez la question telle quelle à l'agent. Comparez sa réponse au résultat
--  ci-dessous. Une bonne réponse filtre sur la clé de tri et met un LIMIT
--  (règle agent-query-safety).

-- Q1 · "Combien la Métropole du Grand Paris a-t-elle consommé en octobre,
--       et quelle part a été couverte par la production solaire locale ?"
SELECT round(sum(conso_kwh) / 1000) AS conso_mwh,
       round(sum(prod_kwh) / 1000)  AS prod_mwh,
       round(100 * sum(prod_kwh) / sum(conso_kwh), 1) AS couverture_pct
FROM gold.synthese_collectivite_jour
WHERE id_destinataire = '488903';
-- Mesuré : 3 ms · 186 lignes lues (4,4 Ko)
-- Résultat attendu : ~10 850 MWh consommés, ~450 MWh produits, couverture ~4,1 %.

-- Q2 · "Quel jour d'octobre la Métropole de Lyon a-t-elle le plus consommé ?"
SELECT jour, round(conso_kwh / 1000, 1) AS conso_mwh
FROM gold.synthese_collectivite_jour
WHERE id_destinataire = (SELECT id_destinataire FROM ref.destinataire WHERE nom = 'Métropole de Lyon')
ORDER BY conso_kwh DESC
LIMIT 1;
-- Mesuré : 6 ms · 378 lignes lues (4,9 Ko)
-- Résultat attendu : le 30 octobre, ~80 MWh. Piège : l'agent doit trouver l'id 488904 dans ref.destinataire.

-- Q3 · "À quelle heure était la pointe de consommation du Grand Paris le 15 octobre, et combien de MW ?"
SELECT toTimeZone(ts, 'Europe/Paris') AS heure, round(puissance_kw / 1000, 2) AS mw
FROM gold.courbe_epci
WHERE code_epci = '200054781' AND grandeur = 'CONS'
  AND ts > toDateTime('2026-10-15', 'Europe/Paris') AND ts <= toDateTime('2026-10-16', 'Europe/Paris')
ORDER BY puissance_kw DESC
LIMIT 1;
-- Mesuré : 16 ms · 8 192 lignes lues (112,1 Ko)
-- Résultat attendu : 19h00 (heure de Paris), ~21,9 MW. Piège : ts est en UTC et marque la FIN de la demi-heure.

-- Q4 · "Quelles sont les 5 communes du Grand Paris qui consomment le plus par compteur ?"
SELECT dictGet('ref.dict_commune', 'nom', code_insee) AS commune,
       round(sum(energie_kwh) / sum(nb_prm), 1)       AS kwh_par_compteur_et_par_jour,
       round(sum(nb_prm) / uniqExact(jour))           AS nb_compteurs
FROM gold.energie_commune_jour
WHERE code_epci = '200054781' AND grandeur = 'CONS'
GROUP BY code_insee
HAVING nb_compteurs >= 20                              -- on écarte les communes trop petites
ORDER BY kwh_par_compteur_et_par_jour DESC
LIMIT 5;
-- Mesuré : 20 ms · 16 384 lignes lues (384,1 Ko)
-- Résultat attendu : Pantin (~223 kWh/compteur/jour), Morangis, Fresnes, Gagny, Bourg-la-Reine.
--    Bonne réponse : l'agent explique que ce sont des communes avec un site industriel (C2).

-- Q5 · "Combien d'alertes de dépassement de puissance le 30 octobre, et sur quels sites ?"
SELECT dictGet('ref.dict_epci', 'nom', code_epci) AS epci, commune, segment, id_prm,
       kva_souscrit, round(pmax_va / 1000, 1) AS pmax_kva, depassement_pct
FROM gold.alertes_pmax
WHERE jour = '2026-10-30'
ORDER BY depassement_pct DESC
LIMIT 50;
-- Mesuré : 4 ms · 514 lignes lues (11,7 Ko)
-- Résultat attendu : 6 alertes, toutes en C4 ; la pire à Paris (+25 %).

-- Q6 · "Quels jours le KPI des 99 % à 9h n'a-t-il pas été atteint ?"
SELECT jour, taux_donnees_9h_pct
FROM gold.kpi_completude_jour
WHERE taux_donnees_9h_pct < 99
ORDER BY jour;
-- Mesuré : 2 ms · 31 lignes lues
-- Résultat attendu : 6 jours (10, 16, 19, 22, 25 et 27 octobre), entre 89,7 et 94,7 %.
--  Relance attendue : "Pourquoi ?" → les fichiers arrivés après 9h
SELECT toDate(ingested_at, 'Europe/Paris') - 1 AS jour, count() AS fichiers_en_retard,
       min(toTimeZone(ingested_at, 'Europe/Paris')) AS premiere_arrivee
FROM bronze.flux_raw
WHERE code_flux = 'CDC' AND toHour(ingested_at, 'Europe/Paris') >= 9
  AND file_name NOT LIKE '%RENVOI%' AND file_name NOT LIKE '%CORRECTION%'
GROUP BY jour
ORDER BY jour;
-- Mesuré : 110 ms · 116 lignes lues (7,7 Ko)
-- Résultat attendu : 1 ou 2 fichiers (lots de 1000 compteurs) arrivés à 14h le lendemain.

-- Q7 · "Classe les métropoles de la plus solaire à la moins solaire."
SELECT collectivite, round(100 * sum(prod_kwh) / sum(conso_kwh), 1) AS couverture_pct
FROM gold.synthese_collectivite_jour
GROUP BY collectivite
ORDER BY couverture_pct DESC;
-- Mesuré : 23 ms · 186 lignes lues (7,2 Ko)
-- Résultat attendu : Toulouse et Nantes en tête (~5,3 %), Lyon dernière (~3,4 %).

-- Q8 · "De combien la consommation de Toulouse baisse-t-elle le week-end ?"
SELECT round(avgIf(conso_kwh, toDayOfWeek(jour) >= 6) / avgIf(conso_kwh, toDayOfWeek(jour) <= 5), 2) AS ratio_weekend_semaine
FROM gold.synthese_collectivite_jour
WHERE id_destinataire = '488906';
-- Mesuré : 3 ms · 186 lignes lues (3,3 Ko)
-- Résultat attendu : ~0,71, soit environ 29 % de moins le week-end.

-- Q9 · "Quelle part de la consommation vient des particuliers et petits pros (C5),
--       des PME (C4) et des industriels (C2), métropole par métropole ?"
SELECT dictGet('ref.dict_epci', 'nom', code_epci) AS epci,
       round(100 * sumIf(energie_kwh, segment = 'C5') / sum(energie_kwh), 1) AS c5_pct,
       round(100 * sumIf(energie_kwh, segment = 'C4') / sum(energie_kwh), 1) AS c4_pct,
       round(100 * sumIf(energie_kwh, segment = 'C2') / sum(energie_kwh), 1) AS c2_pct
FROM gold.energie_commune_jour
WHERE grandeur = 'CONS'
GROUP BY epci
ORDER BY epci;
-- Mesuré : 6 ms · 22 862 lignes lues (245,8 Ko)
-- Résultat attendu : les C5 entre 43 et 62 %. La part C2 varie beaucoup (6 à 39 %) : quelques gros sites suffisent.

-- Q10 · "Quels compteurs ont une énergie journalière qui ne colle pas à leur courbe CDC (écart > 3 %) ?"
--  Question plus difficile : la réponse est dans une vue (gold.v_reconciliation), pas une table.
SELECT jour, id_prm, energie_r65_kwh, round(energie_courbe_kwh, 2) AS energie_courbe_kwh, nb_points, ecart_pct
FROM gold.v_reconciliation
WHERE abs(ecart_pct) > 3
ORDER BY abs(ecart_pct) DESC
LIMIT 20;
-- Mesuré : 507 ms · 30,7 M lignes lues (841,8 Mo) · 537,1 Mo de mémoire
-- Résultat attendu : des écarts de 7 à 8 % avec 46 points au lieu de 48. Bonne réponse : l'agent relie
--    l'écart aux points manquants de la courbe (l'énergie journalière vient des index, il est complet).


-- ÉTAPE 3 · (Production) Un rôle dédié pour l'agent, en lecture seule et borné
--  Non exécuté ici. Vous pouvez le créer sur votre service et le choisir dans
--  la configuration de l'agent si l'option est proposée (non vérifié en bêta).
--  readonly = 2 interdit toute écriture ; max_rows_to_read et max_execution_time
--  bornent le coût d'une question mal posée (règle agent-query-safety).
--    CREATE SETTINGS PROFILE IF NOT EXISTS profil_agent SETTINGS
--        readonly = 2, max_execution_time = 30, max_rows_to_read = 1000000000,
--        max_result_rows = 10000, result_overflow_mode = 'break';
--    CREATE ROLE IF NOT EXISTS role_agent SETTINGS PROFILE 'profil_agent';
--    GRANT SELECT ON gold.* TO role_agent;
--    GRANT SELECT ON ref.* TO role_agent;
--    GRANT dictGet ON ref.* TO role_agent;


-- CHECKPOINT MODULE 8 (3/3)
--  Au moins 5 tables et 20 colonnes documentées.
SELECT
    if((SELECT count() FROM system.tables WHERE database = 'gold' AND comment != '') >= 5, 'OK', 'KO') AS tables_documentees,
    if((SELECT count() FROM system.columns WHERE database = 'gold' AND comment != '') >= 20, 'OK', 'KO') AS colonnes_documentees,
    if((SELECT count() FROM gold.kpi_completude_jour WHERE taux_donnees_9h_pct < 99) > 0, 'OK', 'KO') AS q6_a_une_reponse
SETTINGS select_sequential_consistency = 1;
