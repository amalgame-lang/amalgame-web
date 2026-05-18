#!/bin/bash
# ─────────────────────────────────────────────────────
#  amalgame-web (Mosaic) — Test Runner
#  Usage: ./tests/run_tests.sh [path-to-amc]
# ─────────────────────────────────────────────────────
set -e

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"

AMC=""
if [ -n "$1" ]; then
    AMC="$1"
elif [ -x "./amc" ]; then
    AMC="$(pwd)/amc"
elif command -v amc >/dev/null 2>&1; then
    AMC="$(command -v amc)"
elif [ -x "$PKG_DIR/../Amalgame/amc" ]; then
    AMC="$PKG_DIR/../Amalgame/amc"
elif [ -x "$HOME/.local/bin/amc" ]; then
    AMC="$HOME/.local/bin/amc"
fi
if [ -z "$AMC" ] || [ ! -x "$AMC" ]; then
    echo "error: amc binary not found"
    exit 2
fi

RUNTIME_DIR=""
if [ -d "$PKG_DIR/../Amalgame/runtime" ]; then
    RUNTIME_DIR="$PKG_DIR/../Amalgame/runtime"
elif [ -d "$HOME/.amalgame/runtime" ]; then
    RUNTIME_DIR="$HOME/.amalgame/runtime"
fi

BUILD_DIR=$(mktemp -d -t amalgame-web-XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

echo "Using amc: $AMC"
cd "$PKG_DIR"

# Build facade.o once
"$AMC" --lib -o "$BUILD_DIR/facade" facade.am 2>&1 | tail -2
gcc -O2 -Iruntime -I"$RUNTIME_DIR" -c "$BUILD_DIR/facade.c" -o "$BUILD_DIR/facade.o" 2>&1 | head -5
[ -s "$BUILD_DIR/facade.o" ] || { echo -e "${RED}facade build failed${NC}"; exit 1; }

# Router tests
"$AMC" -o "$BUILD_DIR/router_test" tests/router_test.am --external facade.am 2>&1 | tail -2
gcc -O2 -Iruntime -I"$RUNTIME_DIR" "$BUILD_DIR/router_test.c" "$BUILD_DIR/facade.o" \
    -lgc -lm -lcurl -lz -o "$BUILD_DIR/router_test" 2>&1 | head -5
[ -x "$BUILD_DIR/router_test" ] || { echo -e "${RED}router build failed${NC}"; exit 1; }

"$BUILD_DIR/router_test"

echo -e "\n${GREEN}All tests completed${NC}"
