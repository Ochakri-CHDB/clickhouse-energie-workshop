-- =====================================================================
--  MODULE 8 · ClickHouse Agents : préparer gold, 10 questions, puis des dashboards
-- =====================================================================
--  Un agent ne devine pas le métier : il lit le schéma. Plus le schéma
--  parle, meilleures sont ses requêtes (règle agent-discovery-schema :
--  bases → tables → colonnes ET commentaires → clés de tri → échantillon).
--
--  1. On documente les tables gold avec des COMMENT (métadonnées, instantané).
--  2. On pose les 10 questions dans ClickHouse Agents (voir le README).
--  3. On compare la réponse de l'agent à la requête attendue ci-dessous.
--  4. On lui demande des DASHBOARDS : l'agent interroge ClickHouse, puis
--     construit une page interactive (outil Artifacts). C'est le moment le
--     plus visuel du workshop : configuration de l'agent dans le README.
-- =====================================================================


-- ÉTAPE 1 · Des commentaires que l'agent lira dans system.tables / system.columns
--  MODIFY COMMENT et COMMENT COLUMN ne touchent que les métadonnées : instantané,
--  aucune donnée réécrite. Les commentaires survivent aux rafraîchissements des vues.
ALTER TABLE gold.synthese_collectivite_jour
    MODIFY COMMENT 'Synthèse quotidienne par collectivité destinataire des flux de comptage (6 métropoles). Une ligne par collectivité et par jour d''octobre 2026. Énergies en kWh.';
-- Mesuré : 30 ms
ALTER TABLE gold.synthese_collectivite_jour
    COMMENT COLUMN id_destinataire 'Identifiant du destinataire (488903 = Métropole du Grand Paris, voir ref.destinataire)',
    COMMENT COLUMN jour            'Journée locale (Europe/Paris)',
    COMMENT COLUMN conso_kwh       'Énergie consommée sur le territoire ce jour, en kWh',
    COMMENT COLUMN prod_kwh        'Énergie produite (photovoltaïque) sur le territoire ce jour, en kWh',
    COMMENT COLUMN taux_couverture 'prod_kwh / conso_kwh, entre 0 et 1',
    COMMENT COLUMN nb_prm          'Nombre de compteurs (PRM) ayant remonté une courbe ce jour';
-- Mesuré : 98 ms

ALTER TABLE gold.courbe_epci
    MODIFY COMMENT 'Courbe de charge agrégée par EPCI, pas 30 min. ts = FIN de l''intervalle, en UTC : convertir avec toTimeZone(ts, ''Europe/Paris''). Filtrer sur code_epci puis ts (clé de tri).';
-- Mesuré : 101 ms
ALTER TABLE gold.courbe_epci
    COMMENT COLUMN code_epci    'Code SIREN de l''EPCI (200054781 = Métropole du Grand Paris). Libellé : dictGet(''ref.dict_epci'', ''nom'', code_epci)',
    COMMENT COLUMN grandeur     'CONS = consommation, PROD = production',
    COMMENT COLUMN ts           'Fin de l''intervalle de 30 min, UTC',
    COMMENT COLUMN puissance_kw 'Puissance moyenne sur l''intervalle, somme des compteurs, en kW',
    COMMENT COLUMN nb_prm       'Nombre de points (compteurs) agrégés';
-- Mesuré : 95 ms

ALTER TABLE gold.energie_commune_jour
    MODIFY COMMENT 'Énergie par commune, jour, segment (C5, C4, C2) et grandeur (CONS, PROD). Libellé de commune : dictGet(''ref.dict_commune'', ''nom'', code_insee).';
-- Mesuré : 87 ms
ALTER TABLE gold.energie_commune_jour
    COMMENT COLUMN segment     'C5 = particuliers et petits pros (≤ 36 kVA), C4 = PME/tertiaire (36 à 250 kVA), C2 = industriels HTA',
    COMMENT COLUMN energie_kwh 'Énergie du jour en kWh',
    COMMENT COLUMN nb_prm      'Compteurs de ce segment dans la commune ce jour (additionner les segments pour le total)';
-- Mesuré : 83 ms

ALTER TABLE gold.alertes_pmax
    MODIFY COMMENT 'Dépassements de puissance souscrite (flux PMAX). Une ligne par compteur et par jour en dépassement. Seuls les C4 et C2 peuvent dépasser (en C5 le disjoncteur coupe).';
-- Mesuré : 97 ms
ALTER TABLE gold.alertes_pmax
    COMMENT COLUMN kva_souscrit    'Puissance souscrite EN VIGUEUR ce jour-là, en kVA',
    COMMENT COLUMN pmax_va         'Puissance maximale atteinte dans la journée, en VA',
    COMMENT COLUMN depassement_pct 'Dépassement en % de la puissance souscrite',
    COMMENT COLUMN heure_pointe    'Instant de la pointe, heure de Paris';
-- Mesuré : 80 ms

ALTER TABLE gold.kpi_completude_jour
    MODIFY COMMENT 'Complétude de la collecte des courbes CDC à 9h le lendemain. Cible : taux_donnees_9h_pct >= 99.';
-- Mesuré : 90 ms
ALTER TABLE gold.kpi_completude_jour
    COMMENT COLUMN taux_donnees_9h_pct      'Points reçus avant 9h / points attendus, en %. C''est le KPI contractuel',
    COMMENT COLUMN taux_prm_complets_9h_pct 'Part des compteurs dont la journée est complète à 9h, en %';
-- Mesuré : 79 ms

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
-- Mesuré : 5 ms · 378 lignes lues (4,9 Ko)
-- Résultat attendu : le 30 octobre, ~80 MWh. Piège : l'agent doit trouver l'id 488904 dans ref.destinataire.

-- Q3 · "À quelle heure était la pointe de consommation du Grand Paris le 15 octobre, et combien de MW ?"
SELECT toTimeZone(ts, 'Europe/Paris') AS heure, round(puissance_kw / 1000, 2) AS mw
FROM gold.courbe_epci
WHERE code_epci = '200054781' AND grandeur = 'CONS'
  AND ts > toDateTime('2026-10-15', 'Europe/Paris') AND ts <= toDateTime('2026-10-16', 'Europe/Paris')
ORDER BY puissance_kw DESC
LIMIT 1;
-- Mesuré : 4 ms · 8 192 lignes lues (112,1 Ko)
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
-- Mesuré : 6 ms · 16 384 lignes lues (384,1 Ko)
-- Résultat attendu : Pantin (~223 kWh/compteur/jour), Morangis, Fresnes, Gagny, Bourg-la-Reine.
--    Bonne réponse : l'agent explique que ce sont des communes avec un site industriel (C2).

-- Q5 · "Combien d'alertes de dépassement de puissance le 30 octobre, et sur quels sites ?"
SELECT dictGet('ref.dict_epci', 'nom', code_epci) AS epci, commune, segment, id_prm,
       kva_souscrit, round(pmax_va / 1000, 1) AS pmax_kva, depassement_pct
FROM gold.alertes_pmax
WHERE jour = '2026-10-30'
ORDER BY depassement_pct DESC
LIMIT 50;
-- Mesuré : 15 ms · 514 lignes lues (11,7 Ko)
-- Résultat attendu : 6 alertes, toutes en C4 ; la pire à Paris (+25 %).

-- Q6 · "Quels jours le KPI des 99 % à 9h n'a-t-il pas été atteint ?"
SELECT jour, taux_donnees_9h_pct
FROM gold.kpi_completude_jour
WHERE taux_donnees_9h_pct < 99
ORDER BY jour;
-- Mesuré : 12 ms · 31 lignes lues
-- Résultat attendu : 6 jours (10, 16, 19, 22, 25 et 27 octobre), entre 89,7 et 94,7 %.
--  Relance attendue : "Pourquoi ?" → les fichiers arrivés après 9h
SELECT toDate(ingested_at, 'Europe/Paris') - 1 AS jour, count() AS fichiers_en_retard,
       min(toTimeZone(ingested_at, 'Europe/Paris')) AS premiere_arrivee
FROM bronze.flux_raw
WHERE code_flux = 'CDC' AND toHour(ingested_at, 'Europe/Paris') >= 9
  AND file_name NOT LIKE '%RENVOI%' AND file_name NOT LIKE '%CORRECTION%'
GROUP BY jour
ORDER BY jour;
-- Mesuré : 157 ms · 119 lignes lues (7 Ko)
-- Résultat attendu : 1 ou 2 fichiers (lots de 1000 compteurs) arrivés à 14h le lendemain.

-- Q7 · "Classe les métropoles de la plus solaire à la moins solaire."
SELECT collectivite, round(100 * sum(prod_kwh) / sum(conso_kwh), 1) AS couverture_pct
FROM gold.synthese_collectivite_jour
GROUP BY collectivite
ORDER BY couverture_pct DESC;
-- Mesuré : 3 ms · 186 lignes lues (7,2 Ko)
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
-- Mesuré : 16 ms · 22 862 lignes lues (245,8 Ko)
-- Résultat attendu : les C5 entre 43 et 62 %. La part C2 varie beaucoup (6 à 39 %) : quelques gros sites suffisent.

-- Q10 · "Quels compteurs ont une énergie journalière qui ne colle pas à leur courbe CDC (écart > 3 %) ?"
--  Question plus difficile : la réponse est dans une vue (gold.v_reconciliation), pas une table.
SELECT jour, id_prm, energie_r65_kwh, round(energie_courbe_kwh, 2) AS energie_courbe_kwh, nb_points, ecart_pct
FROM gold.v_reconciliation
WHERE abs(ecart_pct) > 3
ORDER BY abs(ecart_pct) DESC
LIMIT 20;
-- Mesuré : 332 ms · 30,7 M lignes lues (841,8 Mo) · 557,3 Mo de mémoire
-- Résultat attendu : des écarts de 7 à 8 % avec 46 points au lieu de 48. Bonne réponse : l'agent relie
--    l'écart aux points manquants de la courbe (l'énergie journalière vient des index, il est complet).


-- ÉTAPE 3 · Demander un dashboard à l'agent (le moment spectaculaire)
--  Avec les outils ClickHouse + Artifacts (+ Run Code), l'agent ne se contente
--  plus de répondre : il interroge gold, puis construit une page interactive
--  avec graphiques et chiffres clés, en quelques dizaines de secondes.
--  Collez chaque demande telle quelle dans la conversation. Les requêtes ci-dessous
--  sont celles qu'il devrait exécuter : elles servent à vérifier ses chiffres.
--  Une bonne réponse : des données réelles (jamais inventées), des unités (MW, MWh, %),
--  des titres en français, et quelques lignes d'analyse sous les graphiques.

-- D1 · "Construis un dashboard interactif de la Métropole du Grand Paris pour octobre 2026 :
--       la courbe de charge du 15 octobre (consommation et production), l'énergie jour par jour,
--       le top 10 des communes, le KPI de complétude à 9h et les alertes du dernier jour.
--       Ajoute 3 chiffres clés en haut de page."
--  Résultat attendu : 5 graphiques et 3 chiffres clés (~10 846 MWh, ~4,1 % de couverture,
--  98,4 % de KPI moyen). Ce sont les requêtes des tuiles de 01_tuiles_dashboard.sql.
SELECT round(sum(conso_kwh) / 1000) AS conso_mwh, round(100 * sum(prod_kwh) / sum(conso_kwh), 1) AS couverture_pct
FROM gold.synthese_collectivite_jour
WHERE id_destinataire = '488903';
-- Mesuré : 3 ms · 186 lignes lues (4,4 Ko)

-- D2 · "Fais une carte de chaleur jour × heure de la consommation du Grand Paris en octobre,
--       puis explique en 3 phrases ce qu'elle montre."
--  Résultat attendu : 31 lignes × 24 colonnes, de ~8 à ~23 MW. L'analyse doit citer la
--  pointe du soir (19h-20h), les week-ends plus calmes en journée, la hausse en fin de mois.
SELECT toDate(ts - 1, 'Europe/Paris') AS jour, toHour(ts - 900, 'Europe/Paris') AS heure,
       round(avg(puissance_kw) / 1000, 2) AS conso_mw
FROM gold.courbe_epci
WHERE code_epci = '200054781' AND grandeur = 'CONS'
GROUP BY jour, heure
ORDER BY jour, heure;
-- Mesuré : 4 ms · 8 192 lignes lues (112,1 Ko)

-- D3 · "Compare les 6 métropoles sur une seule page : consommation, production solaire,
--       taux de couverture et nombre d'alertes du mois. Mets en évidence la plus solaire."
--  Résultat attendu : un tableau classé et un graphique. Toulouse et Nantes en tête
--  (~5,3 % de couverture), Grand Paris de loin le plus gros consommateur (~10 846 MWh)
--  et le plus d'alertes (140 sur les 257 du mois).
SELECT s.collectivite,
       round(sum(s.conso_kwh) / 1000)                    AS conso_mwh,
       round(sum(s.prod_kwh) / 1000)                     AS prod_mwh,
       round(100 * sum(s.prod_kwh) / sum(s.conso_kwh), 1) AS couverture_pct,
       any(a.alertes)                                    AS alertes
FROM gold.synthese_collectivite_jour AS s
INNER JOIN ref.destinataire AS d ON d.id_destinataire = s.id_destinataire
LEFT JOIN (SELECT code_epci, count() AS alertes FROM gold.alertes_pmax GROUP BY code_epci) AS a ON a.code_epci = d.code_epci
GROUP BY s.collectivite
ORDER BY couverture_pct DESC;
-- Mesuré : 7 ms · 449 lignes lues (9,1 Ko)

-- D4 · "Prépare le rapport d'exploitation du 30 octobre pour le chef d'équipe : complétude
--       à 9h, fichiers arrivés en retard ce mois-ci, alertes de dépassement du jour, et
--       3 recommandations. Présente-le comme une page à imprimer."
--  Résultat attendu : KPI du 30 au-dessus de 99 %, les 6 jours sous la cible avec leurs
--  fichiers en retard (arrivés à 14h), 6 alertes C4 le 30, et des recommandations
--  concrètes (relancer les lots en retard, contacter les sites qui dépassent).
SELECT jour, taux_donnees_9h_pct FROM gold.kpi_completude_jour WHERE taux_donnees_9h_pct < 99 OR jour = '2026-10-30' ORDER BY jour;
-- Mesuré : 2 ms · 31 lignes lues

-- D5 · "Quels sites dépassent régulièrement leur puissance souscrite ? Montre-les sur un
--       graphique (dépassement moyen et nombre de jours) et dis lesquels devraient augmenter
--       leur puissance."
--  Résultat attendu : une vingtaine de sites, presque tous C4, avec 3 ou 4 jours de dépassement
--  (Lyon, Vanves, Saint-Maurice et Paris en tête avec 4 jours). Bonne réponse : l'agent
--  rappelle qu'en C5 le disjoncteur coupe avant tout dépassement.
SELECT id_prm, any(commune) AS commune, any(segment) AS segment, count() AS jours_depassement,
       round(avg(depassement_pct), 1) AS depassement_moyen_pct, max(kva_souscrit) AS kva_souscrit
FROM gold.alertes_pmax
GROUP BY id_prm
HAVING jours_depassement >= 2
ORDER BY jours_depassement DESC, depassement_moyen_pct DESC
LIMIT 20;
-- Mesuré : 4 ms · 257 lignes lues (7,8 Ko)

-- D6 · "Fais une page pour un élu de Lyon : 4 chiffres clés du mois, la courbe d'une journée
--       type de semaine et d'une journée de week-end, le tout lisible par un non-spécialiste."
--  Résultat attendu : chiffres de la Métropole de Lyon (~2 140 MWh, ~3,4 % solaire), deux
--  courbes comparées (le week-end plus bas en journée), et un texte sans jargon.
SELECT if(toDayOfWeek(toDate(ts - 1, 'Europe/Paris')) >= 6, 'week-end', 'semaine') AS type_jour,
       toHour(ts - 900, 'Europe/Paris') AS heure,
       round(avg(puissance_kw) / 1000, 2) AS conso_mw
FROM gold.courbe_epci
WHERE code_epci = '200046977' AND grandeur = 'CONS'
GROUP BY type_jour, heure
ORDER BY type_jour, heure;
-- Mesuré : 25 ms · 8 192 lignes lues (112,1 Ko)


-- ÉTAPE 4 · (Production) Un rôle dédié pour l'agent, en lecture seule et borné
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
