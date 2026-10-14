-- =====================================================================
--  MODULE 3 · Renvois de fichiers et corrections : ReplacingMergeTree
-- =====================================================================
--  Dans la vraie vie : un fichier est renvoyé deux fois, une courbe
--  BRUT est corrigée quelques jours plus tard. Que fait silver ?
-- =====================================================================


-- Le PRM qu'on va suivre (sim_id_prm transforme un numéro en identifiant PRM)
SELECT sim_id_prm(42) AS prm_suivi;
-- Mesuré : 2 ms · 1 ligne lue


-- ÉTAPE 1 · Un fichier est renvoyé à l'identique, 3 jours plus tard
INSERT INTO bronze.flux_raw
SELECT
    replaceOne(file_name, '_488903_', '_488903_RENVOI_') AS file_name,
    code_flux,
    ingested_at + INTERVAL 3 DAY                          AS ingested_at,
    payload
FROM bronze.flux_raw
WHERE code_flux = 'CDC'
  AND file_name LIKE 'GRD_CDC_30MIN_PUB_100280_%';   -- le lot 0 du 15 octobre
-- Mesuré : 437 ms · 624 fichiers lus (11,5 Mo de JSON) · 49 864 lignes écrites · 103,2 Mo de mémoire

--  Les points sont maintenant en double sur le disque…
--  À observer : 96 lignes pour 48 horodatages distincts. Rien n'a été écrasé à l'INSERT.
SELECT count() AS lignes, uniqExact(ts) AS points_distincts
FROM silver.courbe_charge
WHERE id_prm = sim_id_prm(42) AND jour = '2026-10-15';
-- Mesuré : 81 ms · 78 684 lignes lues (648,3 Ko)


-- ÉTAPE 2 · Trois façons de lire SANS doublons
--  a) FINAL : ClickHouse déduplique au moment de la lecture.
--     Simple et juste. Il coûte un peu plus cher qu'une lecture normale, surtout
--     sans filtre : on le réserve aux requêtes filtrées, ou aux tables gold.
SELECT count() AS lignes
FROM silver.courbe_charge FINAL
WHERE id_prm = sim_id_prm(42) AND jour = '2026-10-15';
-- Mesuré : 102 ms · 86 876 lignes lues (1,7 Mo)

--  b) argMax(valeur, version) : la valeur de la ligne dont la version est la plus
--     grande. Même résultat que FINAL, écrit à la main.
SELECT toTimeZone(ts, 'Europe/Paris') AS heure_locale, argMax(valeur_w, version) AS valeur_w
FROM silver.courbe_charge
WHERE id_prm = sim_id_prm(42) AND jour = '2026-10-15'
GROUP BY heure_locale
ORDER BY heure_locale
LIMIT 5;
-- Mesuré : 6 ms · 16 384 lignes lues (203,7 Ko)

--  c) Laisser les merges faire le ménage : ils dédupliquent en arrière-plan,
--     sans date garantie. On n'appelle PAS OPTIMIZE TABLE … FINAL : il réécrit
--     toute la partition (règle insert-optimize-avoid-final). FINAL en lecture suffit.


-- ÉTAPE 3 · Une correction : le gestionnaire de réseau republie la courbe du 15 en CORRIGE
INSERT INTO bronze.flux_raw
SELECT
    replaceOne(file_name, '_488903_', '_488903_CORRECTION_'),
    code_flux,
    ingested_at + INTERVAL 5 DAY,
    replaceAll(payload, '"etapeMetier":"BRUT"', '"etapeMetier":"CORRIGE"')
FROM bronze.flux_raw
WHERE code_flux = 'CDC'
  AND file_name LIKE 'GRD_CDC_30MIN_PUB_100280_488903_2%';
-- Mesuré : 155 ms · 625 fichiers lus (11,5 Mo de JSON) · 49 864 lignes écrites · 102,5 Mo de mémoire

SELECT etape_metier, count() AS points, max(version) AS version_retenue
FROM silver.courbe_charge FINAL
WHERE id_prm = sim_id_prm(42) AND jour = '2026-10-15'
GROUP BY etape_metier;
-- Mesuré : 139 ms · 111 452 lignes lues (2,5 Mo)
-- À observer : une seule version visible, CORRIGE a remplacé BRUT, sans aucun UPDATE.
-- C'est la façon ClickHouse de corriger : on réinsère une version plus récente
-- (règle insert-mutation-avoid-update).


-- ÉTAPE 4 · Le piège à connaître (on y revient au module 5)
--  Une MV voit les INSERT, pas l'état dédupliqué. Une somme calculée par
--  MV compterait le fichier renvoyé deux fois. Les agrégats idempotents
--  (max, min, uniq) ne sont pas affectés. Les sommes, si.
