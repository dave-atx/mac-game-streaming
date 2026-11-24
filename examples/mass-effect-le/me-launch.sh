#!/bin/sh
# Sunshine detached command: start ME LE through Windows Steam in the bottle, on the free engine.
# A cold-starting Steam sometimes drops the steam:// URL (2026-11-21: Steam came up on its store
# page and nothing launched), so ask again until EA's Steam launcher shows up.
GS_HOME="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
. "$GS_HOME/scripts/wine-env.sh"
LOG="${TMPDIR:-/tmp}/me-launch.log"
URL=steam://rungameid/1328670
cd "$WINEPREFIX/drive_c/Program Files (x86)/Steam" || exit 1

launched() {
  wine winedbg --command "info proc" 2>/dev/null | grep -qE "EASteamLauncher|MassEffect"
}

: >"$LOG"
"$GS_HOME/examples/mass-effect-le/set-monitor.sh" >>"$LOG" 2>&1
wine "C:\\Program Files (x86)\\Steam\\steam.exe" "$URL" >>"$LOG" 2>&1 &
for attempt in 1 2 3; do
  i=0
  while [ $i -lt 20 ]; do
    sleep 3
    launched && exit 0
    i=$((i + 1))
  done
  echo "me-launch: no launcher after 60 s, asking Steam again ($attempt)" >>"$LOG"
  # With Steam running this just hands the URL to it and exits.
  wine "C:\\Program Files (x86)\\Steam\\steam.exe" "$URL" >>"$LOG" 2>&1
done
echo "me-launch: gave up" >>"$LOG"
exit 1
