#!/bin/bash
# Where the channels stand, as the site says: the newest build (preview),
# the stable one, and every line still on its way with the time it has
# left. The site is the only place the promotion rule lives
# (lodestar.vaccone.software/api/stable); this reads the same answer the
# stable Macs and the cask workflow read, and believes it on the same
# terms the app does: tag v<version>, zip lodestar-<version>.zip, at that
# tag's download path on GitHub.
#   ./scripts/channel.sh            where both stand
#   ./scripts/channel.sh --version  only the stable version, checked, for
#                                   a workflow (exit 1 on any bad answer)
# LODESTAR_STABLE_URL points it at another site (a preview deploy).
set -euo pipefail
URL="${LODESTAR_STABLE_URL:-https://lodestar.vaccone.software/api/stable}"
MODE="${1:-status}"

BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT
STATUS=$(curl -sS --max-time 30 --retry 2 --retry-delay 5 -o "$BODY" -w '%{http_code}' "$URL") || {
    echo "✕ $URL could not be reached" >&2
    exit 1
}
if [ "$STATUS" != "200" ]; then
    echo "✕ $URL answered HTTP $STATUS: $(head -c 300 "$BODY")" >&2
    exit 1
fi

python3 - "$BODY" "$MODE" <<'PY'
import json, re, sys
from datetime import datetime, timezone

path, mode = sys.argv[1], sys.argv[2]
DOWNLOADS = "https://github.com/Vaccone-Software/lodestar/releases/download/"

def fail(why):
    sys.exit(f"✕ the site's stable answer is not one to believe: {why}")

try:
    answer = json.load(open(path))
    tag, version, zip_ = answer["tag"], answer["version"], answer["zip"]
except (ValueError, KeyError, TypeError) as error:
    fail(f"unreadable ({error})")
if not re.fullmatch(r"\d+(\.\d+)+", str(version)):
    fail(f"version {version!r} is not a version")
if tag != f"v{version}":
    fail(f"tag {tag!r} does not name version {version}")
if zip_.get("name") != f"lodestar-{version}.zip":
    fail(f"zip {zip_.get('name')!r} is not lodestar-{version}.zip")
if zip_.get("url") != f"{DOWNLOADS}{tag}/lodestar-{version}.zip":
    fail(f"zip url {zip_.get('url')!r} is not the tag's download")

if mode == "--version":
    print(version)
    sys.exit(0)

def left(iso):
    when = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    seconds = (when - datetime.now(timezone.utc)).total_seconds()
    if seconds <= 0:
        return "due now"
    days, rest = divmod(int(seconds), 86_400)
    hours = rest // 3_600
    return f"{days}d {hours}h left" if days else f"{hours}h left"

preview = (answer.get("preview") or {}).get("tag", "?")
print(f"preview  {preview}")
print(f"stable   {tag}")
for line in answer.get("pending") or []:
    kind = line.get("kind", "?")
    print(f"  {line.get('line', '?')} {kind:<5}  {line.get('tag', '?')} promotes {line.get('promotes', '?')} ({left(line['promotes']) if line.get('promotes') else '?'})")
policy = answer.get("policy") or {}
if policy:
    print(f"policy   minor {policy.get('minorSoakDays')}d, patch {policy.get('patchSoakDays')}d, nothing younger than {policy.get('settleDays')}d")
PY
