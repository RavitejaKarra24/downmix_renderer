# Downmix reliability and efficiency plan

## Active checklist and scope

Use [`todo.md`](todo.md) for current completed, pending and stopped work. The
implementation records below are historical evidence, not a fresh backlog.
Per owner request, new accessibility features and accessibility-specific manual
qualification are stopped; existing native behavior/test hooks are retained.
Ordinary controls, shortcuts and audio safety remain in scope. A hosted CI run
has now failed; see the active checklist for findings and local follow-through.

## Goals and boundaries

Keep the native, local-only 9.1.6 → stereo renderer and its ADC2 matrix intact. Prioritize audio safety and working controls over new effects or a redesign. Keep macOS 15 support, 48 kHz input/output, ad-hoc signing, and the existing BlackHole workflow. Never silently reroute playback or change system audio settings.

This is a prioritized engineering plan, not a promise of a bug-free app. Automated DSP/model checks cannot certify real audio hardware, TCC permission dialogs, or long-running clock drift.

## Completion status

**Engineering implemented; release qualification is not complete.** The completion audit
found gaps despite the earlier passing suites; the follow-through below closes them and
adds regressions. The remaining hardware/TCC, functional native-scene/shortcut,
Instruments/CPU, quarantined-installation and passing hosted-CI gates cannot be
replaced by source inspection or fake-device tests. Accessibility-specific
qualification is no longer a release gate for the requested scope. Notarization, auto-update and opt-in automatic recovery remain outside
this plan's scope.

| Scope | Implementation / verification |
| --- | --- |
| Phase 1, items 1–7 | Implemented; deterministic DSP, preferences, lifecycle, asynchronous control, actual-engine stub-HAL and native meter checks. |
| Phase 2 | Implemented; bounded transport/drift, shared off-main HAL control/catalog queue, fresh failure counters, profiling tooling. Runtime traces and real playback/CPU measurements pending. |
| Phase 3 | Implemented; setup/recovery, native actions/accessibility regressions, failure-gated universal packaging and source/archive CI checks. Functional native-scene dispatch and passing hosted CI pending; dedicated accessibility qualification stopped. |

Use `Scripts/check.sh` for deterministic checks/build, `Scripts/check_release.sh` for those
plus rendered native UI, and `Scripts/package_zip.sh` for the gated universal download.
The release/UI commands require a usable logged-in macOS desktop session and fail rather
than silently substituting model coverage.

## Original audit evidence (before implementation)

- `AppState.swift`: engine status is delivered through deferred Tasks; `stop()` checks a stale running phase before starting keep-alive. Selected devices and buffer sizes can differ from the active engine. Device discovery only refreshes on app activation, and missing saved devices are replaced by fallback devices.
- `AudioEngine.swift`: callback buffers grow during rendering; teardown clears unit references before callbacks stop; keep-alive has no route watchdog; input format/disconnection is not monitored.
- `DownmixProcessor.swift`: every configuration update clears both delay lines and filter history, even a preamp or swap edit. Non-finite samples can poison filter state.
- `Preferences.swift`: synthesized decoding requires every key, so adding a setting resets older preference files; invalid persisted buffer/gain values are not normalized; failed writes are silent.
- `Checks/main.swift`: only silence, finite coefficients, and an LFE constant are checked. No matrix, clipping, buffer, or migration regressions exist.

## Phase 1 — Implement now: correctness and bounded callback work

1. Make status delivery synchronous on the main-thread control path. Clear meters and surface engine errors consistently. Stop cancels pending microphone permission starts.
2. Apply device selection changes and buffer changes by restarting the active route. Preserve missing saved device identity; stop on disconnect rather than choosing a different output. Subscribe to Core Audio device-list changes with removable listeners.
3. Request/check microphone authorization before starting input; denied/restricted access gives actionable guidance. Keep-alive requires no input permission, starts at launch when configured, and stops safely on route failure.
4. Allocate callback scratch buffers before starting units, bound maximum slices, silence invalid output buffers safely, and stop callbacks before releasing their resources. Monitor input and output availability, selected routes, and 48 kHz format. Keep the watchdog running during keep-alive.
5. Preserve DSP history on gain and output swap changes; reset only when signal topology changes. Ignore non-finite input samples and bound invalid gain settings. Keep ring overflow/underflow frame-aligned.
6. Decode missing settings with defaults, normalize supported values, write atomically, report save failures, and debounce disk writes without delaying live DSP changes. Flush pending preferences on quit.
7. Expand deterministic DSP/ring/preference regression checks and make lint/build/check failures fail the check script.

Acceptance: `Scripts/check.sh` passes; regressions cover all bed channels, center/LFE weights, mapping, gain, swap, positive/negative clipping, filter continuity, silence, invalid samples, ring boundaries, and preference migration. Hardware scenarios below remain explicitly manual.

## Phase 2 — Real-time architecture and diagnostics (engineering implemented; runtime validation pending)

- **Implemented:** replace the shared DSP `NSLock` with a bounded, preallocated three-slot SPSC configuration mailbox and fixed-size meter transport. Payloads require `BitwiseCopyable` and contain no Array/reference storage. Only the input callback owns processor/filter state while running; control setup/cleanup waits for HAL callback quiescence. **Pending:** Instruments/allocation tracing to certify runtime behavior, including Swift/runtime/Core Audio internals. Source-level removal of locks is not a blanket hard-real-time guarantee.
- **Implemented:** atomic counts for underruns, overruns, lost frames, rejected slices, and render failures, plus approximate queue fill/latency and requested/negotiated buffers at UI cadence. Unexpected/undersized output layouts are byte-bounded silent; callback errors are reported and stopped by the control watchdog, never rerouted. Final failure counters remain inspectable with zero queued latency.
- **Implemented:** bounded asynchronous clock correction with preallocated 48-tap/1024-phase windowed-sinc filtering, shared stereo phase, ±2000 ppm correction and 100 ppm/s slew. A post-callback reservoir of at least 2048 frames (42.7 ms) provides learning/reversal headroom; ring capacity additionally covers both maximum slices. Initial priming is intentional; starvation clears signal history, preserves clock bias, and counts all recovery silence. **Pending:** audible-quality and multi-hour playback on USB/Bluetooth/built-in hardware. Offline tests do not certify all-day playback or arbitrary clock jumps.
- **Implemented:** HAL setup/teardown, watchdog and route checks run on one serial off-main queue. Main-actor intent remains synchronous; per-operation delivery IDs reject stale completions. A one-way atomic gate closes immediately on Stop/cancellation; an already-rendering or hardware-buffered slice may finish. Callback storage survives until disposal, with deliberate retention if HAL refuses cleanup.
- **Tooling implemented; measurements pending:** sample an explicitly selected running PID with `Scripts/profile_cpu.sh` for visible, closed, stopped, and keep-alive scenarios. Record machine, buffer size, devices, version, interval, and duration. See `docs/profiling.md` for `ps` limitations and Instruments verification; do not substitute sampler self-tests for real app measurements.

## Phase 3 — Usability and release hardening (engineering implemented; release qualification pending)

- **Implemented:** setup checklist for a 16-channel input, both device sample rates, permission status, and a safe stereo output. Speaker mapping and system playback routing are explicitly manual checks, not falsely verified. Advanced panels show requested versus startup-negotiated buffer sizes, counters and approximate queued latency.
- **Implemented:** explicit saved-route Retry in the window/menu bar (⌘⇧R). Retry refreshes once and requires saved UIDs; reconnect does not auto-start or silently choose a fallback. Repeated Start or selection of the active device does not unnecessarily interrupt rendering. Opt-in automatic recovery remains separate follow-up work.
- **Implemented:** delayed-worker checks cover queue ownership, cancellation, stale events, warmup, configuration, teardown lifetime and reentrancy. Native hosting/rendered accessibility fixtures use actual product views and fake audio/preferences dependencies. See `docs/ui-validation.md` for exact coverage and limitations.
- **Implemented:** stable control identifiers, named device actions and reduced-motion gates; Retry now belongs to the global Transport menu. **Pending:** ordinary global shortcut dispatch and actual Settings/MenuBarExtra scene validation. **Stopped by owner request:** dedicated physical keyboard/VoiceOver/contrast/reduced-motion qualification and new accessibility features. Existing behavior/hooks remain; no unrelated visual redesign.
- **CI configuration added; passing hosted run pending (an initial run failed; see `todo.md`):** `.github/workflows/check.yml` pins actions and selects stable Xcode 26.2 on macOS, running strict formatting/build/regressions, sampler self-tests and Thread Sanitizer checks. Packaging already requires checks and verifies the extracted archive. Retain ad-hoc distribution; notarization and auto-update are separate product decisions.

## Manual release gate

- Fresh launch: permission allow/deny; auto-start enabled/disabled; keep-alive enabled/disabled.
- Start/stop rapidly from window, Settings, and menu bar; stop while permission dialog is open.
- Change input/output and buffer size while running; move gain and swap repeatedly without resetting LFE/dry history.
- Unplug input/output during rendering and during keep-alive; reconnect without implicit fallback routing.
- Change device sample rate; sleep/wake; Bluetooth reconnect; output hardware refusing requested buffer size.
- Confirm aggregate/BlackHole feedback routes are rejected.
- Play every bed channel at known levels; test silence, loud LFE, clipping, and multiple-hour drift.
- Quit immediately after a settings edit; relaunch and verify persistence.
- Build a universal zip, verify signature after extraction, and test a quarantined download on a fresh user account.

## Implementation record

### Implemented

- Phase 1 items 1–7: synchronous status, permission cancellation, actual route/buffer restarts, UID-preserving hotplug handling, keep-alive startup/watchdog, bounded preallocated slices, device-scoped buffer negotiation, DSP history preservation, finite-sample handling, stereo-aligned ring semantics with correct acquire/release ordering, resilient settings and debounced writes.
- Removable event-driven device listener and notification observers; one catalog enumeration per refresh. Errors clear meters. Menu-bar “Show Downmix” reopens a closed main window.
- Injectable control backend, catalog, permission, route-safety and persistence dependencies; tests do not touch real devices or user preferences.
- Packaging uses SwiftPM's reported product directories and separate architecture builds (works with the new Swift Build backend), runs checks first, and replaces the previous zip only after successful verification. Version bumped to 1.1.0 (build 2).

### Automated verification

- Strict recursive `swift format` lint and `git diff --check`.
- DSP/ring suite: 61,236 assertions, including 200,000 concurrent stereo frames. Agent verification also passed optimized and Thread Sanitizer runs without findings.
- Preference regressions: missing/null keys, normalization, malformed files/types, encoding, atomic temporary-file roundtrips, and surfaced write failures.
- Nine lifecycle groups: catalog resolution, transport/keep-alive, device selection, configuration versus restart, automatic startup, disconnect safety, error/meter cleanup, debounce/flush failures, and permission allow/deny/cancel including unrelated hotplug while waiting.
- Full app debug build with the installed stable macOS 26.5 SDK. The local default macOS 27 beta SDK is missing `SwiftUIMacros.StateMacro`; the SDK selection is a verification-environment workaround, not a source workaround:

  ```sh
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk Scripts/check.sh
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk Scripts/package_zip.sh
  ```

- `Scripts/package_zip.sh` passed the complete check suite and both optimized builds; regenerated `Downmix.zip` version 1.1.0 (build 2), containing **arm64 and x86_64**. Strict ad-hoc signature verification passed on the app and on a fresh extraction of the archive.

Hardware/TCC UI, actual audible continuity, CPU profiling, sleep/wake, and multi-hour clock drift have **not** been certified by the Phase 1 checks.

### Phase 2/3 implementation slice

- Replaced the render-thread DSP lock with `RealtimeMailbox`: fixed three-slot ownership transfer via acquire/release atomics, no retry loops, and compile-time rejection of reference/Array payloads. Configuration updates coalesce and apply at input block boundaries; topology-only history resets remain intact.
- Added fixed-size `RealtimeConfiguration` and `RealtimeMeterSnapshot`; Array-to-POD and UI meter conversion stay on control/UI paths. Processor delay arrays are uniquely owned before starting callbacks to avoid startup copy-on-write. Clipping events use a separate atomic latch so overwritten meter publications cannot lose a clip warning.
- Added `AudioDiagnostics` and testable `StereoOutputRenderer`. Keep-alive silence is not an underrun; startup starvation is counted. Errors stop via the watchdog and preserve final counters, without reporting stale queued audio or an active route.
- Setup/retry/diagnostics UI retains the app's existing visual identity and separate observation granularity. Tests cover permission states, genuinely manual setup steps, saved-UID retry after reconnect, repeated-command safety, deduplicated diagnostics observation, and failure history.
- Added pinned-action macOS CI and a read-only CPU sampler with metadata, argument/file/PID validation and process-death/reuse tests. Neither sampler tests nor CI launch the real app or change audio routing.

### Phase 2/3 verification

- Complete `Scripts/check.sh` passed with the stable macOS 26.5 SDK: strict lint, legacy 61,236 DSP/ring assertions, preference regressions, realtime debug/optimized tests, output transport tests, **12 lifecycle groups**, sampler self-tests and full debug build.
- Realtime mailbox tests passed **240,000 publications per run** in debug, optimized and Thread Sanitizer configurations: coherent latest values, no torn/stale payloads, final publication preserved. Array/reference payload rejection is checked by intentionally failing typechecks.
- Output/counter tests passed normal and Thread Sanitizer runs: partial reads/underruns, keep-alive, oversized slices, undersized/unexpected layouts, multi-buffer silence, byte-bound canaries, concurrent counters, clipping retention and queue-latency calculation.
- Final source review found a failure-history cleanup issue; fixed and regression-tested both backend error-publication-plus-throw and device-monitor disconnect paths so recorded counters survive cleanup without stale queued audio.
- Shell syntax/whitespace checks and CI YAML parsing passed. Hosted CI has **not** run.
- Rebuilt **Downmix 1.2.0 (build 3)** for arm64 and x86_64. `Scripts/package_zip.sh` reran the complete checks and both release builds; app and fresh archive extraction passed strict ad-hoc signature verification. `Downmix.zip` is regenerated alongside the source changes.

### Final implementation phase

- Added adaptive stereo resampling and serialized asynchronous control without altering the ADC2 matrix, supported device rates or system routing.
- Final independent review reproduced late-cleanup cancellation of a permission request and erasure of local failure counters. AppState now distinguishes cleanup acknowledgements from explicit Stop; regressions use the real asynchronous bridge rather than only synchronous mocks.
- Review also reproduced negative-skew starvation with the original 512-frame reservoir. Raised the production minimum to 2048, sized the ring from both negotiated buffers and maximum slices, and retained learned clock bias through signal gaps. All post-start recovery silence is included in missing-frame counters. Reconstruction overshoot is saturated safely and clipping survives for UI consumption.
- Actual FIR tests render 240 virtual seconds at the production minimum for constant ±2000 ppm and a +1000→−1000 ppm reversal: no gaps/overflow. Observed queue ranges: 992–1985, 1984–3100 and 1039–2367 frames respectively. These are fast offline renders, not elapsed hardware playback.
- Separate two-hour virtual controller checks cover ±100/500/1000 ppm, changing clocks and 32/128/512/1024-frame blocks with specified packet jitter. Tone checks at 1/10/20 kHz require gain error <0.05 dB, phase error <0.002 rad and peak error <0.006 FS; analytic impulse error <3e−6 FS. This does not establish full stopband behavior or worst-slice realtime deadlines.
- Ten asynchronous-control groups now include permission-after-keep-alive-cleanup and disconnect failure-history preservation; explicit Stop still resets history.
- Native AX tests exposed unknown-role setup/diagnostic rows that hid their values; assigning static-text semantics made the actual values readable. The harness also handles native toolbar segments outside the hosting subtree and validates tab selection from the rendered destination rather than retrying false action acknowledgements.
- CI includes the new clock/control gates, rendered native UI and clock Thread Sanitizer checks, and propagates its selected stable SDK. Hosted execution remains unverified.

### Final-phase verification

- Complete formatting/regression/build gate passed: 61,236 DSP/ring assertions, preferences, realtime debug/optimized checks, corrected output integration, offline clocks, 12 lifecycle groups, 10 asynchronous-control groups and profiling sampler self-tests.
- Realtime transport, output/diagnostic integration and the expanded actual-FIR/virtual-controller clock suite passed Thread Sanitizer without findings. Final normal/sanitized regressions also deliberately starve both limiting-rate runs, verify the learned clock bias survives, and recover with fresh silent PCM without old filter tails.
- Rendered native UI passed **six groups** covering actual accessibility labels/values and native actions for transport, route selections, settings, menu content, setup, diagnostics and reduced-motion content. Dependencies remained fake; no real audio units, routing changes or permission prompts were used. Physical keyboard, VoiceOver speech and animation behavior remain manual.
- Builds use the stable macOS 26.5 SDK. Toolchain search-path warnings remain; the fixture intentionally uses a deprecated own-application AX enhancement setter and an SDK-only reduced-motion shim, documented in `docs/ui-validation.md`.
- Native hosting/layout smoke checks also passed separately. Rebuilt **Downmix 1.3.0 (build 4)** after the final accessibility correction; packaging reran the complete normal check suite and both optimized architecture builds. The universal app and a fresh extraction of `Downmix.zip` passed strict ad-hoc signature verification. No commits or remote releases were made.

### Completion-audit follow-through — 1.3.1 (build 5)

The earlier implementation record was not sufficient evidence of completeness. A fresh
code/test audit reproduced the following gaps and added targeted implementation fixes:

- **Saved identity:** name-only migrated preferences with unavailable devices no longer
  fall through to defaults or overwrite the saved names. Automatic renderer/keep-alive
  startup cannot open a different route. UID resolution remains authoritative.
- **Feedback safety:** both live input and output graphs are resolved; overlapping
  roots/aggregate members, nested overlaps, BlackHole output routes, cycles and unreadable
  graphs fail closed. UID translation avoids repeatedly enumerating the device list for
  each safety certificate/watchdog tick.
- **Actual worker watchdog:** checks required channels, unit client/device layouts and
  virtual/physical stream rates, not just device availability/current ID/nominal rate.
  Nil output buffer lists record failures and stop via the watchdog; cancellation does not
  generate a spurious render failure.
- **Off-main discovery:** production catalog/safety captures share the engine controller's
  serial off-main queue and publish immutable, generation-filtered snapshots. Refreshes
  coalesce, initial automatic startup waits, and explicit Stop cancels catalog-waiting
  intent. Reading the setup checklist does not query HAL. Settings edits during a pending
  Retry rescan save/coalesce but cannot bypass it; the eventual run receives the latest
  gain/buffer configuration.
- **Failure history:** run-scoped final telemetry preserves queued newer counters and
  reads fresh atomic counters after cleanup, even before the next watchdog/UI sample.
  Cleanup cannot replace local errors or enrich a newer permission/run/preflight failure.
  Explicit Stop and new runs still reset history.
- **Meters:** explicit, durable inactive-reset generations immediately clear native
  displayed levels, held peaks/deadlines and clipping, including resets missed while
  unobserved. Running silence retains normal ballistics. Settled/hidden repaint timers
  sleep and fresh activity/window changes wake pending work; no real-app CPU claim.
- **Persistence recovery:** save errors are separate from audio errors and visible in the
  main window, Settings and menu content. Retry Save only invokes persistence; success or
  dismiss clears only that error, without starting/stopping/reconfiguring audio.
- **Retry/favorites:** Retry is disabled for every starting state, including output-only
  warmup, through one shared eligibility rule. Favorite moves target applicable visible
  neighbors, so interleaved input/output, filtered or disconnected entries cannot consume
  an invisible move; boundary context/AX actions reflect actual availability.
- **Release gates:** packaging requires deterministic and rendered native UI checks.
  Relaunch `--test` calls the real repository suite from any working directory and checks/
  builds successfully before terminating a running app. CI checks committed whitespace
  ranges, verifies the committed download and smoke-tests universal packaging. Extracted
  archives must match version/build, bundle identity, minimum OS, permission guidance,
  exact arm64/x86_64 architecture set and a signed build-input digest. This digest detects
  stale artifacts; it is not independent build provenance or hardware qualification.

Verification commands (stable SDK workaround unchanged):

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk Scripts/package_zip.sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk Scripts/check_realtime.sh --tsan
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk Scripts/check_audio_transport.sh --tsan
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk Scripts/check_clock_drift.sh --tsan
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk Scripts/check_hal.sh --tsan
Scripts/verify_archive.sh
```

`Checks/HAL` executes the actual AudioEngine with isolated Core Audio API shadows, checks
that no real HAL calls are linked, and covers unsafe graphs, format/topology mutations,
nil output, partially failed setup, failed disposal/retained refCon and in-flight callback
quiescence. `Checks/Metering` executes actual native view/source/timer logic in debug and
optimized builds. Release fixtures reject failed UI/package gates, committed whitespace,
wrong builds, stale source digests, thin binaries and invalid signatures while preserving
the prior archive. These are deterministic contracts, not real driver certification.

The lifecycle suite has **15 groups** (including diagnostics-log and Music-rate behavior), asynchronous
control **11**, and UI **11** (**1 deterministic ordering + 10 rendered native**), including
favorites/search, Settings transport/buffer/keep-alive, setup-sheet fake
permission/cancellation and save recovery. The DSP/ring suite has **72,048 assertions**
(content layouts, input rate conversion, matrix/ring/clock) and the clock/transport/mailbox
suites remain intact.

**Local verification passed:** strict formatting, whitespace/shell checks, every normal
suite above, the full debug build and rendered native UI gate. Realtime mailbox, output/
diagnostics, clock/FIR and actual-engine stub-HAL checks also passed Thread Sanitizer
without findings. `Scripts/package_zip.sh` completed both optimized architecture builds;
**Downmix 1.3.1 (build 5)** and a fresh archive extraction passed strict ad-hoc signature,
universal architecture, metadata and current-source digest verification. `Downmix.zip`
is regenerated. The documented CLT search-path/native-AX fixture warnings remain; no
real app/audio playback was launched, and no commits or remote releases were made.

### Device-rate follow-through — 1.4.0 (build 6)

Reported symptom: while Apple Music played Atmos, Downmix reported "input must expose at
least 16 channels at 48 kHz" or "the selected input is no longer at 48 kHz". The channel
wording was misleading: the failing condition was the sample rate, not the width.

Root cause (measured on the reporting Mac): the input device's nominal rate follows the
content. BlackHole sat at 44.1 kHz, and the running `SampleRateSwitcher` helper moved it
between 44.1/48/96 kHz as tracks changed. Downmix required 48 kHz at Start and in its
watchdog, so the first non-48 kHz state either blocked Start or stopped a healthy run.

Measurement that shaped the fix: with BlackHole at 44.1/96/192 kHz, an AUHAL **input** unit
whose client format was 48 kHz failed every `AudioUnitRender` with
`kAudioUnitErr_CannotDoInCurrentContext` (-10863), even though the same mismatch worked on
the built-in microphone and on the **output** side. AUHAL therefore cannot be relied on to
convert virtual-device input rates.

Implementation:

- `InputRateConverter` opens the input at the device's own rate and converts to the fixed
  48 kHz DSP rate with `AudioConverter` (float32 interleaved, mastering complexity). `nil`
  when the device is already at 48 kHz, so the normal path keeps zero added CPU and latency.
- The input client format follows the live device width, clamped to the 16 bed slots. The
  processor's input width is published through the existing mailbox after each reopen.
- The watchdog compares the live device rate/width with the run's format. A change reopens
  only the input unit (stop → set format → reallocate → initialize → start); the output unit
  and stereo queue keep running and re-prime in about a quarter of a second. A width below
  two channels, or a rate outside 8–768 kHz, still stops with a specific message. A render
  that fails with `kAudioUnitErr_CannotDoInCurrentContext` between the device's change and
  the reopen is counted but cleared as stale after the reopen, so the transient cannot stop
  a healthy run.
- Output keeps a 48 kHz client format and lets AUHAL convert to the output device rate; a
  live output rate change is no longer treated as a failure. Start no longer requires a
  48 kHz device, and the status/checklist report the live input format and the conversion.
- Input width below 16 channels is accepted at Start and by the engine: the bed slots the
  device exposes are rendered and the rest stay silent, instead of refusing to run.
- A rotating local diagnostic log records sessions, failures with run counters, device
  formats/rate changes, a 20-second heartbeat and fatal-signal markers, and detects a
  previous session that ended abruptly. UI: Transport menu, Advanced panel, Settings →
  Advanced.

Deterministic verification added: `Checks/HAL` covers 44.1/96 kHz starts, live
44.1↔48↔96 kHz switches (input-only reopen, output keeps running), width narrowing/widening,
one-channel and out-of-band refusals, and output rate changes. `Checks/main.swift` covers
stereo/5.1/7.1/9.1/9.1.6 content layouts, narrow devices, and converter gain/frequency/frame
accounting at 32/44.1/88.2/96/192 kHz with mixed block sizes. `Checks/Lifecycle` covers log
silence before a session, failure lines, unclean-stop detection, clean exit and rotation.

Real-hardware verification on the development Mac (actual `AudioEngine`, BlackHole 16ch
input, silent Dolby Audio Bridge loopback captured with a second AUHAL unit; player and
engine at each device rate):

- stereo, 5.1, 7.1, 9.1 and 9.1.6 content at 44.1 kHz: every fed bed slot's meter and the
  captured stereo L/R RMS matched the ADC2 matrix sums; unfed slots stayed at -120 dBFS.
- live 44.1 → 48 → 96 → 44.1 → 48 kHz switches: the engine stayed running, reported the new
  rate and produced the same correct stereo output at every rate.
- with `SampleRateSwitcher` left running it moved BlackHole 44.1 → 48 kHz during a run and
  the engine followed it without stopping, reproducing and resolving the reported failure.
- BlackHole's own device volume was at -12 dB, so absolute levels there are attenuated by the
  driver; the harness verified equal per-channel trim plus the exact relative matrix sums.
- Steady state showed no underruns; each rate switch/startup produced about 0.3 s of counted
  re-priming silence while the queue refilled.

Remaining: a channel or rate switch is not sample-continuous (about 0.25 s gap), the
converter is not bit-exact to the device, and multi-hour playback/instrumentation on the
user's devices is still pending. The hardware harness was an ad-hoc local tool and is not
committed; the reproducible parts are the stub-HAL and DSP/offline checks above.

### Music rate matching — 1.5.0 (build 7)

The previous release made Downmix *follow* the input device's rate. This adds the other
half, explicitly requested: match that rate to what Music is playing. It is a visible
opt-out control, not a silent system change.

- `MusicTrackRateMonitor` reads `sample rate of current track` from Music with AppleScript on
  one utility queue. It never launches Music, polls every 2 s while a track plays and every
  20 s otherwise, and also reacts to Music's `playerInfo` distributed notification. A denied
  Automation permission (`-1743`), a stopped Music, or a track without a rate is reported as
  observation state, never as an audio failure.
- `AudioEngine.requestInputSampleRate` runs on the worker queue with the rest of HAL control.
  It acts only while the renderer (not keep-alive) is running, only for an advertised device
  rate (`kAudioDevicePropertyAvailableNominalSampleRates`), and never touches the output
  device. The existing watchdog then reopens only the input unit, so the stereo output keeps
  running through the switch.
- `AppState` starts/stops monitoring with the renderer and the preference, requests a rate
  only when the reported value differs from the input device's current rate, and never
  repeats an outstanding request. A new checklist row (**Music rate matching**) reports the
  detected rate, the current input rate, waiting/verified states, and the Automation remedy.
  Settings → Audio has the opt-out toggle plus the live `Music X Hz · input Y Hz` line.
- `NSAppleEventsUsageDescription` is added to the bundle and the archive gate requires it.
- The internal DSP remains 48 kHz: matching avoids macOS's implicit downsample and makes the
  true input rate visible, but the stereo render is still 48 kHz.

Verification:

- `Checks/HAL` drives the actual engine with the stub HAL: a request changes the device rate
  and the next watchdog reopens the input at it; unavailable rates are refused without
  stopping; keep-alive and stopped engines never change a device rate; the initial rate
  request keeps rendering.
- `Checks/Lifecycle` (now **15 groups**) covers script-output parsing, monitor start/stop
  with the renderer and the toggle, request deduplication, paused-Music behaviour, the
  Automation-denied row, and verified/pending checklist states.
- Real-hardware chain test on this Mac (actual `AudioEngine`, BlackHole input, silent Dolby
  Audio Bridge output): with BlackHole forced to 44.1 kHz and Music playing a 48 kHz library
  track, the monitor reported `48000`, the engine requested it, BlackHole moved to 48 kHz,
  and the engine stayed running with `inputSampleRate = 48000`. The only 96 kHz material on
  this Mac lives outside the Music library, and no library track above 48 kHz exists, so the
  96 kHz report path is covered by the deterministic suites above rather than by a real
  96 kHz library track.

Remaining: allow/deny the Automation prompt in the real app; import a 96 kHz folder into
Music and listen through a full switch; other players (IINA/mpv/VLC) expose no rate, so they
still need Audio MIDI Setup or a switcher; the mix stays 48 kHz until/unless a variable-rate
DSP is built.

### Native-rate passthrough — 1.6.0 (build 8)

Explicit request: a 96 kHz file must reach the DAC at 96 kHz, 44.1 kHz at 44.1 kHz — no
down- or upsampling anywhere in Downmix. The downmix matrix is rate-independent; only the
rate-dependent engine parts had to change. The fixed 48 kHz DSP was a design choice, not a
downmixing limit.

Implementation:

- `DownmixProcessor.Configuration` carries the pipeline rate. `RealtimeConfiguration` now
  also carries the rate-derived LFE biquad coefficients (computed on the control side) and
  the matched dry delay, so the callback never computes coefficients. The dry delay is
  3.5833 ms (172 samples at 48 kHz) scaled to the rate; delay storage is allocated for the
  maximum supported rate, so a rate change never allocates.
- The clock-drift controller, reservoir floor (42.7 ms at the pipeline rate), stereo queue
  geometry and `queueLatencyMs` are rate-aware. The 48-tap drift kernel is unchanged: it is
  a ±2000 ppm corrector, not a general converter.
- The engine resolves `pipelineRate = input device rate` when the output device advertises
  that rate, sets the output device's nominal rate, and configures the output client at the
  same rate. Otherwise it falls back to 48 kHz (then 44.1 kHz) and the status says
  **output limit**.
- Any input rate/width change or output-rate drift reopens the whole pipeline (both units)
  at the new format; the output unit now starts before the input so the producer cannot
  overfill the ring while the output initializes. Diagnostics carry the pipeline rate.
- The passthrough rate is therefore defined by the input device, not by file metadata: for
  Music the 1.5.0 matching sets the input device per track; other players that set the
  device similarly get native-rate passthrough. Status/checklist report input, render and
  output rates and name the fallback.

Verification:

- DSP (72,048 assertions): matrix sums at 44.1/48/88.2/96/176.4/192/384 kHz; the dry delay
  equals `round(3.5833 ms × rate)` and appears exactly there; the LFE filter keeps its
  125 Hz corner (30 Hz pass, 1 kHz stop); a rate change clears filter/delay history;
  `RealtimeConfiguration` carries the same coefficients.
- HAL: 44.1 kHz start renders/opens the output at 44.1 kHz; a 96 kHz request/config moves
  input, DSP, output client and output device to 96 kHz with no converter; a 48/44.1-only
  output falls back with **output limit**; an externally drifted output rate is restored;
  keep-alive keeps the output device rate and never changes it.
- Lifecycle (15 groups), asynchronous control (11), metering, transport, clock drift (48 kHz
  baseline) and rendered UI all pass; the text now describes passthrough.
- Real hardware: 96 kHz input → DSP and output device 96 kHz (silent Dolby bridge); the
  FIIO followed 44.1 → 96 kHz live; 12 s at 96 kHz showed 0 overruns/underruns and a stable
  4096-frame queue after the start order fix. The previous 30 kHz loopback experiment
  did not establish ultrasonic preservation: meters cannot identify a tone's frequency,
  and the probe's signal/capture behavior was not qualified. No final analog DAC signal
  was captured, nor was a Dolby-bridge low-pass limitation independently established.

Remaining: physical-output listening, long-duration qualification and real 192/384 kHz
profiling. The later 48 kHz user report and logs below supersede the earlier inference
that rate-switch timing problems were always brief BlackHole transients.

### Rate-switch starvation fix — 1.6.1 (build 9)

The user reported distorted/janky 48 kHz playback. Installed 1.6.0 logs confirmed ongoing
starvation after 44.1 → 48 kHz: about 31.7 underrun events/second for several minutes,
correction saturated at −2000 ppm, no render errors or overruns, despite all displayed
rates matching. This was not ordinary independent-clock drift.

- Replace both AUHAL instances on input rate/width changes and external output-rate
  changes, rather than uninitializing/reusing them with a new client ASBD. Reusing the
  units appears to retain stale device-side timing/conversion state. Both old instances
  must dispose successfully before callback-visible storage is replaced; setup/disposal
  failures stop safely, and the existing one-way Stop gate is never reopened.
- Reuse normal device binding, buffer negotiation and client setup for the new units;
  start output before input. Preserve the run's failure counters. Clear only the stale
  old-generation format failure while quiescent, not after fresh callbacks begin.
- Extend isolated HAL checks with an adversarial stale device-rate cache surviving
  uninitialize. Pump valid stereo output, not just input meters, through repeated
  44.1/48/96/48 switches; check every final output sample and underrun/overrun counters.
  Add replacement disposal/setup failure and cancellation checks.
- Real-hardware A/B: the old binary reproduced sustained starvation during a Music/FIIO
  rate transition (3,094 new underrun events in an eight-second settled window). The
  fresh-unit binary passed the same six-step sequence, including three 48 kHz windows,
  with zero settled underruns/overruns and a 2,048-frame queue at 48 kHz.

- Longer transport check: two one-minute settled windows at 48 kHz with real Music
  audio reaching the engine and FIIO, with an intervening 44.1 kHz switch, had zero new
  underruns/overruns, a stable 2,048-frame queue and correction 0 ppm. The harness's
  named-track selection failed because those streaming tracks were not in the local
  library; it instead exercised the existing playing Music source. This verifies
  transport after manual rate changes, not automatic named-track selection. The first
  44.1 kHz window was initially silent and is not an audio-clarity acceptance test.
  Brief transition underruns still occur before the watchdog replaces the units.

Full release checks passed (72,048 DSP/ring assertions, lifecycle, async control,
clock/transport, metering, rendered UI and archive fixtures). Isolated HAL checks also
passed under Thread Sanitizer. The universal 1.6.1 (9) archive passed signature, version,
architecture and current-source verification.

Installed-runtime verified: 1.6.1 (9) launched from `~/Applications/Downmix.app` and
passed code-signature verification. After the user granted microphone access and played
Deva Deva, the real Music monitor observed 44.1 then 48 kHz and automatically moved
BlackHole, DSP and FIIO to 48 kHz. Installed-app heartbeats for a minute showed no new
underruns after the switch (75 transient events remained constant), no overruns/render
errors, a 2,048-frame queue and 0 ppm correction. The user confirmed physical playback
was clear: “now it is good”. No analog signal capture or multi-hour qualification is
claimed.

### Remaining release qualification

1. Multi-hour hardware/audio-quality validation, TCC allow/deny/cancellation, sleep/wake, Bluetooth/USB reconnect, and quarantined installation on a fresh account.
2. Functional native scene/global shortcut dispatch; native fixtures cannot certify real App scene integration. Dedicated physical keyboard/VoiceOver/contrast/reduced-motion qualification is stopped by owner request.
3. Instruments allocation/lock/deadline traces and actual release CPU observations using `docs/profiling.md`. This machine selects Command Line Tools; `xcrun xctrace list templates` fails because full Xcode/Instruments is unavailable.
4. A fully passing hosted CI execution on the reviewed changes. Run [37887832105](https://github.com/RavitejaKarra24/downmix_renderer/actions/runs/37887832105) failed with Bash 3.2 empty-array errors, a silently bypassed missing `rg` isolation check, and a native preamp action-acknowledgement failure. Local follow-through and pending hosted confirmation are tracked in `todo.md`.

The engineering changes do not claim zero runtime allocations, hard-real-time guarantees, arbitrary-clock-jump tolerance, or hardware-qualified all-day playback.
