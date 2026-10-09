#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ $# -eq 0 ]]; then
  git diff --check
  git diff --cached --check
elif [[ $# -eq 2 ]]; then
  BASE="$1"
  HEAD="$2"
  git rev-parse --verify "${HEAD}^{commit}" >/dev/null
  # New branches and workflow_dispatch have no prior push SHA: inspect the tree.
  if [[ -z "$BASE" || "$BASE" =~ ^0+$ ]]; then
    BASE="$(git hash-object -t tree /dev/null)"
  else
    git rev-parse --verify "${BASE}^{commit}" >/dev/null
  fi
  git diff --check "$BASE" "$HEAD" --
else
  echo 'Usage: Scripts/check_whitespace.sh [BASE_COMMIT HEAD_COMMIT]' >&2
  exit 2
fi
