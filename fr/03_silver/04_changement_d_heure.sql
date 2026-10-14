-- =====================================================================
--  MODULE 3 · Le piège du changement d'heure (25 octobre 2026)
-- =====================================================================
--  À 3h du matin on recule à 2h : la journée dure 25 heures, soit 50
--  demi-heures. Les horodatages locaux 02:30 existent DEUX fois.
--  C'est pour ça qu'on stocke en UTC et qu'on affiche en heure locale.
-- =====================================================================


-- ÉTAPE 1 · Nombre de points par jour (heure de Paris), pour un PRM
--  À observer : 48 points les 24 et 26, 50 points le 25.
SELECT
    jour,
    count() AS nb_points
FROM silver.courbe_charge FINAL
WHERE id_prm = sim_id_prm(7) AND grandeur = 'CONS'
  AND jour BETWEEN '2026-10-24' AND '2026-10-26'
GROUP BY jour
ORDER BY jour;
-- Mesuré : 127 ms · 49 152 lignes lues (1 008 Ko)


-- ÉTAPE 2 · La nuit du 25 : même heure locale, deux instants différents
--  À observer : 02:30 apparaît deux fois en heure locale, avec un décalage +0200
--  puis +0100. En UTC, aucun doublon : c'est pour ça que ts est stocké en UTC.
SELECT
    ts                                    AS ts_utc,
    toTimeZone(ts, 'Europe/Paris')        AS heure_locale,
    formatDateTime(ts, '%z', 'Europe/Paris') AS decalage,
    valeur_w
FROM silver.courbe_charge FINAL
WHERE id_prm = sim_id_prm(7) AND grandeur = 'CONS'
  AND ts BETWEEN '2026-10-24 23:00:00' AND '2026-10-25 03:00:00'
ORDER BY ts;
-- Mesuré : 121 ms · 16 384 lignes lues (400 Ko)


-- ÉTAPE 3 · Le nombre de points attendus se calcule, il ne se suppose pas
--  On mesure la durée réelle de la journée locale en minutes, puis on divise par 30.
--  Le KPI de complétude du module 5 utilise exactement ce calcul.
SELECT
    jour,
    dateDiff('minute', toDateTime(jour, 'Europe/Paris'), toDateTime(jour + 1, 'Europe/Paris')) / 30 AS points_attendus
FROM (SELECT toDate('2026-10-23') + number AS jour FROM numbers(5));
-- Mesuré : 2 ms · 5 lignes lues
