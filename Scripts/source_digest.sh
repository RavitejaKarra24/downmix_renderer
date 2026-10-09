#!/usr/bin/env bash
# Fingerprint the current build inputs, including uncommitted/new Swift sources.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
INPUTS=(Package.swift version.env Scripts/package_app.sh Scripts/source_digest.sh Icon.icns)
while IFS= read -r file; do INPUTS+=("$file"); done < <(find Sources -type f -name '*.swift' | LC_ALL=C sort)
shasum -a 256 "${INPUTS[@]}" | shasum -a 256 | awk '{print $1}'
