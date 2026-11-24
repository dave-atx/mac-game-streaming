#!/bin/sh
# Usage: menubar.sh hide|show — toggles macOS menu bar auto-hide. Never fails, so a
# missing Automation permission can't block Sunshine from launching the app.
case "$1" in hide) v=true ;; *) v=false ;; esac
/usr/bin/osascript -e "tell application \"System Events\" to set autohide menu bar of dock preferences to $v" || true
exit 0
