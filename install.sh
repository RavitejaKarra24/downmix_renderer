#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$ROOT/version.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/version.env"
fi

APP_NAME="${APP_NAME:-Downmix}"
EXECUTABLE_NAME="$APP_NAME"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
OPEN_APP="${OPEN_APP:-1}"
APP_PATH="$INSTALL_DIR/$APP_NAME.app"
BUILT_APP="$ROOT/$APP_NAME.app"

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "The Xcode Command Line Tools are required." >&2
  echo "Install them with: xcode-select --install" >&2
  exit 1
fi

echo "→ Building $APP_NAME from the checked-out source"
SIGNING_MODE=adhoc ARCHES="$(uname -m)" "$ROOT/Scripts/package_app.sh" release

echo "→ Installing at $APP_PATH"
pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true
rm -rf "$APP_PATH"
mkdir -p "$INSTALL_DIR"
ditto "$BUILT_APP" "$APP_PATH"

# Locally built source checkouts normally have no quarantine flag. Remove any
# inherited app-specific quarantine metadata without changing global security settings.
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
codesign --verify --deep --strict "$APP_PATH"

if [[ "$OPEN_APP" == "1" ]]; then
  echo "→ Opening $APP_NAME"
  open "$APP_PATH"
fi

echo
echo "Installed: $APP_PATH"
echo "Future launches: open \"$APP_PATH\""
