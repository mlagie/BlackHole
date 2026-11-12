#!/usr/bin/env bash
set -euo pipefail
binary="$(command -v -- "${BLACKHOLE_BIN:-blackhole}")"
binary="$(realpath -- "$binary")"
run_blackhole() { "$binary" "$@" +RTS -N2 -RTS; }
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/project/sub"
python3 - "$scratch/project" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]);data=bytes(range(256))*64
(root/'a.bin').write_bytes(data);(root/'b.bin').write_bytes(data)
PY
ln -s ../a.bin "$scratch/project/sub/link"
for profile in direct22 balanced19 turbo; do
  flags=(--direct --level 22)
  [[ "$profile" != balanced19 ]] || flags=(--balanced)
  [[ "$profile" != turbo ]] || flags=()
  run_blackhole compress "$scratch/project" "${flags[@]}" -o "$scratch/$profile.bh"
  run_blackhole test "$scratch/$profile.bh"
  run_blackhole extract "$scratch/$profile.bh" -o "$scratch/$profile"
  cmp -- "$scratch/project/a.bin" "$scratch/$profile/project/a.bin"
  cmp -- "$scratch/project/b.bin" "$scratch/$profile/project/b.bin"
  test "$(readlink -- "$scratch/$profile/project/sub/link")" = ../a.bin
done
# Values which happen to look like mode flags remain output filenames.
(cd "$scratch"; run_blackhole compress project -o --balanced)
run_blackhole test "$scratch/--balanced"
(cd "$scratch"; run_blackhole compress project --direct --level 19 -o --direct)
run_blackhole test "$scratch/--direct"
if run_blackhole compress "$scratch/project" --balanced --level 22 -o "$scratch/invalid.bh"; then
  echo 'ECHEC : options de niveau contradictoires acceptees' >&2
  exit 1
fi
test ! -e "$scratch/invalid.bh"
if run_blackhole compress "$scratch/project" --direct --level 23 -o "$scratch/invalid.bh"; then
  echo 'ECHEC : niveau 23 accepte' >&2
  exit 1
fi
(cd "$scratch"; run_blackhole compress project -o --turbo)
run_blackhole test "$scratch/--turbo"
if run_blackhole compress "$scratch/project" --turbo --balanced -o "$scratch/conflict.bh"; then
  echo 'ECHEC : profils contradictoires acceptes' >&2
  exit 1
fi
test ! -e "$scratch/conflict.bh"
printf 'Tests turbo/direct/balanced : modes, fichiers, liens, arguments et rejets valides\n'
