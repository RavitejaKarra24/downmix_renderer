#!/usr/bin/env bash
# Compile the real read-only source monitor against isolated, adversarial HAL fixtures.
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
[[ -d "$SDKROOT" ]] || { echo "Source checks blocked: missing SDKROOT" >&2; exit 2; }
case "${1:-}" in
  ""|--tsan) ;;
  *) echo "Usage: Scripts/check_sources.sh [--tsan]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Usage: Scripts/check_sources.sh [--tsan]" >&2; exit 2; }
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-sources-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
swift format lint --strict Sources/Downmix/Audio/AudioSourceMonitor.swift Checks/Sources/main.swift
MODES=(debug optimized)
if [[ "${1:-}" == --tsan ]]; then MODES+=(tsan); fi
for mode in "${MODES[@]}"; do
  FLAGS=(-Onone -g)
  if [[ "$mode" == optimized ]]; then FLAGS=(-O); fi
  if [[ "$mode" == tsan ]]; then FLAGS+=(-sanitize=thread); fi
  swiftc -sdk "$SDKROOT" -swift-version 6 -parse-as-library \
    -target "$(uname -m)-apple-macos15.0" "${FLAGS[@]}" \
    Sources/Downmix/Audio/AudioSourceMonitor.swift Checks/Sources/main.swift \
    -o "$CHECK_DIR/$mode"
  nm -u "$CHECK_DIR/$mode" > "$CHECK_DIR/symbols"
  if ! /usr/bin/awk '
    /_Audio(Object|Unit|OutputUnit|Component|Hardware)/ { print; unsafe = 1 }
    END { exit unsafe }
  ' "$CHECK_DIR/symbols"; then
    echo "FAIL: source fixture links real HAL APIs" >&2
    exit 1
  fi
  "$CHECK_DIR/$mode"
done
