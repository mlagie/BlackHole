# BlackHole 0.12.5 — adaptation Windows

## Livraison et etat reel

Base : ZIP BlackHole fourni par l'utilisateur, version source 0.12.4 avec
ses modifications (turbo par defaut, extraction automatique, association
Fedora). SHA256 de ce ZIP : `13211fd24f85eb9aeffc013cbacabe3ba275ee327c3405c20b42f0ff5edf4041`.
Le ZIP original n'est pas modifie. Les anciens fichiers dist-newstyle Linux
ne sont pas reutilises dans la livraison de sources.

**Le port est implemente et les controles ci-dessous passent. La compilation
et l'execution du programme complet sur Windows natif restent a valider.**
Aucun blackhole.exe n'est fourni ou presente comme teste. Wine a echoue a
ouvrir son socket dans l'execution restreinte ; apres autorisation de son
demarrage, meme une commande Windows simple ne s'est pas terminee dans le
delai de 45 s. Les seuls processus Wine de cet essai ont ete arretes.
Le workflow Windows/Linux fourni n'a pas ete publie ni execute a distance.

## Changements

- `unix` et `System.Posix.Files` sont confines au build POSIX. Windows utilise
  les fonctions de directory pour parcourir fichiers/dossiers/liens. Le
  programme find de Windows n'est jamais utilise comme GNU find.
- Les chemins du disque utilisent le systeme hote, ceux de l'archive restent
  POSIX avec `/`. BH12, liens, references, classement et validations n'utilisent
  plus les regles Windows pour interpreter des chemins d'archive.
- Zstandard 1.5.7 est fourni en sources et compile dans la bibliotheque sur
  Windows, sans dependance a une DLL zstd externe. Les threads ZSTD sont
  actives. Linux conserve sa bibliotheque systeme par defaut ; le flag Cabal
  `-fbundled-zstd` permet d'exercer le code C fourni sur Linux aussi.
- Les liens Windows sont crees comme liens de fichiers ou de dossiers. Le
  type dossier est porte dans BH12 par une cible terminee par `/`. La lecture
  des attributs Win32 utilise des chemins etendus et des unites UTF16 explicites,
  y compris les noms non BMP (ex. emoji). Les cibles restent relatives ;
  les liens absolus/jonctions absolues ne sont pas preserves par defaut.
- Avant extraction Windows, rejet des noms interdits, lecteurs/chemins
  absolus, flux ADS, fins de noms ambigues et collisions usuelles de casse,
  y compris dossiers parents implicites. Des controles pendant la creation
  refusent d'ecraser un fichier ou de fusionner un dossier via un alias
  inattendu du systeme de fichiers, notamment 8.3. Une erreur a ce stade
  peut laisser la destination partiellement extraite.
- `build-windows.ps1`, tests CLI Python communs et CI Windows/Linux avec echange
  d'archives synthetiques. Le script ne modifie ni le PATH ni le registre.
- Les personnalisations du ZIP (turbo par defaut et extraction automatique)
  et les codecs sont conserves. Pas de nouveau format : BH01 a BH12 restent lus.

## Verification executee ici

| Controle | Resultat |
|---|---|
| Build Linux GHC 9.8.4 / libzstd systeme 1.5.7 | Reussi |
| Suite Haskell Linux | 183 assertions reussies |
| Build sans dependance directe unix, branche Windows activee sur Linux, ZSTD fourni | Reussi |
| Suite de cette branche portable | 184 assertions reussies |
| CLI defaut/turbo/balanced/direct, extraction automatique, noms Unicode/espaces/@, fichiers vides/binaires/doublons | Reussie dans les deux builds |
| Archives synthetiques echangees entre les deux builds Linux | Arborescence et SHA256 identiques |
| Interface Haskell de l'appel Win32, avec CPP Windows reel | Verifiee par GHC, sans generation d'executable |
| Sources C BlackHole + ZSTD cible Windows x86_64 COFF | 30 fichiers compiles avec Clang et headers Windows officiels GHC |
| Programme complet natif Windows / script PowerShell | Non executes ici |
| Workflow GitHub Actions Windows/Linux | Fourni, non execute |

Le flag de developpement `-fwindows-check` active les branches portables Windows
sur Linux. Il ne transforme pas Linux en Windows et ne valide pas ses API
natives. La verification d'interface Win32 et les objets COFF ne constituent
pas non plus un test du programme complet sur Windows. Les nouveaux tests
specifiques aux liens de dossiers Windows casses sont prevus pour la CI native,
et ne sont pas comptabilises comme executes ici. Si les droits de creation
manquent sur Windows, les tests de liens sont explicitement signales comme omis.

Les suites couvrent egalement les cas historiques DELTA/solid, BH10/BH11/BH12,
limites de tailles, chemins relatifs et archives malformees. Les validations
Windows incluent CON, NUL.txt, COM¹, ADS, controle/surrogate, point/espace final,
collisions de casse et parents implicites. Les tests de liens de dossiers
incluent un nom non BMP et le test unitaire UTF16 verifie sa paire de surrogates.
Les controles ne constituent pas une preuve exhaustive de tous les fichiers
malformes ni de toutes les particularites des systemes de fichiers Windows.

## Controle du corpus reel sous Linux

Une compression complete avec le nouveau binaire produit exactement les
memes octets que l'archive de reference BH12 : **69 928 291 octets**.
SHA256 : `3bcf35622cccc323de64058c0ea1c7644d30cddb159efeaff0e10b2a27bc227f`.
Aucun taux de compression ni temps Windows n'est invente.

Extraction complete par ce port : **27 593 fichiers, 2 303 dossiers et 31
liens identiques** au corpus, avec comparaison SHA256 de chaque fichier et
cible de chaque lien. Empreinte de l'inventaire :
`a7aa8e39f2a010ba5e2da95f45e68181400fd0415f328b129d50163f1c907ce5`.
Le corpus prive et ses archives ne sont pas inclus dans la livraison.

## Limites Windows a conserver en tete

- Cible du port : Windows 10/11 x64 avec GHC/Cabal (9.8.4/3.10.3.0 pour la CI).
  La confirmation du build et des tests sur cet OS reste necessaire.
- Les droits de creation de liens et les limites de chemins dependent de
  Windows et du disque. Un lien Windows de type fichier pointant vers un
  dossier est refuse en preservation, faute de representation fidele BH12.
- Les reparse points specifiques, les ADS, ACL, permissions et autres attributs
  NTFS ne sont pas ajoutes au format. Les noms Linux impossibles sur Windows
  ne sont pas renommes silencieusement. Les cibles de liens de dossiers Windows
  normalisent les separateurs et ajoutent le slash portant leur nature dossier.
- La creation des liens intervient en dernier. Une erreur de droits ou de
  longueur peut laisser une destination partiellement extraite ; elle n'est
  pas supprimee automatiquement.
- L'installeur Fedora et ses associations sont conserves mais n'ont pas ete
  executes ici. Aucun binaire installe dans votre PATH Linux n'a ete remplace.

## Compilation Windows

Apres installation GHC/Cabal via GHCup, ouvrir PowerShell dans `BlackHole` :

```powershell
.\build-windows.ps1
.\bin-windows\blackhole.exe --version
.\bin-windows\blackhole.exe compress '.\EpiCine-Worker' -o '.\EpiCine-Worker.bh'
.\bin-windows\blackhole.exe extract '.\EpiCine-Worker.bh' -o '.\restauration'
```

Voir WINDOWS.md pour la politique d'execution PowerShell, les options et les
limites. `.github/workflows/build.yml` produit des binaires natifs et controle
les echanges Linux/Windows lorsqu'il est active dans votre depot.

References utilisees pour le port :
[GHCup Windows](https://www.haskell.org/ghcup/install/),
[API directory](https://hackage-content.haskell.org/package/directory-1.3.8.5/docs/System-Directory.html),
[noms Windows](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file),
[Zstandard 1.5.7](https://github.com/facebook/zstd/releases/tag/v1.5.7).
