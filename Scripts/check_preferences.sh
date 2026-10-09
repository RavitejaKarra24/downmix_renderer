#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-preferences-check.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

swift format lint --strict \
  Sources/Downmix/Models/Preferences.swift \
  Checks/Preferences/main.swift
swiftc -swift-version 6 \
  Sources/Downmix/Models/BedLayout.swift \
  Sources/Downmix/Models/Preferences.swift \
  Checks/Preferences/main.swift \
  -o "$TEMP_DIR/preferences-check"
"$TEMP_DIR/preferences-check"
