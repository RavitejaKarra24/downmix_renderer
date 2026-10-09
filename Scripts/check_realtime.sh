#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TSAN=false
case "${1:-}" in
"") ;;
--tsan) TSAN=true ;;
*)
  echo "Usage: $0 [--tsan]" >&2
  exit 2
  ;;
esac
if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [--tsan]" >&2
  exit 2
fi

CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-realtime.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

SOURCES=(
  Sources/Downmix/Models/BedLayout.swift
  Sources/Downmix/DSP/Biquad.swift
  Sources/Downmix/DSP/DownmixProcessor.swift
  Sources/Downmix/Audio/RealtimeMailbox.swift
  Checks/Realtime/main.swift
)
FLAGS=(-swift-version 6 -target "$(uname -m)-apple-macosx15.0")

# Lint only files owned by this workstream; no UI/engine build or SDK override.
swift format lint --strict \
  Sources/Downmix/Audio/RealtimeMailbox.swift \
  Sources/Downmix/DSP/DownmixProcessor.swift \
  Checks/Realtime/main.swift

for mode in debug optimized; do
  if [[ "$mode" == debug ]]; then
    OPTIMIZATION=(-Onone -g)
  else
    OPTIMIZATION=(-O)
  fi
  echo "Running realtime checks ($mode)"
  swiftc "${FLAGS[@]}" "${OPTIMIZATION[@]}" "${SOURCES[@]}" -o "$CHECK_DIR/$mode"
  "$CHECK_DIR/$mode"
done

# Verify the generic boundary rejects both Array and reference payloads, even
# when they are Sendable. These intentionally failing sources stay temporary.
for payload in array reference; do
  if [[ "$payload" == array ]]; then
    printf '%s\n' 'func rejected() { _ = RealtimeMailbox([1, 2, 3]) }' >"$CHECK_DIR/rejected.swift"
  else
    printf '%s\n' \
      'final class Reference: Sendable {}' \
      'func rejected() { _ = RealtimeMailbox(Reference()) }' >"$CHECK_DIR/rejected.swift"
  fi
  if swiftc "${FLAGS[@]}" -typecheck Sources/Downmix/Audio/RealtimeMailbox.swift \
    "$CHECK_DIR/rejected.swift" >"$CHECK_DIR/rejected.log" 2>&1; then
    echo "FAIL: mailbox accepted $payload payload" >&2
    exit 1
  fi
  if [[ "$(<"$CHECK_DIR/rejected.log")" != *BitwiseCopyable* ]]; then
    echo "FAIL: $payload typecheck failed for an unexpected reason" >&2
    exit 1
  fi
done
echo "PASS: Array/reference payloads rejected by BitwiseCopyable"

if [[ "$TSAN" == true ]]; then
  echo "Running realtime checks (Thread Sanitizer)"
  swiftc "${FLAGS[@]}" -Onone -g -sanitize=thread "${SOURCES[@]}" -o "$CHECK_DIR/tsan"
  TSAN_OPTIONS="${TSAN_OPTIONS:-halt_on_error=1}" "$CHECK_DIR/tsan"
fi

echo "All realtime checks passed"
