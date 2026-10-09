#!/usr/bin/env bash
# Exercise check orchestration with macOS Bash 3.2 and fake tools; never touch HAL.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-check-scripts.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
FIXTURE="$TEST_DIR/repo"
mkdir -p "$FIXTURE/Scripts" "$FIXTURE/Sources/Downmix/Audio" \
  "$FIXTURE/Checks/HAL" "$TEST_DIR/bin" "$TEST_DIR/sdk"
cp "$ROOT/Scripts/check_audio_transport.sh" "$ROOT/Scripts/check_clock_drift.sh" \
  "$ROOT/Scripts/check_hal.sh" "$FIXTURE/Scripts/"
: > "$FIXTURE/Sources/Downmix/Audio/AudioEngine.swift"
: > "$FIXTURE/Checks/HAL/EngineAccess.swift"
export CHECK_SCRIPT_LOG="$TEST_DIR/events" COMPILE_RESULT=0 RUN_RESULT=0 SYMBOL_MODE=safe
export SDKROOT="$TEST_DIR/sdk"
cat > "$TEST_DIR/bin/swift" <<'SCRIPT'
#!/bin/bash
exit 0
SCRIPT
cat > "$TEST_DIR/bin/swiftc" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
printf 'compile %s\n' "$*" >> "$CHECK_SCRIPT_LOG"
[[ "$*" == *'-swift-version 6'* ]] || exit 99
[[ "$COMPILE_RESULT" == 0 ]] || exit "$COMPILE_RESULT"
output=''
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -o ]]; then output="$2"; shift; fi
  shift
done
[[ -n "$output" ]] || exit 98
printf '#!/bin/bash\nprintf "run\\n" >> "$CHECK_SCRIPT_LOG"\nexit "$RUN_RESULT"\n' > "$output"
chmod +x "$output"
SCRIPT
cat > "$TEST_DIR/bin/nm" <<'SCRIPT'
#!/bin/bash
case "$SYMBOL_MODE" in
  safe) printf '                 U _swift_retain\n' ;;
  unsafe) printf '                 U _AudioObjectGetPropertyData\n' ;;
  error) exit 19 ;;
  scan-error) rm -f "$(dirname "$2")/undefined-symbols.txt" ;;
  *) exit 99 ;;
esac
SCRIPT
# Prove HAL isolation does not require optional ripgrep or ignore its absence.
cat > "$TEST_DIR/bin/rg" <<'SCRIPT'
#!/bin/bash
printf 'unexpected rg\n' >> "$CHECK_SCRIPT_LOG"
exit 127
SCRIPT
chmod +x "$TEST_DIR/bin/"*
export PATH="$TEST_DIR/bin:/usr/bin:/bin"
fail() { echo "FAIL: $*" >&2; exit 1; }
expect_runs() {
  local actual
  actual="$(/usr/bin/awk '$0 == "run" { count++ } END { print count + 0 }' "$CHECK_SCRIPT_LOG")"
  [[ "$actual" == "$1" ]] || fail "expected $1 fixture executions, got $actual"
}
expect_failure() {
  if /bin/bash "$FIXTURE/Scripts/$1" > "$TEST_DIR/output" 2>&1; then
    fail "$1 accepted a failing compiler, executable or isolation check"
  fi
}
for script in check_audio_transport.sh check_clock_drift.sh; do
  for mode in normal tsan; do
    : > "$CHECK_SCRIPT_LOG"
    if [[ "$mode" == tsan ]]; then
      /bin/bash "$FIXTURE/Scripts/$script" --tsan > "$TEST_DIR/output" 2>&1
    else
      /bin/bash "$FIXTURE/Scripts/$script" > "$TEST_DIR/output" 2>&1
    fi
    expect_runs 1
    if [[ "$mode" == tsan ]]; then
      /usr/bin/awk '/-sanitize=thread/ { found = 1 } END { exit !found }' "$CHECK_SCRIPT_LOG" \
        || fail "$script omitted sanitizer flags"
    fi
  done
  : > "$CHECK_SCRIPT_LOG"
  COMPILE_RESULT=17
  expect_failure "$script"
  expect_runs 0
  COMPILE_RESULT=0
  RUN_RESULT=18
  expect_failure "$script"
  RUN_RESULT=0
  : > "$CHECK_SCRIPT_LOG"
  if /bin/bash "$FIXTURE/Scripts/$script" --invalid > "$TEST_DIR/output" 2>&1; then
    fail "$script accepted invalid arguments"
  fi
  [[ ! -s "$CHECK_SCRIPT_LOG" ]] || fail "$script compiled despite invalid arguments"
done
: > "$CHECK_SCRIPT_LOG"
/bin/bash "$FIXTURE/Scripts/check_hal.sh" --tsan > "$TEST_DIR/output" 2>&1
expect_runs 3
/usr/bin/awk '/unexpected rg/ { bad = 1 } END { exit bad }' "$CHECK_SCRIPT_LOG" \
  || fail 'HAL isolation still depends on ripgrep'
for failure in unsafe error scan-error; do
  : > "$CHECK_SCRIPT_LOG"
  SYMBOL_MODE="$failure"
  expect_failure check_hal.sh
  expect_runs 0
done
SYMBOL_MODE=safe
: > "$CHECK_SCRIPT_LOG"
COMPILE_RESULT=17
expect_failure check_hal.sh
expect_runs 0
COMPILE_RESULT=0
RUN_RESULT=18
expect_failure check_hal.sh
RUN_RESULT=0
echo 'Check-script regressions passed (macOS Bash 3.2, normal/TSAN execution, failure propagation, fail-closed HAL isolation).'
