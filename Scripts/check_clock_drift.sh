#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-clock-drift.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
FLAGS=()
if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [--tsan]" >&2
  exit 2
fi
if [[ "${1:-}" == "--tsan" ]]; then
  FLAGS=(-sanitize=thread -g)
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--tsan]" >&2
  exit 2
fi
swift format lint --strict \
  Sources/Downmix/Audio/AdaptiveStereoResampler.swift \
  Checks/ClockDrift/main.swift
# Optimized standalone build: only the existing SPSC ring and the new core.
# Long virtual tests step the real controller, not billions of FIR operations.
swiftc -O -swift-version 6 -target "$(uname -m)-apple-macos15.0" "${FLAGS[@]}" \
  Sources/Downmix/Audio/RingBuffer.swift \
  Sources/Downmix/Audio/AdaptiveStereoResampler.swift \
  Checks/ClockDrift/main.swift \
  -o "$CHECK_DIR/clock-drift-check"
TSAN_OPTIONS=halt_on_error=1 "$CHECK_DIR/clock-drift-check"
