# Résultats mesurés · Workshop ClickHouse Énergie

Mesures du 8 octobre 2026, run complet depuis zéro (`./run_all.sh`, 3 min 30 au total) sur le service de test :
**ClickHouse Cloud 26.6, AWS eu-central-1, 3 répliques de 64 Go (16 vCPU chacune)**, la configuration
recommandée aux participants. Durées lues dans `system.query_log` (temps serveur). Les données sont simulées
et déterministes : volumes, lignes lues et résultats sont identiques chez chaque participant.
Les mêmes chiffres figurent en commentaire (`Mesuré`) sous chaque instruction des fichiers SQL.

> Ordres de grandeur à retenir pour les slides
> - **1,5 milliard** de points de courbe générés et écrits en **67 s** (8 lots de 8,2 à 8,7 s, ~22 M de points/s), **1,41 octet par point**
> - La courbe d'un compteur sur un mois : **16 384 lignes lues sur 1,5 milliard**, 5 à 55 ms
> - **3 répliques** sur le même scan de 1,5 milliard de lignes : **5,8 s → 2,2 s**, sans changer le SQL
> - Une projection : la pointe nationale passe de **1,3 s à 33 ms** (×39), **83 000 fois moins de lignes lues**
> - Le JSON brut compressé **×15**, les courbes typées **×18 à ×24**
> - Une tuile de dashboard sur gold : **2 à 30 ms**

---

## 00 · Premiers pas
| Mesure | Valeur |
|---|---|
| 1 million de mesures JSON générées par un SELECT | 266 ms |
| 10 millions (variante proposée, run précédent) | 2,35 s, 569 Mo de JSON |

## 01 · Fondamentaux et référentiels
| Mesure | Valeur |
|---|---|
| Communes lues en direct sur geo.api.gouv.fr | 34 969 communes, 68,95 M d'habitants, chargées en 471 ms |
| Parc de PRM généré (ASOF JOIN sur la population cumulée) | 1 000 000 en 532 ms |
| Répartition du parc | C5 98,7 % (RES 86,8 %, PRO 11,8 %), C4 1,1 %, C2 0,2 % |
| Puissance moyenne | RES 8,8 kVA, PRO C5 19,8 kVA, C4 138 kVA, C2 754 kVA |
| Historique des puissances | 1 028 889 lignes, 28 889 changements en octobre, généré en 258 ms |
| PRM des fichiers JSON chez leur destinataire | 20 000 / 20 000 (6 métropoles) |
| Compression `ref.prm` | 26,9 Mo → 7,1 Mo (×3,8). `segment` ×33 (LowCardinality), `code_insee` ×5,5 |
| Index creux : un PRM par sa clé / hors clé | 8 192 lignes lues en 4 ms / 1 000 000 en 7 ms |

## 02 · Bronze
| Mesure | Valeur |
|---|---|
| Fichiers reçus | 1 800 (600 CDC, 600 ENERGIE, 600 PMAX) |
| JSON brut | CDC 1,40 Go, ENERGIE 171 Mo, PMAX 145 Mo, total 1,71 Go |
| Sur disque (ZSTD 3) | 116 Mo, **ratio ×15** |
| 1re journée CDC (20 fichiers) | 697 ms |
| Génération + écriture CDC, 580 fichiers | 11,3 s (1,30 Go de JSON, 2,2 Go de mémoire) |
| ENERGIE, 600 fichiers / PMAX, 600 fichiers | 3,5 s / 5,4 s |
| Explorer le JSON (JSONExtract, type JSON) | 21 à 215 ms sur 64 à 600 fichiers |

## 03 · Silver
| Mesure | Valeur |
|---|---|
| Backfill : points extraits du JSON (3 ARRAY JOIN) | 29,9 M de points en 18,1 s (1,65 M points/s) |
| Rejets / énergie jour / PMax | 8 754 en 2,7 s / 625 080 en 755 ms / 600 000 en 675 ms |
| Flux continu : 20 fichiers du 31/10, MV en cascade bronze → silver → gold | 996 328 points en 5,95 s |
| Compression `silver.courbe_charge` | 1,06 Go → 45 Mo, **ratio ×24, 1,52 octet par point** |
| Par colonne | `valeur_w` 39 Mo (×3), `ts` 458 Ko (×264, Delta), `id_prm` 473 Ko (×511), `grandeur` 38 Ko (×790) |
| Renvoi d'un fichier puis correction | 48 points visibles en FINAL, version CORRIGE retenue |
| Changement d'heure du 25/10 | 50 points ce jour-là, 48 les autres |

## 04 · Dictionnaires
| Mesure | Valeur |
|---|---|
| Énergie par département, 30 M de points | dictGet 271 ms (175 Mo) · JOIN 282 ms (282 Mo) |
| Contrôle qualité dictHas sur 31 M de points | 22 ms |
| Mémoire des dictionnaires | dict_prm 87 Mo (1 M de clés), dict_puissance_asof 345 Mo, dict_commune 28 Mo |
| Rapprochement flou "Rueil Malmaizon" | Rueil-Malmaison, distance 0,23, en 9 ms |

## 05 · Gold
| Mesure | Valeur |
|---|---|
| Backfill du suivi de collecte (AggregatingMergeTree) | 618 163 lignes en 5,2 s (3,2 Go de mémoire) |
| Piège de la somme par MV, après un renvoi de fichier | 684 983 kWh au lieu de 646 706 (**+5,9 %**). `uniqExact` reste juste |
| Vues rafraîchissables | 0,29 à 0,70 s chacune |
| KPI "99 % des données à 9h" | moyenne 98,4 %, 6 jours sous 99 % (89,7 à 94,7 %), les autres à ~99,65 % |
| Alertes de dépassement de puissance | 257 sur le mois, uniquement C4 (224) et C2 (33), +14,5 % en moyenne |
| PRM ayant augmenté leur puissance | 9 alertes avant le changement, 3 après |
| Réconciliation énergie jour / courbe (31 M de points) | 235 ms. 97,6 % des PRM-jours à moins de 0,5 %, 1,9 % entre 0,5 et 3 %, 0,45 % au-delà |
| Synthèse Grand Paris, octobre | 10 846 MWh consommés, 448 MWh produits (4,1 %), 11 973 compteurs |

Calibration du simulateur (vérifiée sur les 20 000 PRM et sur le parc de 1 M) :

| Indicateur | Simulé | Repère |
|---|---|---|
| Énergie RES / PRO / ENT | 36 / 34,5 / 29,5 % | ~37 / 34 / 28 % visés |
| Week-end / semaine | 0,71 | ~0,7 visé |
| Foyer moyen | 12,1 kWh/jour | ~4,5 MWh/an |
| Site C4 / C2 | 490 kWh/jour (charge 15 %) / 4,2 MWh/jour (charge 23 %) | |
| Hausse sur octobre | +12 % du 1er au 29 | le chauffage démarre |
| Pointe | 19h, 1,95 kW par compteur | pointe du soir |

## 06 · Performance (1,488 milliard de points)
| Mesure | Valeur |
|---|---|
| Génération + écriture, 8 lots de 186 M de points | 8,2 à 8,7 s par lot, **67 s au total**, ~22 M points/s, 1,1 Go de mémoire par lot |
| Stockage | 34,4 Go bruts → 1,95 Go, **ratio ×17,6, 1,41 octet par point** |
| Par colonne | `valeur_w` 1,28 Go (×3), `id_prm` 9,7 Mo (×806), `ts` 5,4 Mo (×722), `grandeur` 2,5 Mo (×387) |
| Un an de courbes pour 3,5 M de compteurs (PRM, 61 Md de points) | ~80 Go estimés |

| Requête | Avant | Après | Lignes lues avant → après |
|---|---|---|---|
| Courbe d'un PRM sur le mois (index primaire) | | **5 à 55 ms** (250 ms à froid) | 16 384 sur 1,488 Md (2 granules sur ~180 000) |
| Énergie par département (3 Md de dictGet, scan complet) | 5,77 s | | 1,488 Md, 16,6 Go lus |
| Même requête, **3 répliques** (`enable_parallel_replicas = 1`) | 5,77 s | **2,17 s** (×2,7) | 1,488 Md (réparties sur 3 répliques) |
| Pointe nationale, **projection** | 1,3 s | **33 ms** (×39) | 1,488 Md → 17 835 |
| Conso France par jour, même projection | ~1 s | **7 ms** | 1,488 Md → 17 835 |
| Points > 100 kW, **index de saut minmax** | 692 ms | **159 ms** (×4,4) | 1,488 Md → 22,5 M (1,5 % des granules) |
| Énergie par département, **cache de requêtes** | 4,93 s | **1 ms** | 1,488 Md → 0 |

| Opération sur table chargée (run précédent, répliques de 64 Go) | Durée | Conséquence |
|---|---|---|
| `MATERIALIZE PROJECTION` (1,5 Md de lignes) | 22 s | passe dans la console, mais c'est une réécriture |
| `MATERIALIZE INDEX` (1,5 Md de lignes) | **109 s** | dépasse la limite de 60 s de la console → index déclaré dans le DDL |

## 07 · Exploitation
| Mesure | Valeur |
|---|---|
| Rebuild d'octobre depuis bronze, dédupliqué (argMax) | 30,9 M de lignes en 8,7 s (12,5 Go de mémoire) |
| Contrôle avant publication | 221 ms sur 62,8 M de lignes, prod dédupliquée = rebuild |
| `REPLACE PARTITION` (bascule atomique) | 192 ms |
| `EXCHANGE TABLES` | 15 ms |
| `DELETE` d'un PRM (RGPD), lightweight | 7,1 s |
| `ALTER UPDATE` rare sur référentiel 1 M de lignes | 1,0 s |

## 08 · Dashboards, API, Agents
| Mesure | Valeur |
|---|---|
| 5 tuiles du dashboard, filtrées par collectivité (gold) | 6 à 28 ms chacune |
| Courbe Grand Paris du 15/10 | pointe 21,9 MW à 19h, production max 2,3 MW |
| Vue paramétrée pour l'API | 3 à 30 ms, ~8 200 lignes pour une journée, 186 pour une semaine de synthèse |
| Documentation du schéma pour l'agent (COMMENT) | 67 à 120 ms par table, métadonnées seulement |
| Questions et demandes à l'agent | 2 questions, 6 dashboards, 3 exercices de data science, réponses attendues vérifiées sur le service (voir le README du module 08) |
