#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ -n "${SDKROOT:-}" ]]; then
  SDK="$SDKROOT"
elif [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
else
  SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi
[[ -d "$SDK" ]] || { echo "HAL checks blocked: SDK missing: $SDK" >&2; exit 2; }
case "${1:-}" in
  ""|--tsan) ;;
  *) echo "Usage: $0 [--tsan]" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then echo "Usage: $0 [--tsan]" >&2; exit 2; fi
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-hal.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

swift format lint --strict --recursive Sources/Downmix/Audio/DeviceManager.swift \
  Sources/Downmix/Audio/AudioEngine.swift Checks/HAL
# Only append private-access test helpers. Never rewrite the engine or substitute
# a fake worker. Local Swift API shadows in StubHAL.swift trap unsupported calls.
cat Sources/Downmix/Audio/AudioEngine.swift Checks/HAL/EngineAccess.swift >"$CHECK_DIR/AudioEngine.swift"
SOURCES=(
  Sources/Downmix/Models/AudioDeviceInfo.swift
  Sources/Downmix/Models/BedLayout.swift
  Sources/Downmix/DSP/Biquad.swift
  Sources/Downmix/DSP/DownmixProcessor.swift
  Sources/Downmix/Audio/DeviceManager.swift
  Sources/Downmix/Audio/AudioRenderGate.swift
  Sources/Downmix/Audio/RealtimeMailbox.swift
  Sources/Downmix/Audio/AudioDiagnostics.swift
  Sources/Downmix/Audio/RingBuffer.swift
  Sources/Downmix/Audio/AdaptiveStereoResampler.swift
  Sources/Downmix/Audio/StereoOutputRenderer.swift
  "$CHECK_DIR/AudioEngine.swift"
  Checks/HAL/StubHAL.swift
  Checks/HAL/main.swift
)
assert_no_system_hal() {
  nm -u "$1" >"$CHECK_DIR/undefined-symbols.txt"
  if rg '(_Audio(Object|Unit|OutputUnit|Component|Hardware))' "$CHECK_DIR/undefined-symbols.txt"; then
    echo "FAIL: check executable links a real HAL API" >&2
    exit 1
  fi
}
for mode in debug optimized; do
  FLAGS=(-Onone -g)
  if [[ "$mode" == optimized ]]; then FLAGS=(-O); fi
  echo "Running actual AudioEngine with isolated stub HAL ($mode)"
  swiftc -sdk "$SDK" -swift-version 6 -target "$(uname -m)-apple-macosx15.0" \
    "${FLAGS[@]}" "${SOURCES[@]}" -o "$CHECK_DIR/$mode"
  assert_no_system_hal "$CHECK_DIR/$mode"
  "$CHECK_DIR/$mode"
done
if [[ "${1:-}" == --tsan ]]; then
  swiftc -sdk "$SDK" -swift-version 6 -target "$(uname -m)-apple-macosx15.0" \
    -Onone -g -sanitize=thread "${SOURCES[@]}" -o "$CHECK_DIR/tsan"
  assert_no_system_hal "$CHECK_DIR/tsan"
  TSAN_OPTIONS="${TSAN_OPTIONS:-halt_on_error=1}" "$CHECK_DIR/tsan"
fi
