#!/usr/bin/env bash
# Compile/sign temporary inert fixtures; never execute an app or open audio devices.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/version.env"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-archive-fixture.XXXXXX")"
trap 'result=$?; if [[ "$result" -ne 0 && -f "$TEST_DIR/log" ]]; then tail -40 "$TEST_DIR/log" >&2; fi; rm -rf "$TEST_DIR"' EXIT
APP="$TEST_DIR/base/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS"
printf 'int main(void) { return 0; }\n' > "$TEST_DIR/main.c"
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=15.0 \
  "$TEST_DIR/main.c" -o "$APP/Contents/MacOS/$APP_NAME"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Clear dict' "$PLIST" >/dev/null 2>&1
for entry in \
  "CFBundleIdentifier=$BUNDLE_ID" "CFBundleExecutable=$APP_NAME" \
  "CFBundleShortVersionString=$MARKETING_VERSION" "CFBundleVersion=$BUILD_NUMBER" \
  "LSMinimumSystemVersion=$MACOS_MIN_VERSION" 'CFBundlePackageType=APPL' \
  'NSMicrophoneUsageDescription=Inert verification fixture' \
  "SourceDigest=$("$ROOT/Scripts/source_digest.sh")"; do
  /usr/libexec/PlistBuddy -c "Add :${entry%%=*} string ${entry#*=}" "$PLIST"
done
/usr/bin/codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
/usr/bin/ditto -c -k --keepParent "$APP" "$TEST_DIR/valid.zip"
"$ROOT/Scripts/verify_archive.sh" "$TEST_DIR/valid.zip" > "$TEST_DIR/log" 2>&1
expect_failure() {
  local kind="$1"
  /usr/bin/ditto -c -k --keepParent "$TEST_DIR/candidate/$APP_NAME.app" "$TEST_DIR/$kind.zip"
  if "$ROOT/Scripts/verify_archive.sh" "$TEST_DIR/$kind.zip" > "$TEST_DIR/log" 2>&1; then
    echo "FAIL: invalid $kind archive accepted" >&2; exit 1
  fi
}
reset_candidate() {
  rm -rf "$TEST_DIR/candidate"
  mkdir -p "$TEST_DIR/candidate"
  /usr/bin/ditto "$APP" "$TEST_DIR/candidate/$APP_NAME.app"
}
reset_candidate
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion wrong-build' "$TEST_DIR/candidate/$APP_NAME.app/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$TEST_DIR/candidate/$APP_NAME.app" >/dev/null 2>&1
expect_failure build-number
reset_candidate
/usr/libexec/PlistBuddy -c 'Set :SourceDigest stale-source' "$TEST_DIR/candidate/$APP_NAME.app/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$TEST_DIR/candidate/$APP_NAME.app" >/dev/null 2>&1
expect_failure source-digest
reset_candidate
BINARY="$TEST_DIR/candidate/$APP_NAME.app/Contents/MacOS/$APP_NAME"
/usr/bin/lipo "$BINARY" -thin arm64 -output "$TEST_DIR/thin"
cp "$TEST_DIR/thin" "$BINARY"
/usr/bin/codesign --force --sign - --timestamp=none "$TEST_DIR/candidate/$APP_NAME.app" >/dev/null 2>&1
expect_failure architecture
reset_candidate
/usr/libexec/PlistBuddy -c 'Set :NSMicrophoneUsageDescription unsigned-change' "$TEST_DIR/candidate/$APP_NAME.app/Contents/Info.plist"
expect_failure signature
echo 'Archive checks passed (valid universal fixture; wrong build, stale source, thin binary and broken signature rejected).'
