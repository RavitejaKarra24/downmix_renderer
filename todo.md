# Downmix TODO

Source: `future.md`. This is the active checklist; that file also contains historical implementation evidence. Checked engineering items were already implemented unless explicitly described as follow-through below. A passing fake-device/offline suite is not hardware qualification.

## Scope

- Keep native, local-only 9.1.6 → stereo rendering, the ADC2 matrix, 48 kHz input/output, macOS 15 support, ad-hoc signing and the BlackHole workflow.
- Prioritize audio safety, reliable controls and measured efficiency. Never change system routing/settings or silently select another output.
- No new accessibility features or accessibility-specific release qualification, per owner request. Existing native behavior and AX hooks remain: the hooks also exercise ordinary controls in automated tests.
- Do not redo completed engineering, redesign the UI or add effects without a demonstrated need.

## Completed engineering from the plan

### Phase 1 — correctness and bounded callback work

- [x] Deliver control-path status synchronously; clear meters and surface errors; Stop cancels permission-pending starts.
- [x] Restart active routes for changed devices/buffers; preserve missing saved identity; stop on disconnect without fallback; subscribe with removable device listeners.
- [x] Check/request microphone permission for input; explain denied/restricted access; allow output-only keep-alive without input permission; honor launch preferences.
- [x] Preallocate/bound callback scratch storage, safely silence invalid output, stop callbacks before releasing resources, and monitor route availability and 48 kHz formats during rendering/keep-alive.
- [x] Preserve filter/delay history on gain/swap edits; reset topology changes only; sanitize non-finite samples/gain and keep ring overflow/underflow stereo-frame aligned.
- [x] Decode missing settings with defaults, normalize persisted values, save atomically, report errors, debounce writes without delaying DSP updates, and flush on quit.
- [x] Add deterministic regressions for every bed channel/matrix weight/mapping, gain/swap, both clipping polarities, filter continuity, silence/invalid input, concurrent ring boundaries and preference migration; fail lint/build/check errors.

### Phase 2 — realtime architecture and diagnostics

- [x] Replace the DSP lock with a bounded preallocated three-slot SPSC mailbox and fixed-size meter payloads; reject reference/Array storage at compile time.
- [x] Give the input callback exclusive processor/filter ownership while running; wait for callback quiescence before control cleanup.
- [x] Expose atomic underrun/overrun/lost-frame/rejected-slice/render-failure counters, approximate queue latency/fill and requested/negotiated buffer sizes at UI cadence.
- [x] Fail safely on unexpected/undersized/nil output layouts; stop via watchdog without rerouting; retain final counters without stale queued latency.
- [x] Add preallocated 48-tap/1024-phase stereo resampling, ±2000 ppm correction, 100 ppm/s slew, a minimum 2048-frame reservoir and ring capacity covering both maximum slices.
- [x] Preserve clock bias across starvation, clear signal tails, count recovery silence and saturate reconstruction overshoot safely.
- [x] Serialize HAL setup/teardown/watchdog/catalog/safety off-main; reject stale completion generations; immediately close the atomic render gate on cancellation; retain storage if disposal fails.
- [x] Provide explicit-PID CPU sampler, metadata/argument/file/process validation and self-tests; document its limitations in `docs/profiling.md`.
- [x] Add actual-FIR/offline clock, transport/mailbox and Thread Sanitizer checks, including limiting rates, reversal, jitter, tones, impulse response and recovery.

### Phase 3 — usability and release hardening

- [x] Provide truthful setup checks for channel count, both sample rates, permission and safe stereo output; keep mapping/system playback routing explicitly manual.
- [x] Provide saved-route-only Retry in window/menu/global Transport command; refresh once; no automatic reconnect start/fallback; repeated commands do not interrupt an unchanged route.
- [x] Test delayed-worker queue ownership, cancellation, stale events, warmup, configuration, teardown lifetime and reentrancy with isolated dependencies.
- [x] Exercise actual product views/native control actions with fake audio/preferences; retain stable identifiers and existing AX/reduced-motion hooks without expanding accessibility scope.
- [x] Configure pinned, read-only macOS CI with stable Xcode/SDK selection, committed whitespace checks, source/archive checks, rendered UI, universal packaging and sanitizer gates.
- [x] Gate packaging on checks; use SwiftPM product paths/separate architecture builds; preserve the old download until verified; validate fresh archive extraction, signature, exact architectures, metadata and signed build-input digest.

### Completion-audit fixes already implemented (1.3.1, build 5)

- [x] Preserve unavailable name-only migrated device identities; UID matching is authoritative; never auto-start another route.
- [x] Reject overlapping/nested input/output graphs, BlackHole output, cycles and unreadable graphs; avoid repeated UID enumeration.
- [x] Validate channels, client/device layouts and virtual/physical stream rates in the actual worker watchdog; reject nil output without spurious cancellation failures.
- [x] Coalesce immutable off-main catalog snapshots; generation-filter updates; wait/cancel initial startup and Retry rescans; apply latest settings without bypassing refresh.
- [x] Preserve fresh run-scoped failure telemetry through cleanup without enriching newer errors; reset only on explicit Stop/new run.
- [x] Clear native levels/peaks/clip with durable inactive generations; preserve running-silence ballistics; sleep settled/hidden meter timers and wake on activity.
- [x] Separate save/audio errors; expose Retry Save/dismiss in main/Settings/menu; never alter transport for persistence recovery.
- [x] Disable Retry during every starting state; reorder favorites using applicable visible neighbors and correct boundary availability.
- [x] Execute the real suite with relaunch `--test` from any working directory; check/build before terminating a running app.
- [x] Test actual AudioEngine through isolated HAL shadows and native meter logic in debug/optimized modes; reject failed release gates, whitespace, stale/wrong/thin/unsigned archives.

## Feasible follow-through in this session

- [x] Extract/deduplicate the plan into this checklist and explicitly stop unnecessary scope.
- [x] Inspect local tools: stable macOS 26.5 SDK available; full Xcode/Instruments unavailable (`xcrun xctrace list templates` fails).
- [x] Inspect hosted CI rather than repeat the stale “first run pending” claim. Run [37887832105](https://github.com/RavitejaKarra24/downmix_renderer/actions/runs/37887832105), commit `a41726ed5d74df1b9a87da5b4ad4785312390f98`, failed.
- [x] Fix Bash 3.2/nounset empty flag arrays in audio-transport and clock check scripts; keep common compiler flags in nonempty arrays.
- [x] Remove the HAL isolation check's optional `rg` dependency; use system `awk` and fail closed on symbol scanning errors before running the fixture.
- [x] Change the preamp fixture to verify the resulting preference, not merely the native action's Boolean acknowledgement; preserve the binding-change assertion. macOS 15 hosted confirmation is still pending.
- [x] Add isolated Bash 3.2 script regressions for normal/TSAN execution, invalid arguments, compiler/executable failure propagation and unsafe/unreadable HAL symbols; include them in `Scripts/check.sh`.
- [x] Verify the existing universal archive with `Scripts/verify_archive.sh`: 1.3.1 (build 5), signature, metadata, arm64/x86_64 and current-source digest passed before edits to test-only files/docs.
- [x] Pass strict formatting/whitespace/shell checks, all deterministic suites, debug build and rendered native UI using macOS Bash 3.2 and the stable SDK: 61,236 DSP/ring assertions, 13 lifecycle groups, 11 asynchronous-control groups and 11 UI groups. The final rerun after documentation/test-message cleanup also passed.
- [x] Pass realtime/mailbox, output/diagnostics, clock/FIR and actual-engine stub-HAL Thread Sanitizer checks without findings (local stable SDK; not a performance/hardware certification).
- [x] Verify the archive again after changes: signature, metadata, exact arm64/x86_64 slices and current-source digest passed. No build inputs changed, so no version bump or regenerated download is necessary.

Commands (system PATH also checks that optional Homebrew tools are not required):

```sh
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
/bin/bash Scripts/check_release.sh
/bin/bash Scripts/check_realtime.sh --tsan
/bin/bash Scripts/check_audio_transport.sh --tsan
/bin/bash Scripts/check_clock_drift.sh --tsan
/bin/bash Scripts/check_hal.sh --tsan
/bin/bash Scripts/verify_archive.sh
# Only when a new package is needed:
/bin/bash Scripts/package_zip.sh
```

## Remaining necessary qualification — manual or externally blocked

### Real app/audio/hardware (user-selected devices; no automatic route changes)

- [ ] Fresh launch: real TCC allow/deny/restricted handling; auto-start on/off and keep-alive on/off.
- [ ] Rapid Start/Stop from main, Settings and menu bar; Stop while a real permission dialog is open.
- [ ] Change input/output/buffer while rendering; repeatedly adjust gain/swap and listen for preserved LFE/dry continuity.
- [ ] Unplug input/output during rendering and keep-alive; reconnect and verify saved-route-only manual Retry, no implicit start/fallback.
- [ ] Change device sample rates, sleep/wake, reconnect USB/Bluetooth and test hardware refusing the requested buffer size.
- [ ] Confirm unsafe aggregate/BlackHole feedback routes are rejected on real devices.
- [ ] Play all bed channels at known levels; verify speaker mapping, system playback routing, silence, loud LFE, gain/swap and clipping safely.
- [ ] Listen for resampler artifacts and run multiple-hour playback on the devices actually used; record glitches and final counters. Offline virtual hours do not complete this item.
- [ ] Quit immediately after a settings edit, relaunch and verify real-file persistence; exercise save-error recovery if safely reproducible.
- [ ] Verify actual main/Settings/MenuBarExtra scenes and ordinary global commands: Cmd-Shift-Space, Cmd-Shift-R, Cmd-comma, setup dismissal and reopening a closed main window. This is functional dispatch testing, not a full accessibility audit.
- [ ] Test the universal ad-hoc-signed zip as a quarantined download on a fresh account. Intel execution remains separate from proving an x86_64 slice exists.

### Efficiency evidence (blocked on tools/workload)

- [ ] Collect comparable Release CPU observations for visible, closed, stopped and keep-alive states with an explicit verified PID; record machine, app version, devices, buffers, interval/duration and warmup/workload.
- [ ] With full Xcode/Instruments available, collect allocation/ARC/lock/I/O and callback scheduling/deadline traces after warmup and during deliberate reconfiguration. Preserve traces and versions; source inspection/TSAN do not establish realtime deadlines or zero allocations.

### Hosted CI

- [ ] Commit/push the reviewed local changes when authorized, run hosted CI on that exact commit, verify the preamp native action on macOS 15, and fix any remaining runner-specific failures. Do not count a local run or a rerun of the old commit as verification of these edits.
- [ ] Obtain a completely passing hosted run, including universal packaging/rendered UI and all sanitizer gates (the existing failed run skipped sanitizer checks).

## Stopped / not required for this scope

These are deliberate cancellations, not completed features and not blocking TODOs:

- **Stopped:** new accessibility features and dedicated VoiceOver speech/focus/rotor/custom-action certification.
- **Stopped:** full physical keyboard traversal/focus certification, accessibility contrast/text scaling checks and system Reduce Motion animation qualification. Ordinary existing shortcuts/controls still need functional validation above.
- **Not planned:** notarization, Sparkle/auto-update or remote release publishing; retain ad-hoc distribution.
- **Not planned:** opt-in automatic reconnect/recovery; explicit Retry already serves the requested safe behavior.
- **Not planned:** visual redesign, new effects, matrix/rate changes, automatic system routing or device fallback.
- **No unsupported claims:** zero runtime allocations, blanket hard-realtime safety, arbitrary-clock-jump tolerance, bug-free behavior or all-day hardware qualification.
