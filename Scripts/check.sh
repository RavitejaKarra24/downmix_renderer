#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

Scripts/check_whitespace.sh
while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find Scripts Checks -type f -name '*.sh' -print0)
swift format lint --strict --recursive Sources Checks Scripts Package.swift
swiftc -swift-version 6 \
  Sources/Downmix/Models/BedLayout.swift \
  Sources/Downmix/DSP/Biquad.swift \
  Sources/Downmix/DSP/DownmixProcessor.swift \
  Sources/Downmix/Audio/RingBuffer.swift \
  Checks/main.swift \
  -o "$CHECK_DIR/downmix-dsp-check"
"$CHECK_DIR/downmix-dsp-check"
Scripts/check_preferences.sh
Scripts/check_realtime.sh
Scripts/check_audio_transport.sh
Scripts/check_hal.sh
Scripts/check_clock_drift.sh
Scripts/check_lifecycle.sh
Scripts/check_async_control.sh
Scripts/check_metering.sh
bash Checks/Profiling/test_profile_cpu.sh
bash Checks/Release/test_scripts.sh
bash Checks/Release/test_archive.sh
swift build

echo "All checks passed"
