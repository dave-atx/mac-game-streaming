#!/bin/sh
# Usage: messages.sh quit|restore. Quits Messages for a stream; arriving messages made it redraw,
# which stuttered the stream. restore reopens it in the background only if quit closed it.
# Never fails, so Sunshine can always launch the app.
flag="${TMPDIR:-/tmp}/sunshine-messages-was-running"
case "$1" in
  quit)
    if pgrep -qx Messages; then
      touch "$flag"
      /usr/bin/osascript -e 'tell application "Messages" to quit' || true
    fi ;;
  restore)
    if [ -e "$flag" ]; then
      rm -f "$flag"
      /usr/bin/open -g -a Messages || true
    fi ;;
esac
exit 0
