#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Use the stable SDK even when the selected toolchain defaults to a beta SDK.
if [[ -z "${SDKROOT:-}" ]]; then
  if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  else
    export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
  fi
fi
[[ -d "$SDKROOT" ]] || { printf 'Missing stable SDK: %s (set SDKROOT)\n' "$SDKROOT" >&2; exit 1; }
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-async-control-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

swift format lint --strict \
  Sources/Downmix/Audio/AudioEngine.swift \
  Sources/Downmix/Audio/AudioEngineControlling.swift \
  Sources/Downmix/Audio/AsyncAudioEngineController.swift \
  Sources/Downmix/Audio/AudioRenderGate.swift \
  Sources/Downmix/AppState.swift \
  Checks/AsyncControl/main.swift

# Compile the real HAL worker for API coverage; tests inject ONLY the delayed worker.
swiftc -sdk "$SDKROOT" -swift-version 6 -parse-as-library \
  -target "$(uname -m)-apple-macos15.0" \
  Sources/Downmix/Models/BedLayout.swift \
  Sources/Downmix/Models/Preferences.swift \
  Sources/Downmix/Models/AudioDeviceInfo.swift \
  Sources/Downmix/DSP/Biquad.swift \
  Sources/Downmix/DSP/DownmixProcessor.swift \
  Sources/Downmix/Audio/*.swift \
  Sources/Downmix/AppState.swift \
  Checks/AsyncControl/main.swift \
  -o "$CHECK_DIR/downmix-async-control-check"
"$CHECK_DIR/downmix-async-control-check"
