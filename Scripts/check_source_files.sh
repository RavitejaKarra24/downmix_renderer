#!/usr/bin/env bash
# Isolated open-file source detection checks: generated fixtures only, no players or user files.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ -z "${SDKROOT:-}" ]]; then
  if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  else
    export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
  fi
fi
[[ -d "$SDKROOT" ]] || { echo "Source-file checks blocked: missing SDKROOT" >&2; exit 2; }
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-source-files-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
FILES=(
  Sources/Downmix/Audio/AudioSourceMonitor.swift
  Sources/Downmix/Audio/SourceFileMonitor.swift
  Checks/SourceFiles/main.swift
)
swift format lint --strict Sources/Downmix/Audio/SourceFileMonitor.swift Checks/SourceFiles/main.swift
for mode in debug optimized; do
  FLAGS=(-Onone -g)
  if [[ "$mode" == optimized ]]; then FLAGS=(-O); fi
  swiftc -sdk "$SDKROOT" -swift-version 6 -warnings-as-errors \
    -target "$(uname -m)-apple-macos15.0" "${FLAGS[@]}" "${FILES[@]}" -o "$CHECK_DIR/$mode"
  "$CHECK_DIR/$mode"
done
