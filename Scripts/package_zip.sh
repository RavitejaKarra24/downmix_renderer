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

log "Running formatting, regression, build, and native UI release checks before packaging"
"$ROOT/Scripts/check_release.sh"

log "Building ${APP_NAME} ${MARKETING_VERSION} (${ARCHES})"
SIGNING_MODE=adhoc ARCHES="$ARCHES" "$ROOT/Scripts/package_app.sh" release

log "Verifying the signature on the bundle"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

# Keep the previous download intact until the replacement has passed verification.
VERIFY_DIR="$(mktemp -d "$ROOT/.build/zip-verify.XXXXXX")"
trap 'rm -rf "$VERIFY_DIR"' EXIT
CANDIDATE_ZIP="$VERIFY_DIR/${APP_NAME}.zip"

log "Archiving with ditto"
/usr/bin/ditto -c -k --keepParent "$APP" "$CANDIDATE_ZIP"

log "Unpacking the archive and re-verifying"
/usr/bin/ditto -x -k "$CANDIDATE_ZIP" "$VERIFY_DIR"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/${APP_NAME}.app"

"$ROOT/Scripts/verify_archive.sh" "$CANDIDATE_ZIP"

ARCHIVED_ARCHES="$(lipo -archs "$VERIFY_DIR/${APP_NAME}.app/Contents/MacOS/${APP_NAME}")"
mv -f "$CANDIDATE_ZIP" "$ZIP_PATH"
ZIP_SIZE="$(du -h "$ZIP_PATH" | cut -f1 | tr -d ' ')"

echo
echo "${APP_NAME}.zip  version ${MARKETING_VERSION} (build ${BUILD_NUMBER})"
echo "  path    ${ZIP_PATH}"
echo "  size    ${ZIP_SIZE}"
echo "  arches  ${ARCHIVED_ARCHES}"
echo
echo "Commit the zip in the same commit as any user-facing change."
