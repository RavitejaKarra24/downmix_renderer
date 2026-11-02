#!/usr/bin/env bash
# Isolated decoder fixtures; compile the actual source model and monitor, never read live logs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
case "${1:-}" in
  ""|--tsan) ;;
  *) echo "Usage: Scripts/check_decoders.sh [--tsan]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Usage: Scripts/check_decoders.sh [--tsan]" >&2; exit 2; }
if [[ -z "${SDKROOT:-}" ]]; then
  # Pin the installed stable SDK rather than picking the macOS 27 beta alias.
  if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  else
    export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
  fi
fi
[[ -d "$SDKROOT" ]] || { echo "Decoder checks blocked: missing SDKROOT" >&2; exit 2; }
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-decoders-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
FILES=(Sources/Downmix/Audio/AudioSourceMonitor.swift Sources/Downmix/Audio/DecoderRateMonitor.swift Checks/DecoderRates/main.swift)
swift format lint --strict Sources/Downmix/Audio/DecoderRateMonitor.swift Checks/DecoderRates/main.swift
for arch in arm64 x86_64; do
  swiftc -sdk "$SDKROOT" -swift-version 6 -warnings-as-errors -parse-as-library \
    -target "$arch-apple-macos15.0" -typecheck "${FILES[@]}"
  echo "PASS: Swift 6 macOS 15 $arch typecheck"
done
MODES=(debug optimized)
if [[ "${1:-}" == --tsan ]]; then MODES+=(tsan); fi
for mode in "${MODES[@]}"; do
  FLAGS=(-Onone -g)
  if [[ "$mode" == optimized ]]; then FLAGS=(-O); fi
  if [[ "$mode" == tsan ]]; then FLAGS+=(-sanitize=thread); fi
  swiftc -sdk "$SDKROOT" -swift-version 6 -warnings-as-errors -parse-as-library \
    -target "$(uname -m)-apple-macos15.0" "${FLAGS[@]}" "${FILES[@]}" -o "$CHECK_DIR/$mode"
  "$CHECK_DIR/$mode"
done
