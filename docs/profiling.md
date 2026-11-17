# Phase 2: read-only CPU profiling

`Scripts/profile_cpu.sh` observes **one explicit, already-running PID** on macOS.
It never launches, stops, signals, or installs Downmix, changes audio routing,
selects devices, or changes playback. You establish the state manually, then
supply its PID and scenario. There is no automatic process-name selection.

## Usage

From the repository root, replace `12345` with a PID you have verified:

```bash
PROFILE_INTERVAL_SECONDS=1 PROFILE_DURATION_SECONDS=60 \
PROFILE_APP_VERSION='your build version + commit, Release' \
PROFILE_BUFFER_FRAMES=256 PROFILE_SAMPLE_RATE_HZ=48000 \
PROFILE_INPUT_DEVICE='your input device' \
PROFILE_OUTPUT_DEVICE='your output device' \
PROFILE_NOTES='steady playback, same source and channel layout' \
  /bin/bash Scripts/profile_cpu.sh 12345 visible
```

CSV goes to stdout. An optional third argument writes to a **new** file at a path
chosen by you (its parent directory must already exist):

```bash
/bin/bash Scripts/profile_cpu.sh 12345 closed ./closed.csv
```

Existing files are refused, not overwritten or appended. There are no automatic
writes to user folders. Redirection by your shell, e.g. `> results.csv`, follows
your shell's overwrite rules instead of the script's protection.

- `PROFILE_INTERVAL_SECONDS`: positive **whole seconds**, default `1`.
- `PROFILE_DURATION_SECONDS`: positive **whole seconds**, default `60`.
- Both must be `1..86400`; interval must not exceed duration. Fractions,
  exponent notation, whitespace, leading zeros, and empty values are rejected.
- An initial sample is taken immediately; sampling continues through the duration,
  with the final sleep shortened if necessary. `elapsed_seconds` is actual
  Bash wall-clock elapsed time, not an assumed sample index. Queries and
  scheduling can make the run overshoot; this is not a precision timer.
- PID syntax is a positive decimal integer without leading zeros. Missing,
  inaccessible, zombie, or changed-start-time processes fail with nonzero exit.
  A process dying mid-run leaves partial CSV; **a nonzero exit invalidates the
  run**, even if rows were already emitted. No automatic retry or replacement.
  Start-time checks are best-effort; PID reuse within the timestamp resolution
  or an exit just after the final check cannot be ruled out.

CSV rows include UTC timestamp, elapsed seconds, PID, raw `ps` CPU percentage,
scenario, process executable name/path, process start time, hardware model, CPU
model, logical CPU count, macOS version/build, app version, buffer frames, sample
rate, input/output device labels, requested interval/duration, and notes. All
fields are CSV-quoted; quotes, commas, and newlines in metadata are escaped.
Hardware defaults to `sysctl hw.model`; `PROFILE_HARDWARE` can provide a more
useful description. App version, buffer, sample rate, and device fields are
**user-provided metadata**, defaulting to `unknown`, not inferred or verified.
Avoid sensitive device names/paths in results you plan to share.

## Comparable scenarios

Use one run per steady-state condition, after a consistent warm-up. Labels do
not control or verify the app:

| Label | State to establish manually |
| --- | --- |
| `visible` | Rendering/playback active, main window visible with meters. |
| `closed` | Same rendering/playback, main window closed, process still alive. |
| `stopped` | Audio engine stopped through the app; process still alive. Not SIGSTOP. |
| `keepalive` | Your configured keep-alive behavior, with its exact engine/window state in notes. |

Keep build configuration, source material, channel layout, device pair, sample
rate, buffer size, power/thermal conditions, and competing workload constant.
Record repeats and warm-up/run order; do not average unlike scenarios together.
The sampler does not gather system load or audio glitches. If your manual state
change terminates Downmix, use a new explicit PID for the next run.

## What `%CPU` does and does not establish

Each observation uses the BSD syntax `ps -p "$pid" -o %cpu=`. This is the
process-wide number reported by `ps`, **not an instantaneous measurement of the
last requested sampling interval**, and not isolated audio-callback cost.
`ps` implementations differ: cumulative CPU time divided by process lifetime is
an average, not instantaneous utilization; macOS BSD `ps` describes its `%CPU`
as a decaying average of recent usage. Consult the target machine's `man ps`.
Neither interpretation makes repeated `ps` calls into independent one-second
CPU measurements. Earlier activity and smoothing can affect a run after a state
change. Do not subtract successive percentages to estimate interval CPU.

100% commonly corresponds to one fully busy logical core; multithreaded usage
can exceed 100%. It is not a percentage of the whole machine's capacity.
Rounding can hide low activity; zero is not proof of no work. Sampling overhead,
thermal throttling, scheduler activity, and background applications also affect
comparisons. Treat this CSV as coarse observational evidence, not a realtime
safety test or a benchmark acceptance threshold.

## Callback evidence with Instruments

For allocation/lock investigations, manually attach Xcode Instruments to the
already-running process, with output stored at a location you choose:

1. Use **Time Profiler** to identify the input/output render callback stacks and
   expensive functions. Record visible and closed states under the same workload.
2. Use **Allocations** to inspect allocations and retain/release activity on those
   callback threads after warm-up, including reconfiguration paths you trigger
   manually. Setup allocations outside the callbacks are a separate concern.
3. Use **System Trace / Thread State** and stack inspection to investigate
   callback blocking, mutex waits, scheduling delays, and underruns. Check for
   allocation, locks, ARC, logging, and I/O in callback source as well.
4. Preserve trace, tool/build versions, thread identities, workload, and tested
   paths. Sampling alone can miss brief events; absence of a sampled stack is
   not proof of lock-free/allocation-free behavior. Instrumentation changes timing.

ThreadSanitizer is for races, not performance or proof of no allocations/locks.
Do not compare CPU results from sanitizer-instrumented checks with Release app
runs. No live Downmix CPU measurements or Instruments evidence are claimed by
adding these tools.

## Safe self-tests

```bash
/bin/bash -n Scripts/profile_cpu.sh
/bin/bash -n Checks/Profiling/test_profile_cpu.sh
/bin/bash Checks/Profiling/test_profile_cpu.sh
```

Tests observe their own shell for short runs, exercise stdout/file output and
CSV escaping, reject invalid arguments and exited PIDs, preserve existing files,
and inject deterministic `ps` death/reuse/zombie cases. They create temporary
fixtures and remove them on exit; they do not use the GUI or user audio.

# Phase 3: release checks (local)

There is no hosted CI. Hosted macOS runs failed for reasons unrelated to the code
(a stale committed archive, runner-only UI timing, account billing), so the
workflow was removed and these checks run locally before pushing:

```sh
Scripts/check.sh                        # whitespace, bash syntax, swift-format, DSP/model checks, build
Scripts/check_release.sh                # check.sh plus rendered native UI (needs a desktop session)
Scripts/verify_archive.sh               # committed Downmix.zip: signature, universal, metadata, SourceDigest
Scripts/check_realtime.sh --tsan        # mailbox/DSP under Thread Sanitizer
Scripts/check_audio_transport.sh --tsan # output/counter specs under Thread Sanitizer
Scripts/check_clock_drift.sh --tsan     # offline resampler/clock specs under Thread Sanitizer
Scripts/check_hal.sh --tsan             # actual-engine logic via isolated HAL shadows
```

`Scripts/package_zip.sh` runs `Scripts/check_release.sh` before building, then verifies
its own extracted archive. The fixtures use isolated fake audio/preferences and do not
touch real audio units, permissions or routing. Missing sanitizer specs fail instead of
skipping. Neither these checks nor self-tests measure live app CPU.
