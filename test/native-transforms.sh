#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
binary="$(mktemp)"
trap 'rm -f -- "$binary"' EXIT
"${CC:-cc}" -O1 -g -fsanitize="${SANITIZERS:-address,undefined}" -fno-omit-frame-pointer -Wall -Wextra test/native-transforms.c cbits/normalize.c cbits/words.c -o "$binary"
ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1}" "$binary"
