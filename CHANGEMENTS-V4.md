# BlackHole V4 — workers et terminal

- `blackhole compress SOURCE --workers 4 --turbo` : quatre workers prennent les lots disponibles dans une file partagée.
- Les fichiers ne sont pas divisés arbitrairement en quatre listes identiques ; les lots sont attribués aux premiers workers libres. Le regroupement solid conserve les fichiers similaires ensemble.
- Les tailles des lots s'adaptent au volume total afin d'éviter un seul immense travail de compression, avec bornes de 1 à 64 Mio.
- Le rendu de la progression en terminal remplace entièrement la ligne précédente (effacement par espaces), sans supposer un support ANSI.
- Si stdout n'est pas un terminal, la progression reste ligne par ligne.
- La fenêtre PowerShell utilise `--workers 4` par défaut.

**Attention** : `Compression : Débit` est le débit de traitement du contenu source. `Ecriture : Débit` mesure les octets envoyés au système de fichiers et non la vitesse physique garantie du SSD. Multiplier les workers ne garantit pas un gain si les données sont incompressibles ou si le CPU, le disque ou la RAM limitent le débit.

**Validation** : contrôles statiques effectués ; compilateur GHC absent dans l'environnement, compilation et benchmarks à exécuter sur l'ordinateur cible.
