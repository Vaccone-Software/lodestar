#!/bin/bash
# Draws the pictures of the places and the doors (tools/pictures) into
# packaging/places and packaging/doors, compiled beside the mark so their
# orange is shaded the way the mark's faces are.
#   ./scripts/make-pictures.sh
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp tools/pictures/pictures.swift "$WORK/main.swift"
swiftc -O -o "$WORK/run" "$WORK/main.swift" Sources/LodestarCore/Mark.swift
"$WORK/run" packaging
