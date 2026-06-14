#!/usr/bin/env bash
set -euo pipefail

CXX="${CXX:-c++}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/roi_encode_demo.cpp"
OUT="$SCRIPT_DIR/roi_encode_demo"

if command -v pkg-config >/dev/null 2>&1 &&
   pkg-config --exists libavcodec libavutil; then
    CXXFLAGS_EXTRA="$(pkg-config --cflags libavcodec libavutil)"
    LDFLAGS_EXTRA="$(pkg-config --libs libavcodec libavutil)"
else
    CXXFLAGS_EXTRA="-I/opt/homebrew/include"
    LDFLAGS_EXTRA="-L/opt/homebrew/lib -Wl,-rpath,/opt/homebrew/lib -lavcodec -lavutil"
fi

"$CXX" -std=c++17 -O2 -Wall -Wextra \
    $CXXFLAGS_EXTRA \
    "$SRC" \
    $LDFLAGS_EXTRA \
    -o "$OUT"

echo "Built: $OUT"
