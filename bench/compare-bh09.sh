#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 CHEMIN_SOURCE [CAPACITES_CPU]" >&2
  exit 2
fi

source=$1
cpu=${2:-4}
command -v blackhole >/dev/null || { echo 'blackhole introuvable' >&2; exit 1; }
command -v stat >/dev/null || exit 1

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

echo '=== Variante de reference : ZSTD niveau 8 ==='
/usr/bin/time -f 'Temps reel %e s, RAM max %M Kio' \
  blackhole compress "$source" --level 8 -o "$scratch/reference.bh" \
  +RTS "-N${cpu}" -RTS
blackhole test "$scratch/reference.bh"

echo '=== Variante qualite : --best (ZSTD niveau 12 + BH09 optionnel) ==='
/usr/bin/time -f 'Temps reel %e s, RAM max %M Kio' \
  blackhole compress "$source" --best -o "$scratch/best.bh" \
  +RTS "-N${cpu}" -RTS
blackhole test "$scratch/best.bh"

python3 - "$scratch/reference.bh" "$scratch/best.bh" <<'PY'
from pathlib import Path
import sys
baseline, best = [Path(p).stat().st_size for p in sys.argv[1:]]
print(f'Archive de reference : {baseline:,} octets')
print(f'Archive --best     : {best:,} octets')
print(f'Variation          : {best-baseline:+,} octets')
print(f'Gain relatif       : {(baseline-best)/baseline*100:.2f}%')
PY

printf 'Format final --best : '
head -c 4 "$scratch/best.bh"; printf '\n'

echo 'Les deux archives ont passe blackhole test.'
echo 'Pour un controle integral, extraire dans un nouveau dossier et comparer les fichiers.'
