#!/usr/bin/env bash
set -euo pipefail
# Every invocation recompresses all input bytes; no block cache is used.
source_path="$(realpath -- "${1:?Usage: compare-turbo.sh SOURCE [THREADS]}")"
threads="${2:-4}"
case "$threads" in ''|*[!0-9]*|0) echo 'Nombre de threads invalide' >&2; exit 1;; esac
binary="$(command -v -- "${BLACKHOLE_BIN:-blackhole}")"
binary="$(realpath -- "$binary")"
output="$(mktemp -d)"
trap 'rm -rf -- "$output"' EXIT
for profile in balanced turbo; do
  for number in 1 2 3; do
    archive="$output/$profile-$number.bh"
    "$binary" compress "$source_path" "--$profile" -o "$archive" +RTS "-N$threads" -RTS
    "$binary" test "$archive" +RTS "-N$threads" -RTS
    sha256sum -- "$archive"
  done
done
