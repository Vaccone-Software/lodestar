#!/bin/bash
# Rebuild and hot-swap the running lodestar (the new instance takes over
# the pid file and SIGTERMs the old one). Unloads the login agent first so
# launchd does not fight the dev instance.
set -euo pipefail
cd "$(dirname "$0")/.."
launchctl unload "$HOME/Library/LaunchAgents/com.vaccone.lodestar.plist" 2>/dev/null || true
swift build
nohup .build/debug/lodestar >/dev/null 2>&1 &
echo "lodestar restarted (pid $!)"
