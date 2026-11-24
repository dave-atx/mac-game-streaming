#!/bin/sh
# Set ME LE's Steam launch options so the launcher preselects a game: `set-launch-options.sh 1`
# (default) for ME1, 2 or 3. The launcher still shows "Press any key" and then the game card,
# so two presses of A/Return start it. Steam must not be running (it rewrites localconfig.vdf).
set -eu
GS_HOME="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
. "$GS_HOME/scripts/wine-env.sh"
GAME="${1:-1}"
if pgrep -qf 'steam\.exe'; then echo "quit Steam first (me-quit.sh)" >&2; exit 1; fi
for f in "$WINEPREFIX/drive_c/Program Files (x86)/Steam/userdata/"*/config/localconfig.vdf; do
  python3 -I - "$f" "-game $GAME -autoterminate" <<'EOF'
import re, sys
path, opts = sys.argv[1], sys.argv[2]
s = open(path, encoding="utf-8").read()
m = re.search(r'\n(\t+)"1328670"\n\1\{\n', s)
if not m:
    sys.exit(f"{path}: no 1328670 app block")
indent = m.group(1) + "\t"
start, end = m.end(), s.index("\n" + m.group(1) + "}", m.end())
block = s[start:end]
line = f'{indent}"LaunchOptions"\t\t"{opts}"\n'
block, n = re.subn(rf'{indent}"LaunchOptions"\t\t"[^"\n]*"\n', line, block)
if not n:
    block = line + block
open(path, "w", encoding="utf-8").write(s[:start] + block + s[end:])
print(f"{path}: LaunchOptions = {opts}")
EOF
done
