#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo "Usage: $0 ANCIEN_BINAIRE NOUVEAU_BINAIRE SOURCE DOSSIER_RESULTATS [THREADS=4]" >&2
  exit 2
fi
old_binary="$(realpath -- "$1")"
new_binary="$(realpath -- "$2")"
source_path="$(realpath -- "$3")"
result_path="$4"
threads="${5:-4}"
[[ "$threads" =~ ^[1-9][0-9]*$ ]] || { echo 'Nombre de threads invalide' >&2; exit 2; }
[[ -x "$old_binary" && -x "$new_binary" && -e "$source_path" ]] || exit 2
# Refuse to overwrite prior measurements.
mkdir -- "$result_path"
result_path="$(realpath -- "$result_path")"
for variant in original corrected; do
  binary="$old_binary"
  [[ "$variant" != corrected ]] || binary="$new_binary"
  /usr/bin/time -f 'elapsed_seconds=%e\nmax_rss_kib=%M' \
    -o "$result_path/$variant.time" \
    "$binary" compress "$source_path" --ultra -o "$result_path/$variant.bh" \
    +RTS "-N$threads" -RTS > "$result_path/$variant.log" 2>&1
  "$new_binary" test "$result_path/$variant.bh" +RTS "-N$threads" -RTS \
    > "$result_path/$variant.test.log" 2>&1
  # The older reader should accept the unchanged formats as well.
  "$old_binary" test "$result_path/$variant.bh" +RTS "-N$threads" -RTS \
    > "$result_path/$variant.old-reader.log" 2>&1
done
python3 - "$result_path" <<'PY'
import os,sys
root=sys.argv[1]
a,b=(os.path.getsize(os.path.join(root,n+'.bh')) for n in ('original','corrected'))
print('Original:',a,'octets')
print('Corrige:',b,'octets')
print('Economie:',a-b,'octets')
print('Reduction de taille:',f'{100*(a-b)/a:.4f}%' if a else 'N/A')
PY
