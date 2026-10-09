#!/usr/bin/env bash
# No GUI or audio interaction: the only live process observed is this test shell.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SAMPLER="$ROOT/Scripts/profile_cpu.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-profiling-check.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
export PROFILE_INTERVAL_SECONDS=1 PROFILE_DURATION_SECONDS=1
# Isolate tests from caller-provided metadata.
export PROFILE_HARDWARE=test-hardware PROFILE_APP_VERSION='test,"version"'
export PROFILE_BUFFER_FRAMES=256 PROFILE_SAMPLE_RATE_HZ=48000
export PROFILE_INPUT_DEVICE=test-input PROFILE_OUTPUT_DEVICE=test-output PROFILE_NOTES=

fail() {
  printf 'profiling test: %s\n' "$*" >&2
  exit 1
}
reject() {
  if "$@" > "$TEST_DIR/rejected.stdout" 2> "$TEST_DIR/rejected.stderr"; then
    fail "unexpected success: $*"
  fi
  [[ ! -s "$TEST_DIR/rejected.stdout" ]] || fail 'rejection wrote CSV to stdout'
  [[ -s "$TEST_DIR/rejected.stderr" ]] || fail 'rejection lacked diagnostic'
}

reject bash "$SAMPLER"
for pid in 0 -1 01 '1,2' '1; echo unsafe' abc 99999999999; do
  reject bash "$SAMPLER" "$pid" stopped
done
reject bash "$SAMPLER" "$$" unsupported
for value in 0 -1 01 1.5 nan inf '1; echo unsafe' '' 86401 99999999999; do
  reject env PROFILE_DURATION_SECONDS="$value" bash "$SAMPLER" "$$" stopped
  reject env PROFILE_INTERVAL_SECONDS="$value" bash "$SAMPLER" "$$" stopped
done
reject env PROFILE_INTERVAL_SECONDS=2 bash "$SAMPLER" "$$" stopped
reject bash "$SAMPLER" "$$" stopped ''
reject bash "$SAMPLER" "$$" stopped "$TEST_DIR/missing/output.csv"

bash "$SAMPLER" "$$" stopped > "$TEST_DIR/stdout.csv"
[[ "$(wc -l < "$TEST_DIR/stdout.csv")" -ge 3 ]] || fail 'expected header and at least two samples'
IFS= read -r header < "$TEST_DIR/stdout.csv"
[[ "$header" == '"timestamp_utc","elapsed_seconds","pid","ps_cpu_percent","scenario",'* ]] || fail 'bad CSV header'
content=$(< "$TEST_DIR/stdout.csv")
[[ "$content" == *'"test,""version""","256","48000","test-input","test-output"'* ]] || fail 'metadata/CSV escaping failed'
[[ "$content" == *",\"$$\","* ]] || fail 'PID missing'

bash "$SAMPLER" "$$" keepalive "$TEST_DIR/file.csv" > "$TEST_DIR/output.stdout"
[[ -s "$TEST_DIR/file.csv" && ! -s "$TEST_DIR/output.stdout" ]] || fail 'output routing failed'
cp "$TEST_DIR/file.csv" "$TEST_DIR/original.csv"
reject bash "$SAMPLER" "$$" visible "$TEST_DIR/file.csv"
cmp "$TEST_DIR/file.csv" "$TEST_DIR/original.csv" || fail 'existing output changed'
ln -s "$TEST_DIR/not-created.csv" "$TEST_DIR/symlink.csv"
reject bash "$SAMPLER" "$$" visible "$TEST_DIR/symlink.csv"
[[ ! -e "$TEST_DIR/not-created.csv" ]] || fail 'followed dangling output symlink'
mkfifo "$TEST_DIR/fifo.csv"
reject bash "$SAMPLER" "$$" visible "$TEST_DIR/fifo.csv"

# A real, already-exited test process must fail before creating output.
bash -c 'exit 0' &
exited=$!
wait "$exited"
reject bash "$SAMPLER" "$exited" closed "$TEST_DIR/dead.csv"
[[ ! -e "$TEST_DIR/dead.csv" ]] || fail 'dead PID created output'

# Deterministic ps failure and reuse between reads; no signalling of any process.
mkdir "$TEST_DIR/bin"
# The mock expands these variables when invoked, not when generated.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  '[[ "$1" == -p && "$2" == "$TEST_PID" && "$3" == -o && $# -eq 4 ]] || exit 2' \
  'case "$4" in' \
  '  lstart=) if [[ -e "$TEST_MARKER" ]]; then printf "reused\\n"; else printf "original\\n"; fi ;;' \
  '  comm=) printf "test-process\\n" ;;' \
  '  stat=) printf "%s\\n" "${TEST_STATUS:-S}" ;;' \
  '  %cpu=) if [[ "$TEST_MODE" == death ]]; then exit 1; fi; : > "$TEST_MARKER"; printf "0.0\\n" ;;' \
  '  *) exit 2 ;;' \
  'esac' > "$TEST_DIR/bin/ps"
chmod +x "$TEST_DIR/bin/ps"
for mode in death reuse; do
  rm -f "$TEST_DIR/marker"
  if env PATH="$TEST_DIR/bin:$PATH" TEST_PID="$$" TEST_MODE="$mode" \
    TEST_MARKER="$TEST_DIR/marker" bash "$SAMPLER" "$$" stopped \
    > "$TEST_DIR/$mode.csv" 2> "$TEST_DIR/$mode.stderr"; then
    fail "$mode during sampling was not rejected"
  fi
  [[ "$(wc -l < "$TEST_DIR/$mode.csv")" -eq 1 ]] || fail "$mode emitted a misleading sample"
  [[ -s "$TEST_DIR/$mode.stderr" ]] || fail "$mode lacked diagnostic"
done
rm -f "$TEST_DIR/marker"
reject env PATH="$TEST_DIR/bin:$PATH" TEST_PID="$$" TEST_MODE=death \
  TEST_MARKER="$TEST_DIR/marker" TEST_STATUS=Z bash "$SAMPLER" "$$" stopped
printf 'Profiling sampler checks passed (test shell only; no app CPU measurements).\n'
