#!/bin/bash
# ─────────────────────────────────────────────────────────────────
#  tools/mosaic-build.sh — end-to-end build of a Mosaic app
#
#  Runs the full pipeline:
#    1. tools/mosaic-routes.sh app → _routes.am
#    2. amc <entry>.am _routes.am  → <name>.c
#    3. gcc with runtime headers + per-package libs → ./<name>
#
#  Picks up package libs from `amalgame.lock` (entries pointing at
#  the package cache under ~/.amalgame/packages/). Each package's
#  precompiled facade lives at:
#    <pkg-cache>/build/linux-x86_64/libamalgame-pkg-<MainClass>.a
#  System libs are pulled from each package's `amalgame.toml`
#  `libs = [...]` array.
#
#  Usage:
#    tools/mosaic-build.sh [--app <dir>] [--entry <file>] [-o <out>]
#
#  Defaults: --app app, --entry server.am, -o ./<entry-stem>
#
#  Env: AMC (path to amc), AMC_RUNTIME (path to runtime/ dir)
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

APP_DIR="app"
ENTRY="server.am"
OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --app)   APP_DIR="$2"; shift 2 ;;
        --entry) ENTRY="$2";   shift 2 ;;
        -o)      OUT="$2";     shift 2 ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -z "$OUT" ] && OUT="./$(basename "${ENTRY%.am}")"

# ── Resolve amc + runtime ────────────────────────────────────────

AMC="${AMC:-}"
if [ -z "$AMC" ]; then
    if command -v amc >/dev/null 2>&1; then AMC="$(command -v amc)"
    elif [ -x "$HOME/.local/bin/amc" ];   then AMC="$HOME/.local/bin/amc"
    elif [ -x "$HOME/.amalgame/bin/amc" ]; then AMC="$HOME/.amalgame/bin/amc"
    else echo "error: amc not found" >&2; exit 1; fi
fi

AMC_RUNTIME="${AMC_RUNTIME:-}"
if [ -z "$AMC_RUNTIME" ]; then
    # Probe in order: ~/.local install → /usr/local install → sibling
    # Amalgame checkout (for developer setups).
    for cand in \
        "$HOME/.local/share/amalgame/runtime" \
        "/usr/local/share/amalgame/runtime" \
        "$(dirname "$AMC")/../share/amalgame/runtime" \
        "$(dirname "$(dirname "$AMC")")/../Amalgame/runtime"; do
        if [ -d "$cand" ]; then AMC_RUNTIME="$cand"; break; fi
    done
fi
[ -z "$AMC_RUNTIME" ] && { echo "error: AMC_RUNTIME not found"; exit 1; }

LIBAMALGAME=""
for cand in \
    "$HOME/.local/share/amalgame/lib/libamalgame.a" \
    "/usr/local/share/amalgame/lib/libamalgame.a" \
    "$(dirname "$AMC")/../share/amalgame/lib/libamalgame.a"; do
    if [ -f "$cand" ]; then LIBAMALGAME="$cand"; break; fi
done
[ -z "$LIBAMALGAME" ] && { echo "error: libamalgame.a not found"; exit 1; }

echo "→ amc          $AMC"
echo "→ amc runtime  $AMC_RUNTIME"
echo "→ libamalgame  $LIBAMALGAME"

# ── Step 1: regenerate _routes.am ───────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/mosaic-routes.sh" "$APP_DIR" _routes.am

# ── Step 2: amc → server.c ───────────────────────────────────────

NAME="$(basename "${ENTRY%.am}")"
"$AMC" "$ENTRY" _routes.am -o "$NAME" 2>&1 | tail -8

if [ ! -f "$NAME.c" ]; then
    echo "error: amc didn't generate $NAME.c" >&2
    exit 1
fi

# ── Step 3: pick up per-package facades + system libs ───────────

PKG_ARCHIVES=()
SYS_LIBS=()

if [ -f amalgame.lock ]; then
    # Parse [[package]] entries with awk — one block per entry, all
    # four fields on one record (`|`-separated) for easy bash split.
    while IFS='|' read -r name git tag rev; do
        [ -z "${name:-}" ] && continue
        PKG_CACHE="$HOME/.amalgame/packages/$git/${tag}_${rev}"
        if [ ! -d "$PKG_CACHE" ]; then
            echo "warn: pkg cache missing for $name: $PKG_CACHE" >&2
            continue
        fi
        # First class name from amalgame.toml drives the archive name.
        CLS=$(awk '/^classes/,/]/' "$PKG_CACHE/amalgame.toml" \
              | grep -oE '"[A-Z][A-Za-z0-9_]+"' | head -1 | tr -d '"' || true)
        if [ -z "$CLS" ]; then
            echo "warn: no class found in $PKG_CACHE/amalgame.toml — skipping" >&2
            continue
        fi
        ARCHIVE="$PKG_CACHE/build/linux-x86_64/libamalgame-pkg-${CLS}.a"
        if [ ! -f "$ARCHIVE" ]; then
            echo "→ precompiling facade for $name ($CLS)"
            mkdir -p "$PKG_CACHE/build/linux-x86_64"
            (cd "$PKG_CACHE" && \
             "$AMC" --lib --quiet -o "build/linux-x86_64/${CLS}-facade" facade.am >/dev/null && \
             gcc -O2 -Iruntime -I"$AMC_RUNTIME" -c "build/linux-x86_64/${CLS}-facade.c" \
                 -o "build/linux-x86_64/${CLS}-facade.o" && \
             ar rcs "build/linux-x86_64/libamalgame-pkg-${CLS}.a" \
                    "build/linux-x86_64/${CLS}-facade.o")
        fi
        PKG_ARCHIVES+=("$ARCHIVE")
        # System libs from `libs = [...]` array.
        while IFS= read -r lib; do
            [ -n "$lib" ] && SYS_LIBS+=("-l$lib")
        done < <(awk '/^libs[[:space:]]*=/,/]/' "$PKG_CACHE/amalgame.toml" \
                 | grep -oE '"[a-z0-9_+-]+"' | tr -d '"' || true)
    done < <(awk '
        BEGIN { name=""; git=""; tag=""; rev=""; in_pkg=0 }
        /^\[\[package\]\]/ {
            if (in_pkg && name!="") print name "|" git "|" tag "|" rev
            in_pkg=1; name=""; git=""; tag=""; rev=""; next
        }
        /^\[\[/ {
            if (in_pkg && name!="") print name "|" git "|" tag "|" rev
            in_pkg=0; next
        }
        in_pkg && /^[[:space:]]*name[[:space:]]*=/ { match($0, /"[^"]*"/); name=substr($0,RSTART+1,RLENGTH-2) }
        in_pkg && /^[[:space:]]*git[[:space:]]*=/  { match($0, /"[^"]*"/); git=substr($0,RSTART+1,RLENGTH-2) }
        in_pkg && /^[[:space:]]*tag[[:space:]]*=/  { match($0, /"[^"]*"/); tag=substr($0,RSTART+1,RLENGTH-2) }
        in_pkg && /^[[:space:]]*rev[[:space:]]*=/  { match($0, /"[^"]*"/); rev=substr($0,RSTART+1,RLENGTH-2) }
        END { if (in_pkg && name!="") print name "|" git "|" tag "|" rev }
    ' amalgame.lock)
fi

# ── Step 4: gcc link ─────────────────────────────────────────────

GCC_CMD=(gcc -O2 -I"$AMC_RUNTIME" "$NAME.c"
         "${PKG_ARCHIVES[@]}" "$LIBAMALGAME"
         -lgc -lm -lz "${SYS_LIBS[@]}"
         -o "$OUT")

echo "→ link: ${GCC_CMD[*]}"
"${GCC_CMD[@]}"

echo "✓ built $OUT"
