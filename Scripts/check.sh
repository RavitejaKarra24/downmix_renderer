#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift format lint --recursive Sources Checks Scripts Package.swift
swift build
swiftc \
  Sources/Downmix/Models/BedLayout.swift \
  Sources/Downmix/DSP/Biquad.swift \
  Sources/Downmix/DSP/DownmixProcessor.swift \
  Checks/main.swift \
  -o /tmp/downmix-dsp-check
/tmp/downmix-dsp-check

echo "All checks passed"
