#!/usr/bin/env bash
# Read-only CPU observations of one explicitly selected, already-running process.
set -euo pipefail
export LC_ALL=C

fail() {
  printf 'profile_cpu: %s\n' "$*" >&2
  exit 1
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  fail 'usage: Scripts/profile_cpu.sh PID visible|closed|stopped|keepalive [NEW_OUTPUT.csv]'
fi
pid=$1
scenario=$2
[[ "$pid" =~ ^[1-9][0-9]{0,9}$ ]] || fail 'PID must be a positive decimal integer'
case "$scenario" in
  visible|closed|stopped|keepalive) ;;
  *) fail 'scenario must be visible, closed, stopped, or keepalive' ;;
esac

interval=${PROFILE_INTERVAL_SECONDS-1}
duration=${PROFILE_DURATION_SECONDS-60}
for value in "$interval" "$duration"; do
  [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] || fail 'interval and duration must be positive whole seconds (1..86400)'
  [[ "$value" -le 86400 ]] || fail 'interval and duration must be at most 86400 seconds'
done
[[ "$interval" -le "$duration" ]] || fail 'interval must not exceed duration'
[[ "$(uname -s)" == Darwin ]] || fail 'requires macOS BSD ps'

# lstart is a best-effort guard against PID reuse, not a process handle.
started=$(ps -p "$pid" -o lstart=) || fail "PID $pid is not running or cannot be inspected"
[[ -n "$started" ]] || fail "PID $pid is not running"
process=$(ps -p "$pid" -o comm=) || fail "cannot inspect PID $pid"
check_process() {
  local current status
  current=$(ps -p "$pid" -o lstart=) || fail "PID $pid exited or became inaccessible"
  [[ "$current" == "$started" ]] || fail "PID $pid exited or was reused"
  status=$(ps -p "$pid" -o stat=) || fail "cannot inspect PID $pid"
  [[ -n "$status" && "$status" != *Z* ]] || fail "PID $pid is no longer live"
}
check_process

hardware=${PROFILE_HARDWARE-$(sysctl -n hw.model)}
cpu_model=$(sysctl -n machdep.cpu.brand_string)
logical_cpus=$(sysctl -n hw.logicalcpu)
macos=$(sw_vers -productVersion)
macos_build=$(sw_vers -buildVersion)
app_version=${PROFILE_APP_VERSION-unknown}
buffer_frames=${PROFILE_BUFFER_FRAMES-unknown}
sample_rate=${PROFILE_SAMPLE_RATE_HZ-unknown}
input_device=${PROFILE_INPUT_DEVICE-unknown}
output_device=${PROFILE_OUTPUT_DEVICE-unknown}
notes=${PROFILE_NOTES-}

# No default files, directory creation, append, or overwrite of existing output.
if [[ $# -eq 3 ]]; then
  [[ -n "$3" ]] || fail 'output path must not be empty'
  [[ ! -e "$3" && ! -L "$3" ]] || fail 'output path already exists'
  set -o noclobber
  exec 3> "$3" || fail 'cannot create output (must be a new file in an existing directory)'
else
  exec 3>&1
fi

csv_row() {
  local field separator=''
  for field in "$@"; do
    field=${field//\"/\"\"}
    printf '%s"%s"' "$separator" "$field" >&3
    separator=,
  done
  printf '\n' >&3
}

csv_row timestamp_utc elapsed_seconds pid ps_cpu_percent scenario process process_started \
  hardware cpu_model logical_cpus macos macos_build app_version buffer_frames \
  sample_rate_hz input_device output_device interval_seconds duration_seconds notes

SECONDS=0
while :; do
  check_process
  cpu=$(ps -p "$pid" -o %cpu=) || fail "CPU query failed for PID $pid"
  cpu=${cpu//[[:space:]]/}
  [[ "$cpu" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "missing or invalid CPU result for PID $pid"
  check_process
  csv_row "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$SECONDS" "$pid" "$cpu" \
    "$scenario" "$process" "$started" "$hardware" "$cpu_model" "$logical_cpus" \
    "$macos" "$macos_build" "$app_version" "$buffer_frames" "$sample_rate" \
    "$input_device" "$output_device" "$interval" "$duration" "$notes"
  remaining=$((duration - SECONDS))
  [[ "$remaining" -gt 0 ]] || break
  delay=$interval
  [[ "$delay" -le "$remaining" ]] || delay=$remaining
  sleep "$delay"
done
