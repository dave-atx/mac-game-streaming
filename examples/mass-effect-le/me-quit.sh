#!/bin/sh
# Sunshine undo command: end ME LE and the bottle without cutting off EA's cloud-save upload.
#
# After a game exits, the EA app (EADesktop.exe) uploads the saves under a server-side lock. Killing
# Wine during that upload leaves the lock held, and the next launch fails to take it (HTTP 409) and
# shows "Your latest sync was interrupted" (EC:10608). So close the game, then wait for the sync:
# EADesktop logs "Post game cloud sync completed successfully" and then shuts itself down.
# That wait runs detached (this script re-runs itself with --finish) so Sunshine's undo, and with it
# Moonlight's quit request, returns as soon as the game window is gone.
GS_HOME="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
. "$GS_HOME/scripts/wine-env.sh"
LOG="${TMPDIR:-/tmp}/me-quit.log"
EALOG="$WINEPREFIX/drive_c/ProgramData/EA Desktop/Logs/EADesktop.log"
exec >>"$LOG" 2>&1
echo "== $(date)"

procs() { wine winedbg --command "info proc" 2>/dev/null; }
running() { procs | grep -qE "$1"; }
wait_gone() {  # pattern seconds
  i=0
  while [ $i -lt "$2" ]; do
    running "$1" || return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}
# The last sync line in EA's log: "post game termination" means an upload is in progress.
sync_state() {
  grep -iE 'post game termination|cloud sync completed successfully|cloud sync failed' "$EALOG" 2>/dev/null | tail -1
}
syncing() { sync_state | grep -qi 'post game termination'; }

pgrep -qx wineserver || { sleep 2; exit 0; }

if [ "${1:-}" = --finish ]; then
  if running 'EADesktop\.exe'; then
    # EA starts the upload a few seconds after the game process ends.
    i=0
    while [ $i -lt 20 ] && ! syncing && running 'EADesktop\.exe'; do sleep 1; i=$((i + 1)); done
    i=0
    while [ $i -lt 120 ] && syncing && running 'EADesktop\.exe'; do sleep 1; i=$((i + 1)); done
    # After a successful sync EADesktop quits on its own; give it a moment to do so cleanly.
    wait_gone 'EADesktop\.exe' 15 || true
    if syncing; then echo "EA cloud sync unfinished, quitting anyway"; else sync_state | cut -c1-220; fi
  fi
  wineserver -k
  echo "bottle stopped $(date)"
  exit 0
fi

GAMES='MassEffect[123]\.exe|MassEffectLauncher\.exe'
if running "$GAMES"; then
  # Ask politely first (WM_CLOSE), then force.
  for exe in MassEffect1.exe MassEffect2.exe MassEffect3.exe MassEffectLauncher.exe; do
    wine taskkill /im "$exe" >/dev/null 2>&1
  done
  wait_gone "$GAMES" 15 || {
    echo "games ignored WM_CLOSE, forcing"
    for exe in MassEffect1.exe MassEffect2.exe MassEffect3.exe MassEffectLauncher.exe; do
      wine taskkill /f /im "$exe" >/dev/null 2>&1
    done
  }
fi

# Game windows are gone; the EA sync and the bottle shutdown continue in the background.
nohup "$0" --finish >/dev/null 2>&1 &
sleep 1
exit 0
