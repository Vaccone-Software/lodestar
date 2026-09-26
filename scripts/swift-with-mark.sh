#!/bin/bash
# Runs one of the drawing scripts (the icon, the disk image background)
# compiled beside Sources/LodestarCore/Mark.swift, so every picture of the
# mark is drawn from the one definition the app draws from.
#   ./scripts/swift-with-mark.sh <script.swift> [arguments...]
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$1"; shift
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# A file with top-level code must be main.swift once there are two files.
cp "$SCRIPT" "$WORK/main.swift"
swiftc -O -o "$WORK/run" "$WORK/main.swift" Sources/LodestarCore/Mark.swift
"$WORK/run" "$@"
