#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-lifecycle-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

swift format lint --strict \
  Sources/Downmix/AppState.swift \
  Sources/Downmix/Audio/AudioEngineControlling.swift \
  Sources/Downmix/Audio/DeviceManager.swift \
  Checks/Lifecycle/main.swift

# Compile the actual backend as well as its injectable control interface, without UI/app entry.
swiftc -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macos15.0" \
  Sources/Downmix/Models/BedLayout.swift \
  Sources/Downmix/Models/Preferences.swift \
  Sources/Downmix/Models/AudioDeviceInfo.swift \
  Sources/Downmix/DSP/Biquad.swift \
  Sources/Downmix/DSP/DownmixProcessor.swift \
  Sources/Downmix/Audio/*.swift \
  Sources/Downmix/AppState.swift \
  Checks/Lifecycle/main.swift \
  -o "$CHECK_DIR/downmix-lifecycle-check"
"$CHECK_DIR/downmix-lifecycle-check"
