#!/usr/bin/env bash
# Build, ad-hoc sign, archive, and re-verify the downloadable Downmix.zip.
#
# The archive is produced with `ditto -c -k --keepParent`, not `zip`: `zip` drops
# symlinks and extended attributes, which invalidates the code signature and makes
# the app fail to launch on Apple silicon with no useful error.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/version.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/version.env"
fi

APP_NAME="${APP_NAME:-Downmix}"
MARKETING_VERSION="${MARKETING_VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

# Ship a universal binary so the download runs on both Apple silicon and Intel.
ARCHES="${ARCHES:-arm64 x86_64}"

APP="$ROOT/${APP_NAME}.app"
ZIP_PATH="$ROOT/${APP_NAME}.zip"

log() { printf '==> %s\n' "$*"; }

log "Building ${APP_NAME} ${MARKETING_VERSION} (${ARCHES})"
SIGNING_MODE=adhoc ARCHES="$ARCHES" "$ROOT/Scripts/package_app.sh" release

log "Verifying the signature on the bundle"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

log "Archiving with ditto"
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP_PATH"

log "Unpacking the archive and re-verifying"
VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
/usr/bin/ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/${APP_NAME}.app"

UNPACKED_VERSION="$(/usr/bin/defaults read "$VERIFY_DIR/${APP_NAME}.app/Contents/Info.plist" CFBundleShortVersionString)"
if [[ "$UNPACKED_VERSION" != "$MARKETING_VERSION" ]]; then
  echo "ERROR: archived version ${UNPACKED_VERSION} does not match version.env (${MARKETING_VERSION})" >&2
  exit 1
fi

ARCHIVED_ARCHES="$(lipo -archs "$VERIFY_DIR/${APP_NAME}.app/Contents/MacOS/${APP_NAME}")"
ZIP_SIZE="$(du -h "$ZIP_PATH" | cut -f1 | tr -d ' ')"

echo
echo "${APP_NAME}.zip  version ${MARKETING_VERSION} (build ${BUILD_NUMBER})"
echo "  path    ${ZIP_PATH}"
echo "  size    ${ZIP_SIZE}"
echo "  arches  ${ARCHIVED_ARCHES}"
echo
echo "Commit the zip in the same commit as any user-facing change."
