#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 CHEMIN_SOURCE [THREADS=4]" >&2
  exit 2
fi
source_path="$(realpath -- "$1")"
threads="${2:-4}"
if ! [[ "$threads" =~ ^[1-9][0-9]*$ ]]; then
  echo "Le nombre de threads doit etre un entier positif" >&2
  exit 2
fi
if [[ ! -e "$source_path" ]]; then
  echo "Chemin inexistant: $source_path" >&2
  exit 2
fi
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
for mode in best ultra; do
  echo "=== $mode ==="
  /usr/bin/time -f 'Temps reel: %e s | RAM maximale: %M Ko' \
    blackhole compress "$source_path" "--$mode" -o "$work/$mode.bh" \
    +RTS "-N$threads" -RTS
  blackhole test "$work/$mode.bh"
  stat -c 'Archive: %s octets' "$work/$mode.bh"
done
python3 - "$work/best.bh" "$work/ultra.bh" <<'PY'
import os,sys
b,u=[os.path.getsize(p) for p in sys.argv[1:]]
print('Difference ULTRA - BEST:', u-b, 'octets')
print('Gain:', f'{(b-u)*100/b:.2f}%' if b else 'N/A')
PY
