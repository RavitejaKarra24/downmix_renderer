#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-audio-transport.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
# Bash 3.2 treats an empty array as unset under nounset. Keep common flags here.
FLAGS=(-swift-version 6)
if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [--tsan]" >&2
  exit 2
fi
if [[ "${1:-}" == "--tsan" ]]; then
  FLAGS+=(-sanitize=thread -g)
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--tsan]" >&2
  exit 2
fi
swift format lint --strict \
  Sources/Downmix/Audio/AudioDiagnostics.swift \
  Sources/Downmix/Audio/StereoOutputRenderer.swift \
  Checks/AudioTransport/main.swift
swiftc -target "$(uname -m)-apple-macos15.0" "${FLAGS[@]}" \
  Sources/Downmix/Audio/RingBuffer.swift \
  Sources/Downmix/Audio/AdaptiveStereoResampler.swift \
  Sources/Downmix/Audio/AudioDiagnostics.swift \
  Sources/Downmix/Audio/StereoOutputRenderer.swift \
  Checks/AudioTransport/main.swift \
  -o "$CHECK_DIR/audio-transport-check"
TSAN_OPTIONS=halt_on_error=1 "$CHECK_DIR/audio-transport-check"
