# problem_1.md — Automatic sample-rate switching does not work

## User-visible problem

Automatic mode does not change the input device rate for anything: not Kew, not a browser
(Zen), not even Music while another app is running. The rate stays wherever it was last
set, so playback is whatever the app + macOS already converted it to. Follow input and
Fixed work, but that is manual.

## What actually happens today (evidence)

1. `AudioSourceMonitor` correctly reports the routed clients. Live log lines:
   `[sources] discovery=true clients=Zen` and `clients=kew, Zen`.
2. `SampleRateDecision.resolve` (automatic) requires **exactly one** routed client
   (`sources.count == 1`). Any second audio client — including one that is merely holding
   a silent output stream, like a browser tab or a paused player — makes the decision
   `.multipleSources`, which never requests a rate.
   Consequence: Music matching (which used to work in 1.6.1) is now suppressed whenever
   Zen/kew keeps an output stream open. That is the primary regression.
3. `DecoderRateMonitor` only recognises an explicit `ACAppleLosslessDecoder … Input format:
   … Hz … from N-bit source` record. A read-only live probe against an owned 96 kHz ALAC
   fixture showed OSLog access available and correct PID attribution, but **no** such
   record was produced. So the decoder path currently yields nothing in practice.
4. Therefore automatic mode has no working path in the user's normal setup: Music is
   blocked by client exclusivity, decoder evidence does not appear, and there is no other
   allowed source of truth.

## Why there is no universal "original file rate" API

macOS exposes the rate of the PCM a client hands to the HAL, not the rate of the file or
stream before the app resampled it. After an app converts 96 kHz to 48 kHz, that
information is gone from Core Audio. Unified-log decoder records are the only public
approximation, and they are not guaranteed (see 3). Any implementation that promises
exact automatic native-rate playback for every app is overstating what the platform
allows.

That is why app-default guessing was rejected earlier: "browser ⇒ 48 kHz" is a guess that
produces a *wrong* device rate and extra resampling for 44.1 kHz content.

## Decision for the fix

Keep "no guessing", but stop requiring an impossible universal detector:

1. **Evidence per client, not exclusivity.** Allow matching when exactly one
   *distinct rate* is supported by evidence, even if other silent clients exist. Hold only
   when two different rates are claimed.
2. **User-declarable per-app rate profile.** Some apps expose no evidence at all (Kew,
   browsers, Spotify). The user can record "this app plays at this rate", which is an
   explicit declaration, not a heuristic. Automatic then applies it while that app is the
   only routed client claiming a rate. A one-click "use the current device rate for this
   app" makes this practical.
3. **Priority order, deterministic:** fresh decoder-input evidence > per-app profile >
   supported player metadata (Music). Conflicting claims hold the current rate.
4. **No silent fallback:** the status panel keeps saying which evidence won, or that
   nothing was claimed.

## Acceptance criteria

- Music switches while a browser holds a silent stream (regression fixed).
- Kew with a saved 96 kHz profile switches to 96 kHz automatically.
- Two clients claiming different rates → no change, explained in the UI.
- No evidence and no profile → no change, explained in the UI.
- Saved profiles persist, are sanitised, and never override an explicit decoder record.
- Existing suites (DSP, HAL, lifecycle, async, UI, decoder, source) stay green.
