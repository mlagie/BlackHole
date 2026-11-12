#!/usr/bin/env bash
set -euo pipefail
if (( $# < 1 )); then
  echo "Usage: $0 SOURCE [COEURS=4] [REPERTOIRE_RESULTATS]" >&2
  exit 1
fi
SOURCE="$(realpath "$1")"
CORES="${2:-4}"
RESULTS="${3:-$(mktemp -d)}"
mkdir -p "$RESULTS"
RESULTS="$(realpath "$RESULTS")"
for codec in math auto zstd; do
  file="$RESULTS/$codec.bh"
  echo "=== $codec / ${CORES} coeurs ==="
  /usr/bin/time -f 'temps=%e s ram_max=%M KiB' \
    blackhole compress "$SOURCE" --codec "$codec" -o "$file" +RTS "-N$CORES" -RTS
  stat -c 'taille=%s octets' "$file"
  blackhole analyze "$file"
  blackhole test "$file"
done
