#!/bin/sh
# Check the modules build-engine-fixes.sh installed into an engine, then pack them for release:
#   scripts/package-engine-fixes.sh WINE_ROOT OUTDIR [SOURCE_REF]
# WINE_ROOT is the engine's Wine folder (…/Libraries/Wine). SOURCE_REF names the commit of this repo that built
# them (CI passes $GITHUB_SHA). Writes OUTDIR/engine-fixes-<runtime tag>.tar.gz and its .sha256.
# Checks: each module is x86_64 and exports exactly what the engine's original (<name>.orig) does.
set -eu
GS_HOME="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
WINE_ROOT=$1 OUT=$2 REF=${3:-$(git -C "$GS_HOME" rev-parse HEAD 2>/dev/null || echo unknown)}
UNIX="$WINE_ROOT/lib/wine/x86_64-unix"
pin() { sed -n "s/^$1=\([^ ]*\).*/\1/p" "$GS_HOME/scripts/build-engine-fixes.sh"; }
RUNTIME_TAG=$(pin RUNTIME_TAG) RUNTIME_SHA256=$(pin RUNTIME_SHA256)
WINECX_COMMIT=$(pin WINECX_COMMIT) SDL_VERSION=$(pin SDL_VERSION)
REPO_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-OWNER/mac-game-streaming}"

fail() { echo "package-engine-fixes: $*" >&2; exit 1; }
exports() { nm -gU "$1" | awk '{print $NF}' | sort; }
for m in winebus.so winecoreaudio.so; do
  [ -f "$UNIX/$m.orig" ] || fail "$UNIX/$m.orig missing: was build-engine-fixes.sh run on this engine?"
  [ "$(lipo -archs "$UNIX/$m")" = x86_64 ] || fail "$m is not x86_64"
done
mkdir -p "$OUT"
for m in winebus.so winecoreaudio.so; do
  exports "$UNIX/$m" >"$OUT/.exports.new"; exports "$UNIX/$m.orig" >"$OUT/.exports.orig"
  cmp -s "$OUT/.exports.new" "$OUT/.exports.orig" || { diff "$OUT/.exports.orig" "$OUT/.exports.new" >&2; fail "$m exports differ from the original"; }
  echo "ok $m: x86_64, $(wc -l <"$OUT/.exports.new" | tr -d ' ') exports match the original"
done
otool -L "$UNIX/winebus.so" | grep -q libSDL2 && fail "winebus.so links SDL directly; it should load it at runtime"
nm -u "$UNIX/winebus.so" | grep -q _SDL_ && fail "winebus.so has undefined SDL symbols"
strings "$UNIX/winebus.so" | grep -q 'libSDL2-2.0.0.dylib' || fail "winebus.so doesn't name libSDL2-2.0.0.dylib (built without SDL?)"
[ "$(lipo -archs "$WINE_ROOT/lib/libSDL2-2.0.0.dylib")" = x86_64 ] || fail "libSDL2 is not x86_64"
echo "ok winebus.so loads libSDL2-2.0.0.dylib at runtime; libSDL2 is x86_64"

NAME="engine-fixes-$RUNTIME_TAG"
STAGE="$OUT/$NAME"
mkdir -p "$STAGE/Wine/lib/wine/x86_64-unix"
cp "$UNIX/winebus.so" "$UNIX/winecoreaudio.so" "$STAGE/Wine/lib/wine/x86_64-unix/"
cp "$WINE_ROOT/lib/libSDL2-2.0.0.dylib" "$STAGE/Wine/lib/"
cat >"$STAGE/README.md" <<TXT
# Engine fixes for dappermint/winecx-gptk $RUNTIME_TAG

For that runtime release only (Libraries.tar.gz, sha256 \`$RUNTIME_SHA256\`): the modules link against its ntdll.so.

- \`Wine/lib/wine/x86_64-unix/winebus.so\`: built with SDL 2 support, so controllers reach XInput. The stock module
  logs "SDL support not compiled in!".
- \`Wine/lib/wine/x86_64-unix/winecoreaudio.so\`: render buffer of half Wine's period, which fixes crackling audio.
- \`Wine/lib/libSDL2-2.0.0.dylib\`: SDL $SDL_VERSION, x86_64, which winebus.so loads at runtime.

Install: keep the originals once, then copy the \`Wine\` folder over the runtime's \`Libraries/Wine\`:
\`for f in lib/wine/x86_64-unix/winebus.so lib/wine/x86_64-unix/winecoreaudio.so lib/libSDL2-2.0.0.dylib; do cp -p "\$LIB/Wine/\$f" "\$LIB/Wine/\$f.orig"; done\`
with \`LIB\` set to the runtime's \`Libraries\` folder. Quit every Wine program first.

Sources (LGPL-2.1-or-later for the Wine modules, zlib for SDL):
- Wine: https://github.com/dappermint/winecx at \`$WINECX_COMMIT\`, plus \`patches/winecoreaudio-render-buffer.patch\`
- SDL: https://github.com/libsdl-org/SDL/releases/tag/release-$SDL_VERSION
- Build script and patch: $REPO_URL at \`$REF\` (\`scripts/build-engine-fixes.sh\`)
TXT
tar -C "$OUT" -czf "$OUT/$NAME.tar.gz" "$NAME"
(cd "$OUT" && shasum -a 256 "$NAME.tar.gz" >"$NAME.tar.gz.sha256")
echo "packed $OUT/$NAME.tar.gz"
