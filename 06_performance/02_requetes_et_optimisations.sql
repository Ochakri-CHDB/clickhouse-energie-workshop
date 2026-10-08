-- =====================================================================
--  MODULE 6 · Lire vite : index primaire, projection, index de saut,
--             répliques parallèles, cache
-- =====================================================================
--  Pour chaque requête, notez dans la console : durée, lignes lues, Go lus.
--  Les chiffres "Mesuré" viennent du service de test : 3 répliques de
--  64 Go (16 vCPU), configuré comme le vôtre, sur 1,488 Md de points.
--
--  Les cinq leviers, du plus important au plus ponctuel :
--    1. lire moins de lignes grâce à l'ORDER BY (index primaire)
--    2. répartir un gros scan sur toutes les répliques (parallel replicas)
--    3. pré-agréger (projection)
--    4. sauter des blocs sur une colonne hors clé (index de saut)
--    5. ne pas recalculer ce qui vient d'être calculé (cache de requêtes)
-- =====================================================================


-- REQUÊTE 1 · La courbe d'UN compteur sur le mois (le cas du portail client)
--  Le filtre suit le début de l'ORDER BY (grandeur, id_prm) : ClickHouse saute
--  directement aux bons granules (règle schema-pk-filter-on-orderby).
SELECT toTimeZone(ts, 'Europe/Paris') AS heure, valeur_w
FROM silver.courbe_charge_xl
WHERE grandeur = 'CONS' AND id_prm = sim_id_prm(123456)   -- les 2 premières colonnes de l'ORDER BY
ORDER BY ts;
-- Mesuré : 16 384 lignes lues (272 Ko) · 250 à 265 ms au premier appel sur une réplique
-- (lecture sur S3), puis 5 à 55 ms : le cache disque local de la réplique a pris le relais

--  EXPLAIN indexes = 1 montre ce que l'index a éliminé, sans exécuter la requête.
EXPLAIN indexes = 1
SELECT valeur_w FROM silver.courbe_charge_xl WHERE grandeur = 'CONS' AND id_prm = sim_id_prm(123456);
-- À observer : sous "PrimaryKey", la ligne "Granules". Deux granules de 8 192 lignes
-- lus sur ~180 000 : c'est pour ça que la requête est instantanée.


-- REQUÊTE 2 · Par département : 1,5 milliard de lignes, 3 milliards de dictGet
--  Ici aucun index ne peut aider : on veut TOUTES les lignes. C'est un scan
--  complet, et sa vitesse dépend du nombre de cœurs qui y travaillent.
SELECT
    dictGet('ref.dict_commune', 'code_dept', dictGet('ref.dict_prm', 'code_insee', id_prm)) AS dept,
    dictGet('ref.dict_departement', 'nom', dept) AS departement,
    round(sum(valeur_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.courbe_charge_xl
GROUP BY dept
ORDER BY gwh DESC
LIMIT 10;
-- Mesuré : 5,77 s · 1,488 Md lignes lues (16,6 Go) · 388,3 Mo de mémoire


-- OPTIMISATION A · Répartir le scan sur les 3 répliques (parallel replicas)
--  Par défaut, une requête s'exécute sur la réplique qui la reçoit. Avec
--  enable_parallel_replicas = 1, la table est découpée en morceaux et chaque
--  réplique en traite une partie. C'est la séparation stockage/calcul :
--  toutes les répliques lisent les mêmes données sur S3, il suffit d'ajouter
--  du calcul pour aller plus vite.
SELECT
    dictGet('ref.dict_commune', 'code_dept', dictGet('ref.dict_prm', 'code_insee', id_prm)) AS dept,
    dictGet('ref.dict_departement', 'nom', dept) AS departement,
    round(sum(valeur_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.courbe_charge_xl
GROUP BY dept
ORDER BY gwh DESC
LIMIT 10
SETTINGS enable_parallel_replicas = 1;
-- Mesuré : 2,17 s · 1,488 Md lignes lues (16,6 Go) · 197,1 Mo de mémoire
-- Gain : 5,77 s → 2,17 s (×2,7) avec 3 répliques, sans changer une ligne de SQL
-- À observer : même résultat, même nombre de lignes lues, durée divisée par
-- environ le nombre de répliques. Le gain est le plus fort sur les requêtes
-- qui calculent beaucoup par ligne (ici les dictGet).


-- OPTIMISATION B · La PROJECTION d'agrégation (déclarée à la création de la table)
--  L'optimiseur choisit tout seul de lire la projection quand elle répond à
--  la question : la requête ne change pas. Pour mesurer l'écart, on la désactive
--  d'abord avec optimize_use_projections = 0.
--  La pointe nationale du mois, SANS la projection :
SELECT toTimeZone(ts, 'Europe/Paris') AS instant, round(sum(valeur_w) / 1e6) AS mw
FROM silver.courbe_charge_xl
GROUP BY ts
ORDER BY mw DESC
LIMIT 5
SETTINGS optimize_use_projections = 0;
-- Mesuré : 1,3 s · 1,488 Md lignes lues (11,1 Go) · 229,5 Mo de mémoire

--  … et AVEC (le réglage par défaut) :
SELECT toTimeZone(ts, 'Europe/Paris') AS instant, round(sum(valeur_w) / 1e6) AS mw
FROM silver.courbe_charge_xl
GROUP BY ts
ORDER BY mw DESC
LIMIT 5;
-- Mesuré : 33 ms · 17 835 lignes lues (348,3 Ko)
-- Gain : 1,3 s → 33 ms (×39), et 83 000 fois moins de lignes lues
-- À observer : même résultat, quelques milliers de lignes lues au lieu de 1,5 milliard.
-- La projection contient déjà une ligne par demi-heure (et par part).

--  Bonus : la conso France jour par jour profite de la même projection,
--  car toDate(ts) se calcule à partir de ts, qui est dans la projection.
SELECT toDate(ts - 1, 'Europe/Paris') AS jour, round(sum(valeur_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.courbe_charge_xl
GROUP BY jour
ORDER BY jour;
-- Mesuré : 7 ms · 17 835 lignes lues (348,3 Ko), contre ~1 s et 1,488 Md de lignes sans projection

--  Sur une table déjà chargée, on ajouterait la projection ainsi :
--    ALTER TABLE silver.courbe_charge_xl ADD PROJECTION p_courbe_nationale (SELECT ts, sum(valeur_w), count() GROUP BY ts);
--    ALTER TABLE silver.courbe_charge_xl MATERIALIZE PROJECTION p_courbe_nationale SETTINGS mutations_sync = 1;
--  MATERIALIZE réécrit toutes les parts existantes : sur 1,5 Md de lignes il faut
--  compter une vingtaine de secondes (mesuré : 22 s), à planifier hors des heures de pointe.


-- OPTIMISATION C · L'INDEX DE SAUT minmax sur la valeur
--  "Quels points dépassent 100 kW ?" : seuls les gros sites industriels (C2)
--  atteignent ce niveau. Ils sont ~0,2 % du parc, donc la plupart des granules
--  ont un max sous 100 kW et peuvent être sautés.
--  SANS l'index (use_skip_indexes = 0) :
SELECT count() AS points_sup_100kw, uniqExact(id_prm) AS prm
FROM silver.courbe_charge_xl
WHERE valeur_w > 100000
SETTINGS use_skip_indexes = 0;
-- Mesuré : 692 ms · 1,488 Md lignes lues (5,7 Go) · 250 Mo de mémoire

--  AVEC l'index :
SELECT count() AS points_sup_100kw, uniqExact(id_prm) AS prm
FROM silver.courbe_charge_xl
WHERE valeur_w > 100000;
-- Mesuré : 159 ms · 22,5 M lignes lues (245,6 Mo) · 106,5 Mo de mémoire
-- Gain : 692 ms → 159 ms (×4,4), 1,5 % de la table lue

EXPLAIN indexes = 1
SELECT count() FROM silver.courbe_charge_xl WHERE valeur_w > 100000;
-- À observer : sous "Skip", le nombre de granules gardés, une petite fraction de la table.
-- Un index de saut n'aide que si les valeurs recherchées sont regroupées dans peu
-- de granules. Sur une colonne où toutes les valeurs se mélangent, il ne saute rien.
--  Sur une table déjà chargée : ALTER TABLE … ADD INDEX, puis MATERIALIZE INDEX.
--  Attention : MATERIALIZE INDEX sur 1,5 Md de lignes dépasse largement 60 s (mesuré : 109 s)
--  (la console abandonne). C'est pour ça qu'on déclare l'index dans le CREATE TABLE.


-- OPTIMISATION D · Le cache de requêtes (dashboards rafraîchis en boucle)
--  Le résultat d'une requête est gardé en mémoire pendant query_cache_ttl secondes.
--  La même requête, avec le même texte et les mêmes réglages, est servie depuis
--  le cache sans rien relire.
--  Attention : dictGet est jugé "non déterministe" (le dictionnaire peut être
--  rechargé) : sans query_cache_nondeterministic_function_handling, ClickHouse
--  refuse de cacher (erreur 704). Ici les référentiels changent au plus toutes
--  les heures, un TTL de 5 min est sans risque.
--  On vide d'abord le cache, pour que la démo parte de zéro même si vous relancez
--  le fichier (le cache survit à la recréation des tables, voir plus bas).
SYSTEM DROP QUERY CACHE;

SELECT
    dictGet('ref.dict_commune', 'code_dept', dictGet('ref.dict_prm', 'code_insee', id_prm)) AS dept,
    dictGet('ref.dict_departement', 'nom', dept) AS departement,
    round(sum(valeur_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.courbe_charge_xl
GROUP BY dept
ORDER BY gwh DESC
LIMIT 10
SETTINGS use_query_cache = 1, query_cache_ttl = 300,
         query_cache_nondeterministic_function_handling = 'save';
-- Mesuré : 4,93 s · 1,488 Md lignes lues (16,6 Go) · 387,7 Mo de mémoire

--  … relancez exactement la même requête :
SELECT
    dictGet('ref.dict_commune', 'code_dept', dictGet('ref.dict_prm', 'code_insee', id_prm)) AS dept,
    dictGet('ref.dict_departement', 'nom', dept) AS departement,
    round(sum(valeur_w) * 0.5 / 1e9, 2) AS gwh
FROM silver.courbe_charge_xl
GROUP BY dept
ORDER BY gwh DESC
LIMIT 10
SETTINGS use_query_cache = 1, query_cache_ttl = 300,
         query_cache_nondeterministic_function_handling = 'save';
-- Mesuré : 1 ms (résultat servi par le cache, aucune donnée relue)
-- Gain : 4,93 s → 1 ms
-- À observer : la 2e exécution répond en une milliseconde et ne lit aucune ligne.
-- Attention : le cache est propre à chaque réplique. Si la console vous envoie sur
-- une autre réplique, le 1er appel y recalcule : relancez une fois de plus.
-- Attention : le cache n'est PAS vidé quand la table change, seul le TTL compte.
-- On le réserve aux tuiles où quelques minutes de retard sont acceptables.


-- POUR ALLER PLUS LOIN · PREWHERE est automatique
--  ClickHouse lit d'abord la colonne du filtre le plus sélectif (id_prm), puis
--  seulement les autres colonnes des lignes retenues. EXPLAIN le montre.
EXPLAIN actions = 1
SELECT sum(valeur_w) FROM silver.courbe_charge_xl WHERE id_prm = sim_id_prm(42) AND valeur_w > 1000;
