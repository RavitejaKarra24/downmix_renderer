#!/usr/bin/env bash
# Read-only qualification of a downloadable archive against this source tree.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ $# -le 1 ]] || { echo 'Usage: Scripts/verify_archive.sh [archive.zip]' >&2; exit 2; }
source "$ROOT/version.env"
ARCHIVE="${1:-$ROOT/$APP_NAME.zip}"
[[ -f "$ARCHIVE" ]] || { echo "Missing archive: $ARCHIVE" >&2; exit 1; }
VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-archive-check.XXXXXX")"
trap 'rm -rf "$VERIFY_DIR"' EXIT
/usr/bin/ditto -x -k "$ARCHIVE" "$VERIFY_DIR"
APP="$VERIFY_DIR/$APP_NAME.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
PLIST="$APP/Contents/Info.plist"
check_key() {
  local key="$1" expected="$2" actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST")"
  [[ "$actual" == "$expected" ]] || {
    printf 'Archive %s mismatch: expected %s, got %s\n' "$key" "$expected" "$actual" >&2
    exit 1
  }
}
check_key CFBundleIdentifier "$BUNDLE_ID"
check_key CFBundleExecutable "$APP_NAME"
check_key CFBundleShortVersionString "$MARKETING_VERSION"
check_key CFBundleVersion "$BUILD_NUMBER"
check_key LSMinimumSystemVersion "$MACOS_MIN_VERSION"
check_key SourceDigest "$("$ROOT/Scripts/source_digest.sh")"
DESCRIPTION="$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$PLIST")"
[[ -n "$DESCRIPTION" ]] || { echo 'Archive lacks microphone permission guidance' >&2; exit 1; }
BINARY="$APP/Contents/MacOS/$APP_NAME"
ARCHES="$(/usr/bin/lipo -archs "$BINARY")"
for arch in arm64 x86_64; do
  [[ " $ARCHES " == *" $arch "* ]] || {
    echo "Archive missing architecture: $arch (got: $ARCHES)" >&2; exit 1;
  }
done
[[ "$(wc -w <<< "$ARCHES" | tr -d ' ')" == 2 ]] || {
  echo "Archive must contain exactly arm64 and x86_64, got: $ARCHES" >&2; exit 1;
}
echo "Archive verified: $APP_NAME $MARKETING_VERSION (build $BUILD_NUMBER), universal, current source inputs"
