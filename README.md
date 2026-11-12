# BlackHole 0.12.5

Archiveur Haskell sans perte. Le profil turbo est utilise par defaut : il
conserve les optimisations texte de 0.12.3 et ajoute l'encodage relatif des
chemins quand il reduit la taille finale de l'archive.

## Windows natif

La version 0.12.5 contient le port Windows et un script de compilation :

```powershell
.\build-windows.ps1
.\bin-windows\blackhole.exe compress '.\EpiCine-Worker' -o '.\EpiCine-Worker.bh'
```

GHC/Cabal sont requis ; Zstandard est fourni et compile dans le programme.
Voir [WINDOWS.md](WINDOWS.md) pour la procedure et les limites. Les tests
Linux et de la branche Windows sur Linux passent ; la compilation et
l'execution du programme complet sur Windows reel restent a valider.
Le ZIP ne contient pas d'executable Windows presente comme teste.
Sur Windows, `.\build-windows.ps1 -InstallContextMenu` ajoute « Compresser avec
BlackHole » au clic droit des fichiers et dossiers, avec une fenêtre graphique
et une barre de progression. Sur Fedora/GNOME, `install-fedora.sh` ajoute aussi
une barre de progression dans l'action `Scripts` du clic droit de Nautilus.

## Installation Fedora

```bash
unzip BlackHole-0.12.5-Windows-Linux-Sources.zip
cd BlackHole
./install-fedora.sh
blackhole --version
```

Le script compile, teste et installe dans `~/.local/bin`. Si une autre version
est trouvee en premier dans PATH, utiliser `~/.local/bin/blackhole`.
Il associe aussi les fichiers `.bh` a BlackHole : un double-clic extrait
l'archive dans un dossier portant son nom. Si ce dossier existe, un suffixe
`-copy` est ajoute, puis incremente si necessaire.
Apres une mise a jour depuis une ancienne version, relancer `./install-fedora.sh`
une fois pour enregistrer le type MIME aupres du gestionnaire de fichiers.

## Compression

```bash
blackhole compress EpiCine-Worker/ -o EpiCine-Worker.bh +RTS -N4 -RTS
blackhole test EpiCine-Worker-TURBO.bh
blackhole extract EpiCine-Worker-TURBO.bh -o restauration
# Equivalent au double-clic dans le gestionnaire de fichiers :
blackhole EpiCine-Worker-TURBO.bh
```

Tous les fichiers sont relus et recompresses a chaque execution, sans cache
persistant de blocs. Les doublons exacts sont references dans l'archive.
Le profil turbo peut employer jusqu'a quatre groupes simultanes et quatre
travailleurs ZSTD natifs par groupe ; `-N4` ne limite pas leur total a quatre.

## Chemins relatifs BH12

Pour chaque entree, le format stocke un nombre de remontees et le suffixe
restant. Le dossier courant est celui du parent du dernier fichier, ou le
dossier lui-meme pour une entree dossier. Une reference vers un autre fichier
ne deplace pas le dossier courant. Les liens symboliques gardent leur cible
litterale, y compris `..`.

Ces instructions sont des champs binaires distincts, pas des caracteres `@`.
Un nom `@fichier.js`, un saut de ligne, un nom Unicode ou un contenu contenant
`@@` ne peuvent pas etre confondus avec une remontee. Les caracteres de noms
non UTF8 conserves par l'encodage du systeme sont preservables egalement.

Les metadonnees sont ensuite compressees ensemble avec ZSTD niveau 9. Les
blocs de contenu restent identiques. L'encodeur compare les tailles finales
reelles avec les formats precedents et garde le plus petit : aucune regression
de taille introduite par le choix des chemins relatifs pour une meme archive.
Cela s'applique aussi a balanced et aux autres profils.

**Une archive BH12 exige BlackHole 0.12.4 ou plus recent pour etre lue.**
Les anciens formats BH01 a BH11 restent lisibles. L'ecriture peut encore
choisir un ancien format s'il est plus petit. Pour conserver la compatibilite
avec un lecteur ancien, employer l'ancienne version pour creer l'archive.

Mesure historique 0.12.4 sur le corpus : BH12 gagne 53 910 octets : 69 928 291 octets au total,
contre 69 982 201 avec 0.12.3. Une compression complete mesuree prend 11,92 s
murales (11,81 s affiches par le programme). La cible reproductible de 6–10 s
reste ouverte ; aucun taux de 25 % n'est annonce.

## Autres profils et commandes

```bash
blackhole compress source/ --balanced -o balanced.bh +RTS -N4 -RTS
blackhole compress source/ --direct --level 22 -o direct.bh +RTS -N4 -RTS
blackhole compress source/ --level 22 -o recherche.bh +RTS -N4 -RTS
blackhole analyze archive.bh
blackhole list archive.bh
```

Les profils `--fast`, `--best`, `--ultra`, `--balanced`, `--codec auto|zstd|math|raw` et
les options de liens preserves, ignores ou suivis restent disponibles.
Turbo est le profil par defaut ; `--turbo` reste accepte pour compatibilite.
Balanced et direct restent disponibles comme profils explicites.
Le parcours physique utilise GNU find si disponible ; un repli Haskell
est conserve, notamment pour suivre les liens.

## Tests

```bash
cabal test all --test-show-details=direct
BLACKHOLE_BIN="$(cabal list-bin exe:blackhole)" ./test/direct-integration.sh
./test/native-transforms.sh
```

Le dernier test necessite les runtimes des sanitizers C. Dans un environnement
trace ou sans runtime UBSan GCC :

```bash
CC=clang ASAN_OPTIONS=detect_leaks=0 ./test/native-transforms.sh
```

Voir `VALIDATION-PERFORMANCE.md` pour le corpus, les mesures, les limites et
la verification integrale de la restauration.

### Journal détaillé de compression

Pour analyser les temps d'attente et la complexité réelle d'une compression,
activer le journal événementiel :

```bash
blackhole compress VSCode-linux-x64 -o VSCode-linux-x64.bh --trace \
  2> compression-trace.tsv
```

Le fichier TSV contient un timestamp monotone en nanosecondes, le début et la
fin des phases, la durée, les lots, les tailles source/encodées, les candidats
solid/DELTA/chunk, ainsi que le début et la fin de chaque tâche worker. Les
événements `worker_task_start` permettent de mesurer l'attente entre la mise
en file et l'exécution ; `compression_batch_end` permet de comparer le coût
CPU de chaque lot à son gain de taille. Le journal est désactivé par défaut.

### Indicateurs de progression (CLI et interface graphique)

Pendant la **compression**, BlackHole affiche le pourcentage, le débit des
données source traitées (MiB/s) et le temps restant estimé. Lors de la phase
d'**écriture**, il affiche le pourcentage des octets de l'archive effectivement
transmis au fichier, leur débit (MiB/s) et le temps restant estimé. Le débit
d'écriture correspond aux appels d'écriture du système et non à une mesure
de synchronisation physique sur disque (cache du système d'exploitation).
La progression et l'estimation redémarrent à zéro pour l'écriture ; cette
phase suit la sérialisation de l'archive. Les estimations ne sont fiables
qu'après quelques mesures.

Dans la console : `blackhole compress CHEMIN -o sortie.bh`. Le lanceur
Windows `blackhole-progress.ps1` et l'intégration Nautilus présentent
également les informations.

### Compression parallèle avec plusieurs workers

La commande `blackhole compress DOSSIER --workers 4 --turbo` utilise quatre workers de compression.
Les fichiers sont regroupés en *lots solid* puis envoyés à une file partagée. Les workers
prennent le prochain lot libre au lieu de recevoir chacun exactement un quart des fichiers :
un fichier volumineux n'empêche donc pas les autres workers de continuer. La taille cible
des lots est adaptée pour proposer plusieurs tâches par worker, avec un minimum de 1 Mio
pour conserver le bénéfice de la compression solid. L'ordre de l'archive reste déterministe.

Pour une estimation plus claire, la vitesse affichée pendant `Compression` représente
les **octets source traités par seconde**, et non les écritures disque. Pendant
`Ecriture`, la vitesse correspond aux octets remis au système d'exploitation.
Le débit physique du SSD peut différer à cause du cache disque.
L'interface PowerShell démarre avec 4 workers par défaut.

L'affichage console remplace intégralement la ligne de progression précédente,
y compris lorsque le nom du fichier courant devient plus court. Lorsque la sortie
est redirigée, la progression est écrite ligne par ligne.
