#!/bin/bash
# Install lodestar.app to ~/Applications and register the login LaunchAgent.
# The app instance takes over from any running lodestar via the pid file.
#
# FIRST INSTALL: macOS treats lodestar.app as a new app for privacy
# purposes — it will prompt for Accessibility; grant it under System
# Settings > Privacy & Security > Accessibility and lodestar wakes up on
# its own within a few seconds. No relaunch needed.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/make-app.sh

DEST="$HOME/Applications/lodestar.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R dist/lodestar.app "$DEST"

AGENT="$HOME/Library/LaunchAgents/com.vaccone.lodestar.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.vaccone.lodestar</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DEST/Contents/MacOS/lodestar</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ThrottleInterval</key>
	<integer>10</integer>
</dict>
</plist>
PLIST

launchctl unload "$AGENT" 2>/dev/null || true
launchctl load "$AGENT"
echo "installed $DEST and loaded the login agent"
echo "first install: grant Accessibility to lodestar in System Settings — it wakes up on its own"

# Global CLI: link the bundle binary into PATH (no sudo — pick a writable bin).
for dir in /opt/homebrew/bin /usr/local/bin; do
    if [ -d "$dir" ] && [ -w "$dir" ]; then
        ln -sf "$HOME/Applications/lodestar.app/Contents/MacOS/lodestar" "$dir/lodestar"
        echo "linked $dir/lodestar"
        break
    fi
done
