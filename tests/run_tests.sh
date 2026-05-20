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

# Locate amalgame-datetime (used by RateLimit since v0.6.0). Same
# resolution order as net-http.
DATETIME_DIR=""
if [ -n "$AMALGAME_DATETIME" ] && [ -d "$AMALGAME_DATETIME" ]; then
    DATETIME_DIR="$AMALGAME_DATETIME"
elif [ -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-datetime" ]; then
    DATETIME_DIR="$(ls -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-datetime"/*/ 2>/dev/null | head -1)"
    DATETIME_DIR="${DATETIME_DIR%/}"
elif [ -d "$PKG_DIR/../amalgame-datetime" ]; then
    DATETIME_DIR="$PKG_DIR/../amalgame-datetime"
fi
if [ -z "$DATETIME_DIR" ] || [ ! -f "$DATETIME_DIR/facade.am" ]; then
    echo -e "${RED}error: amalgame-datetime not found${NC}"
    echo "  set AMALGAME_DATETIME=<path> or run \`amc package add datetime\`"
    exit 2
fi

# Locate amalgame-random (used by Csrf since v0.7.0). Same chain.
RANDOM_DIR=""
if [ -n "$AMALGAME_RANDOM" ] && [ -d "$AMALGAME_RANDOM" ]; then
    RANDOM_DIR="$AMALGAME_RANDOM"
elif [ -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-random" ]; then
    RANDOM_DIR="$(ls -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-random"/*/ 2>/dev/null | head -1)"
    RANDOM_DIR="${RANDOM_DIR%/}"
elif [ -d "$PKG_DIR/../amalgame-random" ]; then
    RANDOM_DIR="$PKG_DIR/../amalgame-random"
fi
if [ -z "$RANDOM_DIR" ] || [ ! -f "$RANDOM_DIR/facade.am" ]; then
    echo -e "${RED}error: amalgame-random not found${NC}"
    echo "  set AMALGAME_RANDOM=<path> or run \`amc package add random\`"
    exit 2
fi

# Build sibling facade .o files once, then amalgame-web's own.
# Order matters: net-http and datetime have no inter-dep; web
# depends on both. --external on the web build wires the types
# (HttpResponse from net-http, DateTime from datetime).
"$AMC" --lib -o "$BUILD_DIR/nethttp" "$NETHTTP_DIR/facade.am" 2>&1 | tail -2
gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$DATETIME_DIR" -I"$RUNTIME_DIR" -c "$BUILD_DIR/nethttp.c" -o "$BUILD_DIR/nethttp.o" 2>&1 | head -5
[ -s "$BUILD_DIR/nethttp.o" ] || { echo -e "${RED}nethttp build failed${NC}"; exit 1; }
"$AMC" --lib -o "$BUILD_DIR/datetime" "$DATETIME_DIR/facade.am" 2>&1 | tail -2
gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$DATETIME_DIR" -I"$RANDOM_DIR" -I"$RUNTIME_DIR" -c "$BUILD_DIR/datetime.c" -o "$BUILD_DIR/datetime.o" 2>&1 | head -5
[ -s "$BUILD_DIR/datetime.o" ] || { echo -e "${RED}datetime build failed${NC}"; exit 1; }
"$AMC" --lib -o "$BUILD_DIR/random" "$RANDOM_DIR/facade.am" 2>&1 | tail -2
gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$DATETIME_DIR" -I"$RANDOM_DIR" -I"$RUNTIME_DIR" -c "$BUILD_DIR/random.c" -o "$BUILD_DIR/random.o" 2>&1 | head -5
[ -s "$BUILD_DIR/random.o" ] || { echo -e "${RED}random build failed${NC}"; exit 1; }
# v0.7.x: amalgame-web is split across multiple .am files
# (facade.am + sources from amalgame.toml). The compiler treats
# them all as the same package; we just have to pass each one to
# both the lib build and the test --external chain.
WEB_SOURCES="facade.am session.am web_context.am security_headers.am cors.am rate_limit.am csrf.am web_app.am"
WEB_EXTERNAL_FLAGS=""
for src in $WEB_SOURCES; do
    WEB_EXTERNAL_FLAGS="$WEB_EXTERNAL_FLAGS --external $src"
done

"$AMC" --lib -o "$BUILD_DIR/facade" $WEB_SOURCES \
    --external "$NETHTTP_DIR/facade.am" \
    --external "$DATETIME_DIR/facade.am" \
    --external "$RANDOM_DIR/facade.am" 2>&1 | tail -2
gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$DATETIME_DIR" -I"$RANDOM_DIR" -I"$RUNTIME_DIR" -c "$BUILD_DIR/facade.c" -o "$BUILD_DIR/facade.o" 2>&1 | head -5
[ -s "$BUILD_DIR/facade.o" ] || { echo -e "${RED}facade build failed${NC}"; exit 1; }

# Build + run one test file. --external order matters: net-http first
# so HttpResponse is registered before amalgame-web's facade references
# it as the typed Closure return type. amalgame-web's own files come
# last so cross-file refs (e.g. WebContext.Session → session.am) resolve.
build_and_run() {
    local name="$1"
    local src="$2"
    echo -e "\n── ${name} ──"
    "$AMC" -o "$BUILD_DIR/$name" "$src" \
        --external "$NETHTTP_DIR/facade.am" \
        --external "$DATETIME_DIR/facade.am" \
        --external "$RANDOM_DIR/facade.am" \
        $WEB_EXTERNAL_FLAGS 2>&1 | tail -2
    gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$DATETIME_DIR" -I"$RANDOM_DIR" -I"$RUNTIME_DIR" \
        "$BUILD_DIR/$name.c" "$BUILD_DIR/facade.o" "$BUILD_DIR/nethttp.o" "$BUILD_DIR/datetime.o" "$BUILD_DIR/random.o" \
        -lgc -lm -lz -o "$BUILD_DIR/$name" 2>&1 | head -5
    [ -x "$BUILD_DIR/$name" ] || { echo -e "${RED}${name} build failed${NC}"; exit 1; }
    "$BUILD_DIR/$name"
}

build_and_run router_test           tests/router_test.am
build_and_run security_headers_test tests/security_headers_test.am
build_and_run cors_test             tests/cors_test.am
build_and_run rate_limit_test       tests/rate_limit_test.am
build_and_run csrf_test             tests/csrf_test.am
build_and_run web_app_test          tests/web_app_test.am

echo -e "\n${GREEN}All tests completed${NC}"
