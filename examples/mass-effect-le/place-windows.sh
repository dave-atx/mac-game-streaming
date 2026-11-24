#!/bin/sh
# Sunshine detached helper: while the streaming display exists, move the ME LE launcher and the EA
# app's Steam hand-off window ("EA Steam Launcher", e.g. its cloud-save dialog) onto it.
# The launcher has no monitor setting and always opens on the primary display. The games themselves
# are placed by MonitorIndex in their GamerSettings.ini.
# Needs Sunshine's Automation permission for System Events (already granted for menubar.sh).
PATH="$HOME/.local/bin:$PATH"
sleep 2
while vdisplay status >/dev/null 2>&1; do
  origin=$(vdisplay list | awk '/vendor 0x5644/ { for (i = 1; i <= NF; i++) if ($i == "at") print $(i + 1) }' | tr -d '()')
  x=${origin%,*}; y=${origin#*,}
  if [ -n "$origin" ]; then
    /usr/bin/osascript >/dev/null 2>&1 <<OSA
tell application "System Events"
  -- CrossOver names the process MassEffectLauncher.exe; the free engine leaves it as "wine".
  repeat with p in (every process whose name contains "MassEffectLauncher" or name is "wine")
    repeat with w in (every window of p whose name is "Mass Effect Launcher" or name is "EA Steam Launcher")
      set {wx, wy} to position of w
      if wx is not $x or wy is not $y then
        set position of w to {$x, $y}
        set frontmost of p to true
      end if
    end repeat
  end repeat
end tell
OSA
  fi
  sleep 2
done
