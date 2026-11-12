# BlackHole V5 — correction de la progression du terminal

La sortie CLI utilise désormais une ligne courte (58 colonnes maximum, ou moins si `COLUMNS` est défini). Chaque rafraîchissement imprime `\r`, le texte compact puis des espaces jusqu’à la largeur fixe pour effacer intégralement la ligne précédente.

Cela empêche les lignes de progression longues de déborder sur une seconde ligne du terminal, situation où un simple retour chariot ne suffit pas à effacer la première ligne. Les caractères de contrôle et caractères non ASCII dans le nom affiché sont remplacés par `?` dans la console pour éviter les différences de largeur; le nom réel est inchangé pour la compression.

L'écriture est protégée par un MVar commun. Les messages détaillés utilisés par l'interface graphique (`BLACKHOLE_PROGRESS=gui`) restent inchangés pour préserver leur parsing.

Commande : `blackhole compress DOSSIER --turbo --workers 4`.

Limites : non compilé/testé sur un terminal Windows dans cet environnement, faute de GHC. Le terminal doit avoir au moins 60 colonnes lorsque `COLUMNS` n'est pas défini; si le terminal est plus étroit, définir `COLUMNS` à sa largeur effective.
