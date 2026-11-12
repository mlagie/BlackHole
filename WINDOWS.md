# BlackHole 0.12.5 — Windows natif

## Etat de validation

Les sources ont ete adaptees pour Windows 10/11 x64, sans WSL. La compilation
et les tests natifs Windows restent a executer sur Windows : cet environnement
est Linux et Wine ne demarre pas correctement. Aucun `blackhole.exe` non teste
n'est presente comme valide dans cette livraison.

Les suites Linux et la branche portable Windows activee sur Linux ont passe.
Les fichiers C, y compris Zstandard, ont ete compiles en objets Windows x86_64
COFF ; l'interface Haskell des fonctions Windows a ete verifiee par le
compilateur. Cela ne remplace pas un test du programme sur Windows reel.

## Compilation dans PowerShell

Installer GHC et Cabal via [GHCup](https://www.haskell.org/ghcup/install/).
La version utilisee pour les verifications et la CI est GHC 9.8.4 avec Cabal
3.10.3.0. Ouvrir ensuite PowerShell dans le dossier contenant blackhole.cabal.

```powershell
.\build-windows.ps1
```

Si la politique PowerShell bloque les scripts locaux, une invocation limitee
au processus est possible :

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-windows.ps1
```

Le script compile, teste puis copie le programme dans `bin-windows\blackhole.exe`
ainsi que son lanceur graphique `blackhole-progress.ps1`.
Il n'installe pas de toolchain, ne change pas le PATH ou les associations de
fichiers Windows. Si Cabal demande un catalogue de paquets :

```powershell
.\build-windows.ps1 -UpdateIndex
```

Zstandard 1.5.7 est fourni sous forme de sources et compile dans le programme
sur Windows, avec ses travailleurs natifs. Il n'est pas necessaire d'installer
une DLL zstd ou un paquet Linux. La toolchain C fait partie de l'installation
GHC Windows habituelle.

Pour ajouter BlackHole au menu contextuel de l'Explorateur pour les fichiers et
les dossiers :

```powershell
.\build-windows.ps1 -InstallContextMenu
```

Le raccourci est enregistré uniquement pour l'utilisateur courant et ouvre une
fenêtre avec une barre de progression. Il produit automatiquement `source.bh`
à côté de la source. Pour le retirer :

```powershell
.\install-windows-context-menu.ps1 -Uninstall
```

Alternative manuelle :

```powershell
cabal build all
cabal test all --test-show-details=direct '--test-options=+RTS -N2 -RTS'
cabal list-bin exe:blackhole
```

## Utilisation

```powershell
.\bin-windows\blackhole.exe --version
.\bin-windows\blackhole.exe compress '.\EpiCine-Worker' -o '.\EpiCine-Worker.bh'
.\bin-windows\blackhole.exe test '.\EpiCine-Worker.bh'
.\bin-windows\blackhole.exe extract '.\EpiCine-Worker.bh' -o '.\restauration'
```

Le profil turbo reste le defaut du ZIP fourni par l'utilisateur. `--turbo`
reste accepte. Les niveaux, codecs, options de liens et `+RTS -N4 -RTS`
restent utilisables. Les chemins de disque peuvent utiliser les antislashs,
les lecteurs et les chemins UNC habituels. Les chemins DANS l'archive restent
relatifs, separes par `/`, avec l'encodage compact BH12 s'il est plus petit.
La commande `blackhole.exe archive.bh` garde l'extraction automatique du ZIP
fourni ; aucune association Explorer n'est installee automatiquement.

## Liens et noms Windows

Les liens de fichiers et de dossiers sont distingues lors de leur creation.
Pour les nouveaux liens de dossiers Windows, une cible terminee par `/` dans
BH12 conserve la nature dossier, y compris si la cible manque. Les lecteurs
Linux traitent cette cible comme une cible de dossier. Une cible de lien
reste relative a l'emplacement du lien ; les liens sont crees apres les fichiers.

La creation de liens peut exiger le mode developpeur Windows ou les droits
adequats. Les tests signalent explicitement les tests de liens omis si ces
droits manquent. Pour compresser en ignorant les liens : `--skip-symlinks`.
Pour inclure les contenus accessibles via les liens : `--follow-symlinks` ;
les liens descendants sortant de la racine et les boucles restent rejetes.
Les liens/jonctions absolus ne sont pas preserves par defaut. Les reparse
points autres que liens/jonctions et les metadonnees NTFS comme ADS, ACL et
attributs specifiques ne sont pas representes par ce format. Un lien Windows
de type fichier visant un dossier est refuse en preservation, car BH12 ne
peut pas conserver cette combinaison incoherente sans changer son comportement.

Un projet Linux peut contenir des noms impossibles sur Windows : `CON`, `NUL`,
`a:b`, un saut de ligne, une fin de nom avec point/espace, ou deux fichiers
`a.js`/`A.js`. L'extracteur les refuse, sans renommer silencieusement les fichiers.
Les collisions usuelles sont detectees avant creation du dossier destination.
Les alias inattendus du systeme de fichiers, notamment les noms courts 8.3,
sont egalement refuses pendant la creation plutot que d'ecraser un fichier ;
une erreur a ce stade peut laisser une destination partiellement extraite.
Les limitations de longueur de chemin et les droits du disque cible restent
ceux de Windows et des API de la toolchain.

## Integration continue

`.github/workflows/build.yml` compile sur Windows et Linux, teste, produit les
binaires natifs puis echange des archives de donnees synthetiques entre les
deux systemes. Ce workflow est fourni mais n'a pas ete publie ou lance depuis
cette session. Le test d'echange Windows retire les repertoires GHC du PATH
pour detecter une eventuelle dependance DLL masquee par la machine de build.
