#!/bin/bash
# The draft, end to end, against the running Lodestar: open it by verb,
# feed a recording in place of the microphone, read the words back, close
# without pasting (the text lands on the pasteboard), and compare.
#   tools/draft-functional.sh [recording.aiff]
# With no recording, one is synthesized with `say`. Exit 0 when every
# expected word came back.
set -euo pipefail
L=${LODESTAR:-$HOME/Applications/lodestar.app/Contents/MacOS/lodestar}
FILE="${1:-}"
if [ -z "$FILE" ]; then
    FILE=$(mktemp -t draft).aiff
    say -o "$FILE" "Run the migration for user sessions and tail the log."
fi
"$L" draft state >/dev/null || { echo "✕ lodestar is not running or the verb is unknown"; exit 1; }
"$L" draft speak >/dev/null
sleep 1.5
"$L" draft audio "$FILE" >/dev/null
sleep 11
TEXT=$("$L" draft state | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"].get("text",""))')
"$L" draft close >/dev/null
echo "heard: $TEXT"
ok=0
for word in migration sessions log; do
    if echo "$TEXT" | grep -qi "$word"; then echo "  ✓ $word"; else echo "  ✕ $word"; ok=1; fi
done
BOARD=$(pbpaste)
[ "$BOARD" = "$TEXT" ] && echo "  ✓ pasteboard holds the draft" || { echo "  ✕ pasteboard differs"; ok=1; }
exit $ok
