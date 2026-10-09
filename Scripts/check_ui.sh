#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:---hosting}"
if [[ "$MODE" != --hosting && "$MODE" != --rendered ]] || [[ $# -gt 1 ]]; then
  echo "Usage: Scripts/check_ui.sh [--rendered]" >&2
  exit 2
fi
# CLT's default SDK27 can lack the SwiftUI State macro plugin. Use the stable SDK.
if [[ -n "${DOWNMIX_UI_SDKROOT:-}" ]]; then
  export SDKROOT="$DOWNMIX_UI_SDKROOT"
elif [[ -z "${SDKROOT:-}" ]]; then
  if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  else
    export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
  fi
fi
if [[ ! -d "$SDKROOT" ]]; then
  echo "UI checks blocked: stable macOS SDK missing: $SDKROOT (set DOWNMIX_UI_SDKROOT)." >&2
  exit 2
fi
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-ui-check.XXXXXX")"
DOMAIN="com.local.downmix.UIchecks.$(uuidgen)"
APP="$CHECK_DIR/DownmixUIChecks.app"
trap 'rm -rf "$CHECK_DIR"' EXIT
mkdir -p "$APP/Contents/MacOS"
/usr/libexec/PlistBuddy -c 'Clear dict' "$APP/Contents/Info.plist" >/dev/null 2>&1
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $DOMAIN" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string DownmixUIChecks' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$APP/Contents/Info.plist"

swift format lint --strict --recursive Sources/Downmix/UI Sources/Downmix/DownmixApp.swift Checks/UI/main.swift
# Compile one unmodified snapshot of ALL product sources. Other release-check
# agents may still be editing engine/model files while swiftc is running.
mkdir -p "$CHECK_DIR/Sources"
cp -R Sources/Downmix "$CHECK_DIR/Sources/Downmix"
cp Checks/UI/main.swift "$CHECK_DIR/main.swift"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$CHECK_DIR/Sources/Downmix" -name '*.swift' | sort)
# Compiler caches contain no fixture preferences or executable state; SDK/toolchain
# hashes keep entries distinct. Reuse them rather than rebuild AppKit every run.
MODULE_CACHE="$ROOT/.build/ui-check-module-cache"
mkdir -p "$MODULE_CACHE"
FLAGS=(-sdk "$SDKROOT" -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macos15.0" -module-cache-path "$MODULE_CACHE")
# Include the real app commands in compile coverage, without running its live AppState.
swiftc "${FLAGS[@]}" -typecheck "${SOURCES[@]}"
PRODUCT=()
for file in "${SOURCES[@]}"; do
  [[ "$file" == "$CHECK_DIR/Sources/Downmix/DownmixApp.swift" ]] || PRODUCT+=("$file")
done
swiftc "${FLAGS[@]}" "${PRODUCT[@]}" "$CHECK_DIR/main.swift" -o "$APP/Contents/MacOS/DownmixUIChecks"
# Direct execution keeps the fixture in-process and makes failures visible to CI.
# A hung AppKit/WindowServer must fail, never masquerade as a passing UI check.
perl -e 'alarm 120; exec @ARGV or die $!' "$APP/Contents/MacOS/DownmixUIChecks" "$MODE"
