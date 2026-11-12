---
applyTo: "**/*.hs,**/*.cabal,**/package.yaml,**/stack.yaml"
---

# Bonnes pratiques Haskell

## Sûreté
- Pas de fonctions partielles (`head`, `tail`, `fromJust`, `!!`, `read`, `error`). Utiliser `Maybe`, `Either`, `NonEmpty`, `readMaybe`, le pattern matching.
- Définitions totales ; garder `-Wincomplete-patterns` actif.
- Erreurs attendues : `Either` ou un type d'erreur dédié, pas d'exceptions.

## Types
- Écrire la signature de type avant l'implémentation.
- `newtype` pour distinguer les concepts (`UserId`, `Email`) au lieu d'`Int`/`String` bruts.
- Types sommes plutôt que booléens ou chaînes magiques ; rendre les états illégaux irreprésentables.
- Records à champs nommés dès 3 champs.
- `Text` pour le texte, `ByteString` pour le binaire, `Data.Map.Strict`/`Set`/`Vector` plutôt que des listes pour la recherche.
- `deriving stock` / `deriving newtype` explicites.

## Style
- Fonctions pures ; IO isolé aux frontières.
- Noms explicites, fonctions courtes, pas de point-free illisible.
- `traverse`, `foldl'`, `mapM_` plutôt que la récursion manuelle quand c'est plus clair.
- Imports qualifiés pour les conflits de noms ; exports explicites dans chaque module.
- Haddock (`-- |`) sur tout ce qui est exporté.
- Pas de Template Haskell, type families ou GADTs sans besoin réel.

## Performance
- `foldl'` plutôt que `foldl` ; champs stricts dans les structures durables.
- Mesurer (profiling, criterion/tasty-bench) avant d'optimiser.

## Effets
- Contraintes de classes minimales ; pas de `Monad m =>` inutile.
- Applications : `ReaderT Env IO` ou `mtl` simple, pas de piles de transformers profondes.
- Pas d'instances orphelines.

## Outillage et tests
- Compiler avec `-Wall -Wextra` ; formater avec `ormolu`/`fourmolu` ; linter avec `hlint`.
- Bornes de dépendances respectant le PVP.
- Hspec ou Tasty pour les tests unitaires, QuickCheck pour les propriétés, doctest pour les exemples.

## Réponses attendues
- Code qui compile ; indiquer la version de GHC, les extensions et les `build-depends`.
- En revue de code : signaler d'abord fonctions partielles, problèmes de paresse et erreurs de modélisation, puis proposer la correction.