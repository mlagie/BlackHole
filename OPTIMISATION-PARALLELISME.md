# Optimisation du parcours et de la compression

Changements dans `src/BlackHole/Archive.hs` :

- Le parcours Haskell traite en parallèle jusqu'à 8 branches du dossier racine, quel que soit le profil choisi. Les sous-dossiers restent séquentiels afin de ne pas saturer le disque avec des milliers de tâches. L'ordre des résultats est préservé.
- La mesure des tailles des fichiers utilise au maximum 4 tâches I/O simultanées.
- Le pool de compression n'est plus limité arbitrairement à 4 threads en mode direct/Turbo : il suit le nombre de capacités GHC, avec plafonds variables selon le codec et le niveau, pour contenir la consommation mémoire.
- En mode `Auto`, jusqu'à 8 tâches de compression au niveau inférieur à 15 ; 4 aux niveaux 15 à 19 ; 2 au-dessus. En mode Zstd explicite, jusqu'à 16 / 8 / 2 respectivement.
- La déduplication conserve les octets déjà lus pour chaque fichier unique. Le regroupement et la compression réutilisent ce cache au lieu de relire chaque fichier, sans modifier les blocs, les regroupements ni le format de l'archive.
- Les lots Zstandard multi-thread utilisent des jobs natifs de 4 Mio. Les
  lots solid Turbo de 8 à 16 Mio exposaient auparavant un job de 16 Mio et
  n'exploitaient donc souvent qu'un seul thread natif. La fenêtre de 64 Mio,
  le chevauchement et le niveau de compression sont conservés.
- Le chemin Turbo LDM utilise aussi le contexte multi-thread pour les blocs
  d'au moins 1 Mio. Les blocs plus petits restent séquentiels, car ils ne
  peuvent pas fournir assez de travail pour amortir la création des jobs.

## Important

L'architecture actuelle prépare et regroupe encore **toute** la liste des fichiers avant de lancer la compression. Ce patch ne constitue donc pas un vrai pipeline de compression en flux avec file bornée entre le parcours et la compression. Il accélère les étapes existantes sans modifier le format BH12 ni les règles de regroupement (solid/déduplication).

Pour exploiter tous les coeurs, l'exécutable doit être construit avec `-threaded` et lancé avec plusieurs capacités RTS (`+RTS -N -RTS`, déjà configuré dans le fichier cabal). Sur HDD, moins de tâches de lecture peuvent offrir de meilleures performances.

## Validation

`cabal test all --test-show-details=direct` passe. Un test CLI de compression,
d'extraction et de comparaison binaire passe également sur un corpus mixte
texte/binaire avec doublon. Le gain exact dépend du stockage et du corpus ;
`bench/benchmark.sh` reste nécessaire pour mesurer le facteur sur le corpus
de production.
