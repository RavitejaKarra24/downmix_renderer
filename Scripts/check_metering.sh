#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ $# -ne 0 ]]; then
  echo "Usage: Scripts/check_metering.sh" >&2
  exit 2
fi
if [[ -z "${SDKROOT:-}" ]]; then
  if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  else
    export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
  fi
fi
if [[ ! -d "$SDKROOT" ]]; then
  echo "Metering checks blocked: SDK missing: $SDKROOT" >&2
  exit 2
fi
swift format lint --strict Sources/Downmix/UI/Components/NativeMeteringView.swift Checks/Metering/main.swift
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-metering-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
# Compile actual product implementations, isolated from unrelated backend work.
# MeterSource/MeterSnapshot share files with AppState/DSP; extract verbatim, never
# mock them. All generated copies stay outside the shared working tree.
python3 Checks/Metering/extract_sources.py "$ROOT" "$CHECK_DIR/MeterSource.swift"
SOURCES=("$CHECK_DIR/MeterSource.swift")
for file in Sources/Downmix/UI/Components/NativeMeteringView.swift Sources/Downmix/UI/Theme.swift Sources/Downmix/Models/BedLayout.swift; do
  cp "$file" "$CHECK_DIR/$(basename "$file")"
  SOURCES+=("$CHECK_DIR/$(basename "$file")")
done
cp Checks/Metering/main.swift "$CHECK_DIR/main.swift"
MODULE_CACHE="$ROOT/.build/metering-check-module-cache"
mkdir -p "$MODULE_CACHE"
FLAGS=(-sdk "$SDKROOT" -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macos15.0" -module-cache-path "$MODULE_CACHE")
# First cover the normal native view configuration, without fixture hooks.
swiftc "${FLAGS[@]}" -typecheck "${SOURCES[@]}"
# The test switch exposes read-only state and controllable time/visibility on the
# actual native view. No audio backend or AppState is ever constructed.
for optimization in -Onone -O; do
  swiftc "${FLAGS[@]}" -D METERING_CHECKS "$optimization" "${SOURCES[@]}" "$CHECK_DIR/main.swift" -o "$CHECK_DIR/metering-checks"
  perl -e 'alarm 60; exec @ARGV or die $!' "$CHECK_DIR/metering-checks"
done
