#!/bin/bash
# External watchdog for Hammerspoon.
# Checks the heartbeat file; if stale (>45s), kills and relaunches Hammerspoon.
# URL scheme and IPC don't work when the run loop is frozen, so we must kill it.
# Installed as a launchd agent — see com.user.hammerspoon-watchdog.plist.

HEARTBEAT="$HOME/.hammerspoon/heartbeat"
STALE_SEC=45
LOG="$HOME/.hammerspoon/console.log"

if [ ! -f "$HEARTBEAT" ]; then
    exit 0  # Hammerspoon hasn't started yet
fi

last=$(cat "$HEARTBEAT" 2>/dev/null)
now=$(date +%s)
age=$(( now - last ))

if [ "$age" -gt "$STALE_SEC" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] heartbeat stale (${age}s) — killing and relaunching Hammerspoon" >> "$LOG"
    killall Hammerspoon 2>/dev/null
    sleep 2
    open -a Hammerspoon
fi
