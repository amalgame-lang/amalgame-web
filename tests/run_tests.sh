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
if [ -n "$AMC_RUNTIME" ] && [ -d "$AMC_RUNTIME" ]; then
    RUNTIME_DIR="$AMC_RUNTIME"
elif [ -d "$PKG_DIR/../Amalgame/runtime" ]; then
    RUNTIME_DIR="$PKG_DIR/../Amalgame/runtime"
elif [ -d "$HOME/.amalgame/runtime" ]; then
    RUNTIME_DIR="$HOME/.amalgame/runtime"
fi

BUILD_DIR=$(mktemp -d -t amalgame-web-XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

echo "Using amc: $AMC"
cd "$PKG_DIR"

# Locate amalgame-net-http (sibling repo) — needed since v0.3.0
# because Route.Handler is typed `Closure<WebContext, HttpResponse>`.
# Resolution order:
#   1. $AMALGAME_NET_HTTP env override (CI / explicit paths)
#   2. ~/.amalgame/packages/.../amalgame-net-http/<latest>/  (after `amc package add net-http`)
#   3. Sibling checkout — ../amalgame-net-http (local dev)
NETHTTP_DIR=""
if [ -n "$AMALGAME_NET_HTTP" ] && [ -d "$AMALGAME_NET_HTTP" ]; then
    NETHTTP_DIR="$AMALGAME_NET_HTTP"
elif [ -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-net-http" ]; then
    NETHTTP_DIR="$(ls -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-net-http"/*/ 2>/dev/null | head -1)"
    NETHTTP_DIR="${NETHTTP_DIR%/}"
elif [ -d "$PKG_DIR/../amalgame-net-http" ]; then
    NETHTTP_DIR="$PKG_DIR/../amalgame-net-http"
fi
if [ -z "$NETHTTP_DIR" ] || [ ! -f "$NETHTTP_DIR/facade.am" ]; then
    echo -e "${RED}error: amalgame-net-http not found${NC}"
    echo "  set AMALGAME_NET_HTTP=<path> or run \`amc package add net-http\`"
    exit 2
fi

# Build amalgame-web facade.o + amalgame-net-http facade.o once.
# net-http first (no deps), then web with --external pointing at it
# so SecurityHeaders.Apply(HttpResponse) can resolve the return type.
"$AMC" --lib -o "$BUILD_DIR/nethttp" "$NETHTTP_DIR/facade.am" 2>&1 | tail -2
gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$RUNTIME_DIR" -c "$BUILD_DIR/nethttp.c" -o "$BUILD_DIR/nethttp.o" 2>&1 | head -5
[ -s "$BUILD_DIR/nethttp.o" ] || { echo -e "${RED}nethttp build failed${NC}"; exit 1; }
"$AMC" --lib -o "$BUILD_DIR/facade" facade.am --external "$NETHTTP_DIR/facade.am" 2>&1 | tail -2
gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$RUNTIME_DIR" -c "$BUILD_DIR/facade.c" -o "$BUILD_DIR/facade.o" 2>&1 | head -5
[ -s "$BUILD_DIR/facade.o" ] || { echo -e "${RED}facade build failed${NC}"; exit 1; }

# Build + run one test file. --external order matters: net-http first
# so HttpResponse is registered before amalgame-web's facade references
# it as the typed Closure return type.
build_and_run() {
    local name="$1"
    local src="$2"
    echo -e "\n── ${name} ──"
    "$AMC" -o "$BUILD_DIR/$name" "$src" \
        --external "$NETHTTP_DIR/facade.am" --external facade.am 2>&1 | tail -2
    gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$RUNTIME_DIR" \
        "$BUILD_DIR/$name.c" "$BUILD_DIR/facade.o" "$BUILD_DIR/nethttp.o" \
        -lgc -lm -lz -o "$BUILD_DIR/$name" 2>&1 | head -5
    [ -x "$BUILD_DIR/$name" ] || { echo -e "${RED}${name} build failed${NC}"; exit 1; }
    "$BUILD_DIR/$name"
}

build_and_run router_test           tests/router_test.am
build_and_run security_headers_test tests/security_headers_test.am
build_and_run cors_test             tests/cors_test.am

echo -e "\n${GREEN}All tests completed${NC}"
