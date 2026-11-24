#!/bin/sh
# Point ME1/2/3 at the streaming display before a launch. The games pick a monitor by MonitorIndex in
# GamerSettings.ini, which counts Wine's monitors: the main display first, then the others in macOS's order.
# Seen 2026-11-21 (LG main: 0=LG, 1=built-in, 2=virtual) and 2026-11-24 (no LG: 0=built-in, 1=virtual). A fixed
# index breaks as soon as a display is plugged or unplugged: the game falls back to the main display, and the
# stream shows an empty desktop. Only files that already have a MonitorIndex line are changed.
GS_HOME="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
. "$GS_HOME/scripts/wine-env.sh"
PATH="$HOME/.local/bin:$PATH"
GAME="$WINEPREFIX/drive_c/Program Files (x86)/Steam/steamapps/common/Mass Effect Legendary Edition/Game"

# vdisplay list: id <TAB> flags (main, builtin, active) <TAB> geometry <TAB> pixels <TAB> vendor … model …
index=$(vdisplay list 2>/dev/null | awk -F '\t' '
  { row[NR] = $0; if ($2 ~ /(^| )main( |$)/) main = NR }
  END {
    if (!main) exit
    n = 0; order[n++] = main
    for (i = 1; i <= NR; i++) if (i != main) order[n++] = i
    for (k = 0; k < n; k++) if (row[order[k]] ~ /vendor 0x5644 /) { print k; exit }
  }')
if [ -z "$index" ]; then
  echo "set-monitor: no streaming display, leaving MonitorIndex alone"
  exit 0
fi

for n in 1 2 3; do
  f="$GAME/ME$n/BioGame/Config/GamerSettings.ini"
  old=$(sed -n 's/^MonitorIndex=\([0-9]*\).*/\1/p' "$f" 2>/dev/null)
  [ -n "$old" ] || continue
  if [ "$old" != "$index" ]; then
    # The file has CRLF line endings; replacing only the digits keeps them.
    sed -i '' "s/^MonitorIndex=[0-9]*/MonitorIndex=$index/" "$f"
    echo "set-monitor: ME$n MonitorIndex $old -> $index"
  fi
done
