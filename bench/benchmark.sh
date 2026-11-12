#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 DOSSIER_OU_FICHIER [RESULTATS_DIR]" >&2
  exit 1
fi
SOURCE="$(realpath "$1")"
OUT="${2:-$(mktemp -d)}"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
NAME="$(basename "$SOURCE")"
echo "Résultats: $OUT"
for level in fast default best; do
  ARGS=()
  case "$level" in
    fast) ARGS=(--fast);;
    best) ARGS=(--best);;
  esac
  echo "=== BlackHole $level ==="
  /usr/bin/time -f 'temps=%e s pic-memoire=%M KiB' \
    blackhole compress "$SOURCE" -o "$OUT/$NAME-$level.bh" "${ARGS[@]}"
  stat -c 'taille=%s octets' "$OUT/$NAME-$level.bh"
  blackhole test "$OUT/$NAME-$level.bh"
done
if command -v zstd >/dev/null; then
  if [[ -f "$SOURCE" ]]; then
    /usr/bin/time -f 'zstd temps=%e s memoire=%M KiB' \
      zstd -3 -f -q "$SOURCE" -o "$OUT/$NAME.zst"
    stat -c 'zstd taille=%s octets' "$OUT/$NAME.zst"
  else
    echo 'Comparer dossiers : tar+zstd requiert une commande additionnelle.'
  fi
fi
