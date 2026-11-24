#!/bin/sh
# Runs the scripts against stand-in wine / wineserver / cp / pgrep (tests/trace/shim) in a fake HOME, and
# compares the commands they would have run with tests/trace/expected/. No Wine, game or display needed.
#   tests/trace/run.sh            check
#   tests/trace/run.sh --update   rewrite expected/ after an intended change (review the diff)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
EX="$REPO/examples/mass-effect-le"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gs-trace.XXXXXX")"
UPDATE=0; [ "${1:-}" = --update ] && UPDATE=1
FAIL=0

STEAM="$WORK/home/prefix/drive_c/Program Files (x86)/Steam"
VDF="$STEAM/userdata/1/config/localconfig.vdf"
mkdir -p "$(dirname "$VDF")" "$WORK/tmp"
printf '"UserLocalConfigStore"\n{\n\t"Software"\n\t{\n\t\t"apps"\n\t\t{\n\t\t\t"1328670"\n\t\t\t{\n\t\t\t\t"LastPlayed"\t\t"1"\n\t\t\t}\n\t\t}\n\t}\n}\n' >"$VDF"

# run NAME FAKE_PROCS PGREP_RC SCRIPT [ARGS...]: trace one script run into $WORK/NAME.txt.
run() {
  name=$1 procs=$2 rc=$3 script=$4; shift 4
  out="$WORK/$name.txt"
  : >"$out"
  env -i HOME="$WORK/home" PATH="$HERE/shim:/usr/bin:/bin" TMPDIR="$WORK/tmp/" TRACE="$out" \
    GS_CONFIG="${GS_CONFIG_OVERRIDE:-$HERE/config.env}" FAKE_PROCS="$procs" PGREP_RC="$rc" \
    /bin/sh "$script" "$@" >>"$out.stdout" 2>&1
  status=$?
  # me-quit finishes in the background (--finish); wait for it so the trace is complete.
  case "$name" in me-quit-running)
    i=0; while [ $i -lt 20 ] && ! grep -q '^wineserver -k' "$out"; do sleep 1; i=$((i + 1)); done ;;
  esac
  echo "exit $status" >>"$out"
}

check() {  # NAME
  got="$WORK/$1.txt"
  sed -i '' -e "s#$WORK/home#HOME#g" -e "s#$WORK/tmp/#TMP/#g" -e "s#$REPO#REPO#g" "$got"
  if [ $UPDATE = 1 ]; then cp "$got" "$HERE/expected/$1.txt"; echo "updated $1"; return; fi
  if diff -u "$HERE/expected/$1.txt" "$got"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi
}

run setup-d3d "" 1 "$EX/setup-d3d.sh"; check setup-d3d
run me-launch "EASteamLauncher.exe" 1 "$EX/me-launch.sh"; check me-launch
run me-quit-idle "" 1 "$EX/me-quit.sh"; check me-quit-idle
run me-quit-running "MassEffect1.exe" 0 "$EX/me-quit.sh"; check me-quit-running
run set-launch-options "" 1 "$EX/set-launch-options.sh" 2; cat "$VDF" >>"$WORK/set-launch-options.txt"; check set-launch-options
run gs-help "" 1 "$REPO/scripts/gs" help; cat "$WORK/gs-help.txt.stdout" >>"$WORK/gs-help.txt"; check gs-help
GS_CONFIG_OVERRIDE=/nonexistent run no-config "" 1 "$REPO/scripts/gs" status
cat "$WORK/no-config.txt.stdout" >>"$WORK/no-config.txt"; check no-config

echo "work files: $WORK"
exit $FAIL
