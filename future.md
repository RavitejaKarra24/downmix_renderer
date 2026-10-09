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

The latest lifecycle suite has **13 groups**, asynchronous control **11**, and UI **11**
(**1 deterministic ordering + 10 rendered native**), including favorites/search, Settings
transport/buffer/keep-alive, setup-sheet fake permission/cancellation and save recovery.
The legacy **61,236 DSP/ring assertions** and clock/transport/mailbox suites remain intact.

**Local verification passed:** strict formatting, whitespace/shell checks, every normal
suite above, the full debug build and rendered native UI gate. Realtime mailbox, output/
diagnostics, clock/FIR and actual-engine stub-HAL checks also passed Thread Sanitizer
without findings. `Scripts/package_zip.sh` completed both optimized architecture builds;
**Downmix 1.3.1 (build 5)** and a fresh archive extraction passed strict ad-hoc signature,
universal architecture, metadata and current-source digest verification. `Downmix.zip`
is regenerated. The documented CLT search-path/native-AX fixture warnings remain; no
real app/audio playback was launched, and no commits or remote releases were made.

### Remaining release qualification

1. Multi-hour hardware/audio-quality validation, TCC allow/deny/cancellation, sleep/wake, Bluetooth/USB reconnect, and quarantined installation on a fresh account.
2. Functional native scene/global shortcut dispatch; native fixtures cannot certify real App scene integration. Dedicated physical keyboard/VoiceOver/contrast/reduced-motion qualification is stopped by owner request.
3. Instruments allocation/lock/deadline traces and actual release CPU observations using `docs/profiling.md`. This machine selects Command Line Tools; `xcrun xctrace list templates` fails because full Xcode/Instruments is unavailable.
4. A fully passing hosted CI execution on the reviewed changes. Run [37887832105](https://github.com/RavitejaKarra24/downmix_renderer/actions/runs/37887832105) failed with Bash 3.2 empty-array errors, a silently bypassed missing `rg` isolation check, and a native preamp action-acknowledgement failure. Local follow-through and pending hosted confirmation are tracked in `todo.md`.

The engineering changes do not claim zero runtime allocations, hard-real-time guarantees, arbitrary-clock-jump tolerance, or hardware-qualified all-day playback.
