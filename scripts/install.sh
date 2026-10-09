#!/bin/zsh
# Builds TouchBridge and installs it as the copy you use daily: ~/Applications/TouchBridge.app.
# Rebuilding in the project folder never touches that copy; run this script to update it.
#
# "Start at Login" is a per-user launch agent (~/Library/LaunchAgents/com.theofanis.touchbridge.agent.plist)
# that runs the installed executable by path, so updating the app in place keeps it working.
# The first install turns it on (the app writes the agent itself).
set -euo pipefail

cd "${0:A:h}/.."
DEST="$HOME/Applications/TouchBridge.app"
LABEL="com.theofanis.touchbridge.agent"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
JOB="gui/$(id -u)/$LABEL"

./scripts/bundle.sh

# Quit every running TouchBridge (a normal Quit: the agent does not restart it), so the panel is free.
pkill -TERM -x TouchBridge || true
for _ in {1..40}; do pgrep -x TouchBridge >/dev/null || break; sleep 0.25; done
if pgrep -x TouchBridge >/dev/null; then echo "TouchBridge did not quit; aborting." >&2; exit 1; fi

mkdir -p "$DEST"
rsync -a --delete build/TouchBridge.app/ "$DEST/"
codesign --verify "$DEST"

if [[ -f "$AGENT" ]]; then
    launchctl kickstart "$JOB" 2>/dev/null || launchctl bootstrap "gui/$(id -u)" "$AGENT"
    for _ in {1..32}; do launchctl print "$JOB" 2>/dev/null | grep -qE '^[[:space:]]*state = running' && break; sleep 0.25; done
    if launchctl print "$JOB" 2>/dev/null | grep -qE '^[[:space:]]*state = running'; then
        echo "Installed $DEST and restarted the login item."
    else
        echo "Installed $DEST, but the login item did not start; opening the app directly." >&2
        open "$DEST"
        exit 1
    fi
else
    open "$DEST" --args --enable-login-item
    echo "Installed $DEST; it turns on Start at Login on first start."
fi
