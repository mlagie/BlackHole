#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v cabal >/dev/null; then
  echo 'cabal est requis pour les tests integration' >&2
  exit 1
fi
BASE="$(mktemp -d)"
trap 'rm -rf -- "$BASE"' EXIT
mkdir -p "$BASE/project/node_modules/.bin" "$BASE/project/node_modules/bcrypt/bin"
printf 'test\n' > "$BASE/project/node_modules/bcrypt/bin/bcrypt"
ln -s ../bcrypt/bin/bcrypt "$BASE/project/node_modules/.bin/bcrypt"
cabal run exe:blackhole -- compress "$BASE/project" -o "$BASE/preserve.bh"
cabal run exe:blackhole -- extract "$BASE/preserve.bh" -o "$BASE/out"
test -L "$BASE/out/project/node_modules/.bin/bcrypt"
test "$(readlink "$BASE/out/project/node_modules/.bin/bcrypt")" = '../bcrypt/bin/bcrypt'
cabal run exe:blackhole -- compress "$BASE/project" --skip-symlinks -o "$BASE/skip.bh"
! cabal run exe:blackhole -- list "$BASE/skip.bh" | grep 'lien ->'
cabal run exe:blackhole -- compress "$BASE/project" --follow-symlinks -o "$BASE/follow.bh"
! cabal run exe:blackhole -- list "$BASE/follow.bh" | grep 'lien ->'
ln -s /etc/passwd "$BASE/project/unsafe"
if cabal run exe:blackhole -- compress "$BASE/project" -o "$BASE/unsafe.bh"; then
  echo 'ECHEC : lien externe accepte' >&2
  exit 1
fi
if cabal run exe:blackhole -- compress "$BASE/project" --follow-symlinks -o "$BASE/unsafe-follow.bh"; then
  echo 'ECHEC : suivi vers /etc/passwd accepte' >&2
  exit 1
fi
rm "$BASE/project/unsafe"
ln -s . "$BASE/project/cycle"
if cabal run exe:blackhole -- compress "$BASE/project" --follow-symlinks -o "$BASE/cycle.bh"; then
  echo 'ECHEC : boucle acceptee' >&2
  exit 1
fi
printf 'Tests symlinks reussis\n'
