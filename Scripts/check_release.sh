#!/usr/bin/env bash
# Qualification of automatable requirements. Requires a logged-in macOS desktop.
# Hardware/TCC, physical keyboard/VoiceOver and Instruments remain manual gates.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ $# -eq 0 ]] || { echo 'Usage: Scripts/check_release.sh' >&2; exit 2; }
"$ROOT/Scripts/check.sh"
"$ROOT/Scripts/check_ui.sh" --rendered
echo 'Automated release checks passed; manual qualification is still required.'
