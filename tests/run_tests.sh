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

## Locate amalgame-random (used by Csrf since v0.7.0). Same chain.
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

# Locate amalgame-logging (used by LogConfig + WebApp.WithLogging since v0.8.2).
LOGGING_DIR=""
if [ -n "$AMALGAME_LOGGING" ] && [ -d "$AMALGAME_LOGGING" ]; then
    LOGGING_DIR="$AMALGAME_LOGGING"
elif [ -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-logging" ]; then
    LOGGING_DIR="$(ls -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-logging"/*/ 2>/dev/null | head -1)"
    LOGGING_DIR="${LOGGING_DIR%/}"
elif [ -d "$PKG_DIR/../amalgame-logging" ]; then
    LOGGING_DIR="$PKG_DIR/../amalgame-logging"
fi
if [ -z "$LOGGING_DIR" ] || [ ! -f "$LOGGING_DIR/facade.am" ]; then
    echo -e "${RED}error: amalgame-logging not found${NC}"
    echo "  set AMALGAME_LOGGING=<path> or run \`amc package add logging\`"
    exit 2
fi

# Locate amalgame-crypto (used by SignedCookieSessionStore since v0.8.3).
# Pure-AM facade with embedded @c{} blocks for SHA-256 + HMAC core —
# same --external chaining as amalgame-datetime / amalgame-random.
CRYPTO_DIR=""
if [ -n "$AMALGAME_CRYPTO" ] && [ -d "$AMALGAME_CRYPTO" ]; then
    CRYPTO_DIR="$AMALGAME_CRYPTO"
elif [ -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-crypto" ]; then
    CRYPTO_DIR="$(ls -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-crypto"/*/ 2>/dev/null | head -1)"
    CRYPTO_DIR="${CRYPTO_DIR%/}"
elif [ -d "$PKG_DIR/../amalgame-crypto" ]; then
    CRYPTO_DIR="$PKG_DIR/../amalgame-crypto"
fi
if [ -z "$CRYPTO_DIR" ] || [ ! -f "$CRYPTO_DIR/facade.am" ]; then
    echo -e "${RED}error: amalgame-crypto not found${NC}"
    echo "  set AMALGAME_CRYPTO=<path> or run \`amc package add crypto\`"
    exit 2
fi

# Locate amalgame-database-nosql-redis (used by RedisSessionStore since
# v0.8.4). Unlike crypto/datetime/random/logging this is a C-only
# package — no facade.am — so we wire it via the fake-cache pattern
# (AMALGAME_PACKAGES_DIR + amalgame.lock) that the redis package's own
# tests use. Resolution chain mirrors the others.
REDIS_DIR=""
if [ -n "$AMALGAME_DB_REDIS" ] && [ -d "$AMALGAME_DB_REDIS" ]; then
    REDIS_DIR="$AMALGAME_DB_REDIS"
elif [ -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-database-nosql-redis" ]; then
    REDIS_DIR="$(ls -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-database-nosql-redis"/*/ 2>/dev/null | head -1)"
    REDIS_DIR="${REDIS_DIR%/}"
elif [ -d "$PKG_DIR/../amalgame-database-nosql-redis" ]; then
    REDIS_DIR="$PKG_DIR/../amalgame-database-nosql-redis"
fi
if [ -z "$REDIS_DIR" ] || [ ! -f "$REDIS_DIR/amalgame.toml" ]; then
    echo -e "${RED}error: amalgame-database-nosql-redis not found${NC}"
    echo "  set AMALGAME_DB_REDIS=<path> or run \`amc package add database-nosql-redis\`"
    exit 2
fi

# Stage a fake AMALGAME_PACKAGES_DIR cache pointing at REDIS_DIR.
# This is the same dance the redis package's own tests use — needed
# because the package is C-only (no .am facade to --external) and
# amc resolves `import Amalgame.Database.NoSQL.Redis` via the package
# cache lookup.
# Locate amalgame-threading (used by v0.9.2 per-instance mutex in
# MemorySessionStore + RateLimit). Same C-only fake-cache pattern.
THREADING_DIR=""
if [ -n "$AMALGAME_THREADING" ] && [ -d "$AMALGAME_THREADING" ]; then
    THREADING_DIR="$AMALGAME_THREADING"
elif [ -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-threading" ]; then
    THREADING_DIR="$(ls -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-threading"/*/ 2>/dev/null | head -1)"
    THREADING_DIR="${THREADING_DIR%/}"
elif [ -d "$PKG_DIR/../amalgame-threading" ]; then
    THREADING_DIR="$PKG_DIR/../amalgame-threading"
fi
if [ -z "$THREADING_DIR" ] || [ ! -f "$THREADING_DIR/amalgame.toml" ]; then
    echo -e "${RED}error: amalgame-threading not found${NC}"
    echo "  set AMALGAME_THREADING=<path> or run \`amc package add threading\`"
    exit 2
fi

# Shared fake AMALGAME_PACKAGES_DIR cache for both C-only deps.
SHARED_FAKE_CACHE="$BUILD_DIR/pkg_cache"
REDIS_PKG_GIT="github.com/amalgame-lang/amalgame-database-nosql-redis"
REDIS_PKG_TAG="v0.3.0"
REDIS_FAKE_SHA="deadbeefcafebabe0000000000000000000000ab"
REDIS_SHORT_SHA="${REDIS_FAKE_SHA:0:8}"
REDIS_CACHE_DIR="$SHARED_FAKE_CACHE/$REDIS_PKG_GIT/${REDIS_PKG_TAG}_${REDIS_SHORT_SHA}"
mkdir -p "$(dirname "$REDIS_CACHE_DIR")"
rm -rf "$REDIS_CACHE_DIR"
ln -s "$REDIS_DIR" "$REDIS_CACHE_DIR"

THREADING_PKG_GIT="github.com/amalgame-lang/amalgame-threading"
THREADING_PKG_TAG="v0.1.0"
THREADING_FAKE_SHA="cafebabedeadbeef0000000000000000000000cd"
THREADING_SHORT_SHA="${THREADING_FAKE_SHA:0:8}"
THREADING_CACHE_DIR="$SHARED_FAKE_CACHE/$THREADING_PKG_GIT/${THREADING_PKG_TAG}_${THREADING_SHORT_SHA}"
mkdir -p "$(dirname "$THREADING_CACHE_DIR")"
rm -rf "$THREADING_CACHE_DIR"
ln -s "$THREADING_DIR" "$THREADING_CACHE_DIR"

export AMALGAME_PACKAGES_DIR="$SHARED_FAKE_CACHE"

# Write a transient amalgame.lock in $PKG_DIR so amc's
# PackageRegistry.Load() picks up the redis package. The
# package is C-only — no facade.am — so we can't wire it via
# --external like the AM-facade siblings. Restore any
# pre-existing lock via the EXIT trap.
EXISTING_LOCK_BACKUP=""
if [ -f "$PKG_DIR/amalgame.lock" ]; then
    EXISTING_LOCK_BACKUP="$BUILD_DIR/amalgame.lock.bak"
    cp "$PKG_DIR/amalgame.lock" "$EXISTING_LOCK_BACKUP"
fi
trap '
    rm -rf "$BUILD_DIR"
    if [ -n "$EXISTING_LOCK_BACKUP" ] && [ -f "$EXISTING_LOCK_BACKUP" ]; then
        mv "$EXISTING_LOCK_BACKUP" "$PKG_DIR/amalgame.lock"
    else
        rm -f "$PKG_DIR/amalgame.lock"
    fi
' EXIT

cat > "$PKG_DIR/amalgame.lock" <<EOF
[[package]]
name = "amalgame-database-nosql-redis"
git  = "$REDIS_PKG_GIT"
tag  = "$REDIS_PKG_TAG"
rev  = "$REDIS_FAKE_SHA"

[[package]]
name = "amalgame-threading"
git  = "$THREADING_PKG_GIT"
tag  = "$THREADING_PKG_TAG"
rev  = "$THREADING_FAKE_SHA"
EOF

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
gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$DATETIME_DIR" -I"$RANDOM_DIR" -I"$LOGGING_DIR" -I"$RUNTIME_DIR" -c "$BUILD_DIR/random.c" -o "$BUILD_DIR/random.o" 2>&1 | head -5
[ -s "$BUILD_DIR/random.o" ] || { echo -e "${RED}random build failed${NC}"; exit 1; }
"$AMC" --lib -o "$BUILD_DIR/logging" "$LOGGING_DIR/facade.am" 2>&1 | tail -2
gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$DATETIME_DIR" -I"$RANDOM_DIR" -I"$LOGGING_DIR" -I"$CRYPTO_DIR" -I"$RUNTIME_DIR" -c "$BUILD_DIR/logging.c" -o "$BUILD_DIR/logging.o" 2>&1 | head -5
[ -s "$BUILD_DIR/logging.o" ] || { echo -e "${RED}logging build failed${NC}"; exit 1; }
"$AMC" --lib -o "$BUILD_DIR/crypto" "$CRYPTO_DIR/facade.am" 2>&1 | tail -2
gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$DATETIME_DIR" -I"$RANDOM_DIR" -I"$LOGGING_DIR" -I"$CRYPTO_DIR" -I"$RUNTIME_DIR" -c "$BUILD_DIR/crypto.c" -o "$BUILD_DIR/crypto.o" 2>&1 | head -5
[ -s "$BUILD_DIR/crypto.o" ] || { echo -e "${RED}crypto build failed${NC}"; exit 1; }
# v0.7.x: amalgame-web is split across multiple .am files
# (facade.am + sources from amalgame.toml). The compiler treats
# them all as the same package; we just have to pass each one to
# both the lib build and the test --external chain.
WEB_SOURCES="facade.am session.am web_context.am security_headers.am cors.am rate_limit.am csrf.am log_config.am signed_cookie_session.am redis_session.am web_app.am"
WEB_EXTERNAL_FLAGS=""
for src in $WEB_SOURCES; do
    WEB_EXTERNAL_FLAGS="$WEB_EXTERNAL_FLAGS --external $src"
done

"$AMC" --lib -o "$BUILD_DIR/facade" $WEB_SOURCES \
    --external "$NETHTTP_DIR/facade.am" \
    --external "$DATETIME_DIR/facade.am" \
    --external "$RANDOM_DIR/facade.am" \
    --external "$LOGGING_DIR/facade.am" \
    --external "$CRYPTO_DIR/facade.am" 2>&1 | tail -2
gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$DATETIME_DIR" -I"$RANDOM_DIR" -I"$LOGGING_DIR" -I"$CRYPTO_DIR" -I"$REDIS_DIR/runtime" -I"$RUNTIME_DIR" -c "$BUILD_DIR/facade.c" -o "$BUILD_DIR/facade.o" 2>&1 | head -5
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
        --external "$LOGGING_DIR/facade.am" \
        --external "$CRYPTO_DIR/facade.am" \
        $WEB_EXTERNAL_FLAGS 2>&1 | tail -2
    gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$DATETIME_DIR" -I"$RANDOM_DIR" -I"$LOGGING_DIR" -I"$CRYPTO_DIR" -I"$REDIS_DIR/runtime" -I"$RUNTIME_DIR" \
        "$BUILD_DIR/$name.c" "$BUILD_DIR/facade.o" "$BUILD_DIR/nethttp.o" "$BUILD_DIR/datetime.o" "$BUILD_DIR/random.o" "$BUILD_DIR/logging.o" "$BUILD_DIR/crypto.o" \
        -lgc -lm -lz -lcrypto -lpthread -o "$BUILD_DIR/$name" 2>&1 | head -5
    [ -x "$BUILD_DIR/$name" ] || { echo -e "${RED}${name} build failed${NC}"; exit 1; }
    "$BUILD_DIR/$name"
}

build_and_run router_test                tests/router_test.am
build_and_run security_headers_test      tests/security_headers_test.am
build_and_run cors_test                  tests/cors_test.am
build_and_run rate_limit_test            tests/rate_limit_test.am
build_and_run csrf_test                  tests/csrf_test.am
build_and_run web_app_test               tests/web_app_test.am
build_and_run signed_cookie_session_test tests/signed_cookie_session_test.am
build_and_run redis_session_test         tests/redis_session_test.am

echo -e "\n${GREEN}All tests completed${NC}"
