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

# v0.17.0: amalgame-net-http v0.11+ #include's Amalgame_Tls.h for
# the HttpClient HTTPS path. Same sibling-first lookup.
TLS_DIR=""
if [ -n "$AMALGAME_TLS" ] && [ -d "$AMALGAME_TLS" ]; then
    TLS_DIR="$AMALGAME_TLS"
elif [ -d "$PKG_DIR/../amalgame-tls" ]; then
    TLS_DIR="$PKG_DIR/../amalgame-tls"
elif compgen -G "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-tls/*/runtime" > /dev/null 2>&1; then
    TLS_DIR="$(ls -d $HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-tls/*/ 2>/dev/null | head -1)"
    TLS_DIR="${TLS_DIR%/}"
fi
if [ -z "$TLS_DIR" ] || [ ! -d "$TLS_DIR/runtime" ]; then
    echo -e "${RED}error: amalgame-tls not found${NC}"
    echo "  set AMALGAME_TLS=<path> or run \`amc package add tls\`"
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

# v0.12.0: amalgame-async runtime (ucontext + epoll fibers).
# Required since amalgame-net-http v0.9.1+'s Amalgame_Net_Http.h
# #includes Amalgame_Async.h unconditionally. C-only package
# (no facade.am), wired via the same fake-cache pattern.
ASYNC_DIR=""
if [ -n "$AMALGAME_ASYNC" ] && [ -d "$AMALGAME_ASYNC" ]; then
    ASYNC_DIR="$AMALGAME_ASYNC"
elif [ -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-async" ]; then
    ASYNC_DIR="$(ls -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-async"/*/ 2>/dev/null | head -1)"
    ASYNC_DIR="${ASYNC_DIR%/}"
elif [ -d "$PKG_DIR/../amalgame-async" ]; then
    ASYNC_DIR="$PKG_DIR/../amalgame-async"
fi
if [ -z "$ASYNC_DIR" ] || [ ! -f "$ASYNC_DIR/amalgame.toml" ]; then
    echo -e "${RED}error: amalgame-async not found${NC}"
    echo "  set AMALGAME_ASYNC=<path> or run \`amc package add async\`"
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

# v0.11.0: net-http also in the cache + lock so PkgRegistry knows
# Http1.Serve/ServeMt/H1Conn etc. — WebApp.Serve calls them
# directly. Requires amc >= 0.8.38 (PkgClasses lookup in cgen).
NETHTTP_PKG_GIT="github.com/amalgame-lang/amalgame-net-http"
NETHTTP_PKG_TAG="v0.7.0"
NETHTTP_FAKE_SHA="abcdef0123456789000000000000000000000ef"
NETHTTP_SHORT_SHA="${NETHTTP_FAKE_SHA:0:8}"
NETHTTP_CACHE_DIR="$SHARED_FAKE_CACHE/$NETHTTP_PKG_GIT/${NETHTTP_PKG_TAG}_${NETHTTP_SHORT_SHA}"
mkdir -p "$(dirname "$NETHTTP_CACHE_DIR")"
rm -rf "$NETHTTP_CACHE_DIR"
ln -s "$NETHTTP_DIR" "$NETHTTP_CACHE_DIR"

ASYNC_PKG_GIT="github.com/amalgame-lang/amalgame-async"
ASYNC_PKG_TAG="v0.2.0"
ASYNC_FAKE_SHA="fedcba9876543210000000000000000000000ff"
ASYNC_SHORT_SHA="${ASYNC_FAKE_SHA:0:8}"
ASYNC_CACHE_DIR="$SHARED_FAKE_CACHE/$ASYNC_PKG_GIT/${ASYNC_PKG_TAG}_${ASYNC_SHORT_SHA}"
mkdir -p "$(dirname "$ASYNC_CACHE_DIR")"
rm -rf "$ASYNC_CACHE_DIR"
ln -s "$ASYNC_DIR" "$ASYNC_CACHE_DIR"

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

[[package]]
name = "amalgame-net-http"
git  = "$NETHTTP_PKG_GIT"
tag  = "$NETHTTP_PKG_TAG"
rev  = "$NETHTTP_FAKE_SHA"

[[package]]
name = "amalgame-async"
git  = "$ASYNC_PKG_GIT"
tag  = "$ASYNC_PKG_TAG"
rev  = "$ASYNC_FAKE_SHA"
EOF

# Build sibling facade .o files once, then amalgame-web's own.
# Order matters: net-http and datetime have no inter-dep; web
# depends on both. --external on the web build wires the types
# (HttpResponse from net-http, DateTime from datetime).
# v0.11.0: build net-http with ALL its sources (not just facade.am)
# so the AM-side class bodies (HttpResponse.New(), Cookie methods,
# HttpParser.*, etc.) are emitted into nethttp.o. The amalgame-web
# facade build references these symbols; without their bodies in
# the .o, the final link of each test binary fails. Pre-split
# net-http (v0.4.5 and earlier) had everything in facade.am; since
# v0.4.6 the user (or test runner) has to enumerate.
NETHTTP_SOURCES="$NETHTTP_DIR/facade.am $NETHTTP_DIR/cookie.am $NETHTTP_DIR/http_request.am $NETHTTP_DIR/http_response.am $NETHTTP_DIR/http_parser.am $NETHTTP_DIR/http_server.am $NETHTTP_DIR/http_client.am"
"$AMC" --lib -o "$BUILD_DIR/nethttp" $NETHTTP_SOURCES 2>&1 | tail -30
gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$TLS_DIR/runtime" -I"$ASYNC_DIR/runtime" -I"$DATETIME_DIR" -I"$RUNTIME_DIR" -c "$BUILD_DIR/nethttp.c" -o "$BUILD_DIR/nethttp.o" 2>"$BUILD_DIR/gcc-last.log" || true
head -30 "$BUILD_DIR/gcc-last.log"
[ -s "$BUILD_DIR/nethttp.o" ] || { echo -e "${RED}nethttp build failed${NC}"; cat "$BUILD_DIR/gcc-last.log"; exit 1; }
"$AMC" --lib -o "$BUILD_DIR/datetime" "$DATETIME_DIR/facade.am" 2>&1 | tail -30
gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$TLS_DIR/runtime" -I"$ASYNC_DIR/runtime" -I"$DATETIME_DIR" -I"$RANDOM_DIR" -I"$RUNTIME_DIR" -c "$BUILD_DIR/datetime.c" -o "$BUILD_DIR/datetime.o" 2>"$BUILD_DIR/gcc-last.log"; head -5 "$BUILD_DIR/gcc-last.log"
[ -s "$BUILD_DIR/datetime.o" ] || { echo -e "${RED}datetime build failed${NC}"; exit 1; }
"$AMC" --lib -o "$BUILD_DIR/random" "$RANDOM_DIR/facade.am" 2>&1 | tail -30
gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$TLS_DIR/runtime" -I"$ASYNC_DIR/runtime" -I"$DATETIME_DIR" -I"$RANDOM_DIR" -I"$LOGGING_DIR" -I"$RUNTIME_DIR" -c "$BUILD_DIR/random.c" -o "$BUILD_DIR/random.o" 2>"$BUILD_DIR/gcc-last.log"; head -5 "$BUILD_DIR/gcc-last.log"
[ -s "$BUILD_DIR/random.o" ] || { echo -e "${RED}random build failed${NC}"; exit 1; }
"$AMC" --lib -o "$BUILD_DIR/logging" "$LOGGING_DIR/facade.am" 2>&1 | tail -30
gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$TLS_DIR/runtime" -I"$ASYNC_DIR/runtime" -I"$DATETIME_DIR" -I"$RANDOM_DIR" -I"$LOGGING_DIR" -I"$CRYPTO_DIR" -I"$RUNTIME_DIR" -c "$BUILD_DIR/logging.c" -o "$BUILD_DIR/logging.o" 2>"$BUILD_DIR/gcc-last.log"; head -5 "$BUILD_DIR/gcc-last.log"
[ -s "$BUILD_DIR/logging.o" ] || { echo -e "${RED}logging build failed${NC}"; exit 1; }
"$AMC" --lib -o "$BUILD_DIR/crypto" "$CRYPTO_DIR/facade.am" 2>&1 | tail -30
gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$TLS_DIR/runtime" -I"$ASYNC_DIR/runtime" -I"$DATETIME_DIR" -I"$RANDOM_DIR" -I"$LOGGING_DIR" -I"$CRYPTO_DIR" -I"$RUNTIME_DIR" -c "$BUILD_DIR/crypto.c" -o "$BUILD_DIR/crypto.o" 2>"$BUILD_DIR/gcc-last.log"; head -5 "$BUILD_DIR/gcc-last.log"
[ -s "$BUILD_DIR/crypto.o" ] || { echo -e "${RED}crypto build failed${NC}"; exit 1; }
# v0.7.x: amalgame-web is split across multiple .am files
# (facade.am + sources from amalgame.toml). The compiler treats
# them all as the same package; we just have to pass each one to
# both the lib build and the test --external chain.
WEB_SOURCES="facade.am session.am web_context.am security_headers.am cors.am rate_limit.am csrf.am log_config.am signed_cookie_session.am redis_session.am acme_config.am tls_binding_config.am basic_auth.am jwt_auth.am oauth2.am static.am powered_by.am web_app.am mosaic_server.am"
WEB_EXTERNAL_FLAGS=""
for src in $WEB_SOURCES; do
    WEB_EXTERNAL_FLAGS="$WEB_EXTERNAL_FLAGS --external $src"
done
# v0.11.0: net-http is also split (cookie.am / http_request.am / etc.
# since v0.4.6). The consumer needs ALL of them on --external so amc
# emits the forward decls + bodies for HttpResponse.New(), Cookie_new,
# HttpRequest.FromH1Conn etc. — they're referenced from WebApp.Serve
# closures. amc >= 0.8.38's PkgClasses lookup handles the typedef
# struct for each (BeginMulti emits them once at the top), but the
# AM-method bodies still need --external to be picked up by the cgen.
# v0.11.3 (amc >= 0.8.39): net-http is auto-attached via the
# PkgRegistry lock + cache wired above ($SHARED_FAKE_CACHE).  Its
# facade + [stdlib].sources land on ExternalFiles automatically.
# Listing them manually here too causes a double-attach + gcc
# `struct redefinition` errors. Keep empty.
NETHTTP_EXTERNAL_FLAGS=""

"$AMC" --lib -o "$BUILD_DIR/facade" $WEB_SOURCES \
    $NETHTTP_EXTERNAL_FLAGS \
    --external "$DATETIME_DIR/facade.am" \
    --external "$RANDOM_DIR/facade.am" \
    --external "$LOGGING_DIR/facade.am" \
    --external "$CRYPTO_DIR/facade.am" 2>&1 | tail -30
gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$TLS_DIR/runtime" -I"$ASYNC_DIR/runtime" -I"$DATETIME_DIR" -I"$RANDOM_DIR" -I"$LOGGING_DIR" -I"$CRYPTO_DIR" -I"$REDIS_DIR/runtime" -I"$RUNTIME_DIR" -c "$BUILD_DIR/facade.c" -o "$BUILD_DIR/facade.o" 2>"$BUILD_DIR/gcc-last.log"; head -5 "$BUILD_DIR/gcc-last.log"
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
        $NETHTTP_EXTERNAL_FLAGS \
        --external "$DATETIME_DIR/facade.am" \
        --external "$RANDOM_DIR/facade.am" \
        --external "$LOGGING_DIR/facade.am" \
        --external "$CRYPTO_DIR/facade.am" \
        $WEB_EXTERNAL_FLAGS 2>&1 | tail -30
    gcc -O2 -Iruntime -I"$NETHTTP_DIR/runtime" -I"$TLS_DIR/runtime" -I"$ASYNC_DIR/runtime" -I"$DATETIME_DIR" -I"$RANDOM_DIR" -I"$LOGGING_DIR" -I"$CRYPTO_DIR" -I"$REDIS_DIR/runtime" -I"$THREADING_DIR/runtime" -I"$RUNTIME_DIR" \
        -include "$THREADING_DIR/runtime/Amalgame_Threading.h" \
        -include "$REDIS_DIR/runtime/Amalgame_Database_Redis.h" \
        "$BUILD_DIR/$name.c" "$BUILD_DIR/facade.o" "$BUILD_DIR/nethttp.o" "$BUILD_DIR/datetime.o" "$BUILD_DIR/random.o" "$BUILD_DIR/logging.o" "$BUILD_DIR/crypto.o" \
        -lgc -lm -lz -lssl -lcrypto -lpthread -o "$BUILD_DIR/$name" 2>"$BUILD_DIR/gcc-last.log" || true
    head -10 "$BUILD_DIR/gcc-last.log"
    [ -x "$BUILD_DIR/$name" ] || { echo -e "${RED}${name} build failed${NC}"; exit 1; }
    "$BUILD_DIR/$name"
}

build_and_run router_test                tests/router_test.am
build_and_run security_headers_test      tests/security_headers_test.am
build_and_run cors_test                  tests/cors_test.am
build_and_run rate_limit_test            tests/rate_limit_test.am
build_and_run csrf_test                  tests/csrf_test.am
build_and_run web_app_test               tests/web_app_test.am
build_and_run oauth2_test                tests/oauth2_test.am
build_and_run mosaic_server_test         tests/mosaic_server_test.am
build_and_run signed_cookie_session_test tests/signed_cookie_session_test.am
build_and_run redis_session_test         tests/redis_session_test.am
build_and_run acme_config_test           tests/acme_config_test.am
build_and_run tls_binding_config_test    tests/tls_binding_config_test.am
build_and_run static_test                tests/static_test.am
build_and_run powered_by_test            tests/powered_by_test.am
build_and_run webapp_serve_smoke_test    tests/webapp_serve_smoke_test.am

echo -e "\n${GREEN}All tests completed${NC}"
