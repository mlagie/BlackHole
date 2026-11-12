#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -lt 1 ]; then
  echo 'Usage: ./bench/compare-best.sh DOSSIER [THREADS=4]' >&2
  exit 2
fi
source_path=$1
threads=${2:-4}
base=$(mktemp -d)
trap 'rm -rf "$base"' EXIT
cabal build exe:blackhole
blackhole=$(cabal list-bin exe:blackhole)
echo '=== Base (level 8) ==='
/usr/bin/time -f 'time=%e s peak_rss=%M KiB' "$blackhole" compress "$source_path" -o "$base/base.bh" --level 8 +RTS -N"$threads" -RTS
"$blackhole" test "$base/base.bh"
echo '=== Best (level 12 + similar solid) ==='
/usr/bin/time -f 'time=%e s peak_rss=%M KiB' "$blackhole" compress "$source_path" -o "$base/best.bh" --best +RTS -N"$threads" -RTS
"$blackhole" test "$base/best.bh"
base_bytes=$(stat -c %s "$base/base.bh")
best_bytes=$(stat -c %s "$base/best.bh")
echo "base=$base_bytes bytes"
echo "best=$best_bytes bytes"
awk -v a="$base_bytes" -v b="$best_bytes" 'BEGIN {printf "relative change=%.2f%%\n", 100*(b-a)/a}'
"$blackhole" analyze "$base/best.bh"
