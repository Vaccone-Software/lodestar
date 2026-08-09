#!/bin/bash
# Push the current tree to the public repo as one release snapshot commit.
# The public repo is a showroom: it only ever sees released states.
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLIC_REPO="https://github.com/Vaccone-Software/lodestar.git"
VERSION=$(grep 'public static let version' Sources/LodestarCore/Version.swift | cut -d'"' -f2)
EXCLUDES=(PUBLISHING.md CLAUDE.md scripts/takeover.sh scripts/handback.sh)

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "✕ uncommitted changes — commit to the private repo first"
    exit 1
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
git -c credential.helper= -c credential.helper='!gh auth git-credential' \
    clone -q "$PUBLIC_REPO" "$STAGE"
git -C "$STAGE" checkout -q main 2>/dev/null || git -C "$STAGE" checkout -q -b main

find "$STAGE" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
git archive HEAD | tar -x -C "$STAGE"
for f in "${EXCLUDES[@]}"; do rm -f "$STAGE/$f"; done

git -C "$STAGE" add -A
if git -C "$STAGE" diff --cached --quiet; then
    echo "nothing to publish"
    exit 0
fi
if [ "$(git -C "$STAGE" rev-list --count HEAD 2>/dev/null || echo 0)" = "0" ]; then
    MSG="Lodestar v$VERSION: initial public release"
else
    MSG="v$VERSION"
fi
git -C "$STAGE" commit -q -m "$MSG"
git -C "$STAGE" tag -f "v$VERSION"
git -C "$STAGE" -c credential.helper= -c credential.helper='!gh auth git-credential' \
    push -q origin main "refs/tags/v$VERSION"
echo "✓ published v$VERSION to $PUBLIC_REPO"
