#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 SOURCE [THREADS=4]" >&2
  exit 2
fi
source_path="$(realpath -- "$1")"
threads="${2:-4}"
[[ "$threads" =~ ^[1-9][0-9]*$ ]] || { echo 'Nombre de threads invalide' >&2; exit 2; }
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
for profile in direct22 balanced19; do
  flags=(--direct --level 22)
  [[ "$profile" != balanced19 ]] || flags=(--balanced)
  echo "=== $profile ==="
  /usr/bin/time -f 'Temps reel: %e s | RAM maximale: %M Ko' \
    blackhole compress "$source_path" "${flags[@]}" -o "$scratch/$profile.bh" \
    +RTS "-N$threads" -RTS
  blackhole test "$scratch/$profile.bh" +RTS "-N$threads" -RTS
  stat -c 'Archive: %s octets' "$scratch/$profile.bh"
done
