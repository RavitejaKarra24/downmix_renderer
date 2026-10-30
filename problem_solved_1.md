# Problem solved: surround audio arrived as stereo

**Date:** 2026-10-29
**App:** Downmix 1.3.1 (`~/Applications/Downmix.app`, source: `downmix_renderer`)
**Status:** fixed, verified on the affected Mac

---

## 1. The problem at hand

### Pipeline

```
Elmedia Video Player  →  BlackHole 16ch  →  Downmix  →  FIIO KA13 (stereo)
```

Everything runs at 48 kHz. Downmix is supposed to receive 16 discrete bed channels
(9.1.6) and fold them down to stereo. Stereo at the FIIO is expected; stereo at the
**input of the renderer** is the bug.

### Symptom

While a movie played in Elmedia, Downmix's bed visualizer lit up **only L and R**.
Center, LFE, surrounds and heights stayed dark, so the fold-down produced a stereo
mix of a stereo mix — dialogue was not anchored, LFE was missing, and the result
sounded flat.

Reported for multiple files, including real 5.1 (E-AC-3) sources such as
`OK Jaanu.2017...DDP.5.1.mkv`. The complaint was specifically: *"it used to work
before; the only change in the plan is that we now use the Downmix app instead of
Downmix Renderer."*

### What had already been established (before this session)

- BlackHole 16ch exposes 16 input and 16 output channels at 48 kHz.
- Downmix opens **16** input channels with a direct 1:1 channel map.
- Audio MIDI Setup's speaker test into BlackHole *did* light up C and Rrs, i.e.
  BlackHole plus the renderer can transport and identify individual channels.
- Therefore the loss was somewhere in the **player → CoreAudio handoff**, but it had
  never been measured directly.

---

## 2. How it was solved

### 2.1 Getting a real measurement path

The decisive blocker was instrumentation: macOS denied audio capture to the terminal,
so any probe read silence.

- Verified with `AVCaptureDevice.authorizationStatus(for: .audio)` → `denied`.
- Reset the denied Microphone record for the terminal (`tccutil reset Microphone
  com.github.wez.wezterm`) and granted the prompt once → `authorized`.
- Built a throwaway HAL probe that opens BlackHole **exactly like Downmix does**
  (AUHAL input unit, bus 1, packed Float32, 16-channel client format, 4096-frame
  slice) and reports per-channel peak dB, optionally dumping raw interleaved float32
  for offline DFT analysis.
- Built a companion tool that plays a synthetic N-channel tone file into BlackHole
  with per-channel distinct frequencies/amplitudes.

Sanity checks before trusting the pipeline:

| Test | Result |
| --- | --- |
| Synthetic 6-ch client into BlackHole (the "beep") | device channels 1–6 receive it; user confirmed Downmix showed 6 channels |
| Elmedia playing the same 6-ch source | device channels 1–2 only |

So the app, its 16-channel open, and BlackHole were all fine — the player was sending
two channels.

### 2.2 Locating the cause

Both an AVFoundation-based player (Elmedia) and `mpv` refused multichannel output on
this device. `mpv -v` printed the reason:

```
[ao/coreaudio] requested format: 48000 Hz, 5.1 channels, floatp
[ao/coreaudio] audio channel layout: tag: <0>, descriptions <16>
[ao/coreaudio] channel label=52 unusable to build channel bitmap, skipping layout
[ao/coreaudio] converted input channel layout (failed)
[ao/coreaudio] result: stereo
```

Players pick their output channel count from the **input device's preferred channel
layout** (`kAudioDevicePropertyPreferredChannelLayout`), and BlackHole had been
configured in Audio MIDI Setup with a *custom 7.1.4* arrangement:

```
[L, R, C, LFE, Ls, Rs, Lrs, Rrs, Unknown, Unknown, Vhl, Vhr, LeftTopRear, RightTopRear, Unknown, Unknown]
```

`kAudioChannelLabel_LeftTopMiddle/RightTopMiddle` (49/51) and
`kAudioChannelLabel_LeftTopRear/RightTopRear` (52/54) have **no channel-bitmap bit**,
and `Unknown` (0xFFFFFFFF) maps to nothing. Any client that builds a channel map from
a bitmap — AVFoundation and FFmpeg both do — fails to convert the layout and silently
falls back to a stereo stream. L/R reach BlackHole; C/LFE/surrounds are never sent.

### 2.3 Proof

Same file, same player, only the device layout changed:

| Input device layout | Elmedia → BlackHole |
| --- | --- |
| custom 7.1.4 (49/51/52/54 + Unknown labels) | **2 ch** (L, R only) — bug reproduced |
| 16-ch 9.1.6 bed with convertible labels | **6 ch** (L, R, C, LFE, Ls, Rs), no bleed |

Per-channel tone analysis with the bed layout installed (frequencies 440/660/880/220/
1320/1760 Hz):

```
ch1 L    dominant=440 Hz   (source L)
ch2 R    dominant=660 Hz   (source R)
ch3 C    dominant=880 Hz   (source C)
ch4 LFE  dominant=220 Hz   (source LFE)
ch5 Ls   dominant=1320 Hz  (source Ls)
ch6 Rs   dominant=1760 Hz  (source Rs)
ch7..16 silent
```

Additional confirmations:

- **7.1 source (AAC):** side pair → channels 5/6, rear pair → channels 7/8, i.e.
  positional mapping still works, nothing collapsed.
- **`OK Jaanu` (E-AC-3 5.1):** all six channels present, C carrying dialogue.
- **`Ae Dil Hai Mushkil` (E-AC-3 5.1):** L, R, C, LFE, Ls, Rs all live.
- **Restoring the old 7.1.4 layout** returned Elmedia to L/R only — the causation is
  reproducible in both directions.

### 2.4 Repairs that were tried and rejected by measurement

These are recorded so nobody repeats them:

| Attempt | Outcome |
| --- | --- |
| Semantically exact 9.1.6 label set (using 49/51/52/54) | HAL accepts it, but Elmedia falls back to stereo again |
| Tag-based `kAudioChannelLayoutTag_Atmos_9_1_6` payload | HAL accepts it (with the width-sized padding), still stereo — the driver normalises it back to generic descriptions |
| Changing Elmedia's "Number of playback channels" only | No effect while the device layout stayed unconvertible |
| Blaming the app / BlackHole / the 16-ch open | Disproved: the same app + BlackHole carried 6 discrete channels from a synthetic client |

**Conclusion:** the channel *count* is not the lever — the *labels* in the device
layout must be convertible.

---

## 3. Changes made

### 3.1 New: `Sources/Downmix/Audio/InputChannelLayout.swift`

Owns the contract between Downmix and client players.

- `bedLabels` — the 16-channel 9.1.6 bed in processor order (L, R, C, LFE, Ls, Rs,
  Lrs, Rrs, Lw, Rw, Ltf, Rtf, Ltm, Rtm, Ltr, Rtr) described with the **closest labels
  every client can convert**:
  `Left, Right, Center, LFEScreen, LeftSurround, RightSurround, RearSurroundLeft,
  RearSurroundRight, LeftWide, RightWide, VerticalHeightLeft, VerticalHeightRight,
  TopCenterSurround, VerticalHeightCenter, TopBackLeft, TopBackRight`.
  The top-middle pair has no bitmap-safe label, so top-centre labels are used there;
  the audible result is identical because this bed of channels is folded into L/R.
- `layoutData()` — builds the `AudioChannelLayout` payload
  (`kAudioChannelLayoutTag_UseChannelDescriptions`, 16 descriptions,
  `12 + 16 × 20 = 332` bytes, which is the only size BlackHole accepts).
- `labels(deviceID:scope:)` — reads the current layout and returns `nil` for a
  different width, a tag-only layout or unreadable data.
- `isInstalled(deviceID:)` — both output and input scopes must match the bed.
- `installIfNeeded(deviceID:channelCount:)` — off-main only; skips a compatible
  layout (never rewrites), writes whichever scope differs, verifies afterwards.
  Returns `nil` for non-16-channel inputs (nothing to do) and `false` when the HAL
  refuses the change.

### 3.2 `Sources/Downmix/Audio/AudioEngine.swift`

- `EngineStatus.bedLayoutInstalled: Bool?` (`nil` = no claim / not applicable,
  `true` = installed and verified, `false` = HAL refused).
- In `start(...)`, right after `validateDevices(...)` and **before** any I/O unit is
  created, the engine calls
  `InputChannelLayout.installIfNeeded(deviceID: inputDeviceID, channelCount: inputChannels)`
  so the next client stream negotiates the full bed. A refusal is logged and reported;
  it never stops rendering.
- `publish(...)` clears `bedLayoutInstalled` for every phase except `running`/
  `keepAlive`, so a stopped run never claims a layout certificate.

### 3.3 `Sources/Downmix/AppState.swift`

- The Setup Checklist's "9.1.6 speaker mapping" item is no longer an unverifiable
  `.manual` instruction. A new `speakerMappingCheck(_:)` reports:
  - running and installed → **Verified** ("reopen a file that was already playing so
    the player re-negotiates every channel"),
  - running and refused → **Needs attention** (pointing at Audio MIDI Setup),
  - not running → **Manual**, explaining that Downmix installs the layout on Start.
- Reading the checklist still performs no HAL work and requests no permission, and no
  check asserts a state the app cannot observe.

### 3.4 `Checks/HAL/StubHAL.swift` + `Checks/HAL/main.swift` + `Scripts/check_hal.sh`

- The stub HAL now models `kAudioDevicePropertyPreferredChannelLayout`
  (read, settable, write, write-failure injection) instead of trapping on any device
  mutation, and still never links the real HAL (the `nm -u` guard is unchanged).
- New `bedLayoutChecks()`: a running engine certifies the layout, both scopes receive
  the bed labels with exactly one write each, a compatible layout is never rewritten,
  a 32-channel input is left alone and makes no claim, and a refused write keeps the
  engine running with `bedLayoutInstalled == false`.
- `Scripts/check_hal.sh` compiles the new source file.

### 3.5 Documentation

- `README.md`: Part 1 still documents Audio MIDI Setup as the manual way to verify or
  reorder the assignment, and now states that Downmix installs the 9.1.6 bed layout on
  every Start; the Setup Checklist description and the "only some speakers" symptom
  were rewritten to describe the real cause (player sent stereo, reopen the file).
- `problem.md`: rewritten as the resolved record (symptom, pipeline, root cause,
  measurements, fix, triage notes).

---

## 4. Verification performed

| Check | Result |
| --- | --- |
| `SDKROOT=…/MacOSX26.5.sdk Scripts/check.sh` | **All checks passed** (DSP, preferences, realtime, transport, HAL incl. new bed-layout checks, clock drift, lifecycle, async control, metering, profiling, release scripts, `swift build`) |
| `swift format lint --strict --recursive Sources Checks Scripts Package.swift` | clean |
| `Scripts/check_whitespace.sh` | clean |
| Reinstall (`SDKROOT=… ./install.sh`) + Start on the affected Mac | device layout was rewritten from the broken 7.1.4 arrangement to `[L, R, C, LFE, Ls, Rs, Lrs, Rrs, Lw, Rw, Ltf, Rtf, Ltm, Rtm, Ltr, Rtr]` |
| Elmedia, 5.1 tone file | device channels 1–6, correct order, no bleed |
| Elmedia, 7.1 tone file | side pair → 5/6, rear pair → 7/8 |
| Elmedia, `OK Jaanu` (E-AC-3 5.1) | 6 channels live, C dominant |
| Elmedia, `Ae Dil Hai Mushkil` (E-AC-3 5.1) | 6 channels live |
| Regression: restore old layout | bug reproduces again, so the fix is the layout install |

Environment note: a bare `swift build` fails on this Mac because the
CommandLineTools SDK 27 install is missing the `SwiftUIMacros` plugin. That is
pre-existing (reproduced on a pristine `HEAD` export) and unrelated to this change;
the repository's check scripts pin `MacOSX26.5.sdk`, and builds succeed with that
`SDKROOT`.

---

## 5. How it behaves now

1. Press **Start** in Downmix. Before audio opens, the input device's 9.1.6 bed layout
   is installed (only if it is not already correct).
2. The Setup Checklist shows **9.1.6 speaker mapping · Verified** for that run.
3. Play (or reopen) the movie in the player. The player reads the convertible layout
   and sends 6 or 8 channels; Downmix's bed shows C/LFE/surrounds and folds them to
   stereo.
4. A player that was already mid-playback keeps its old stereo stream — reopen the
   file, or simply play the next one.

Elmedia's own "Number of playback channels" setting no longer needs to be juggled: with
a convertible device layout the source's channel count drives the stream.

---

## 6. Follow-ups (not done here)

- No version bump (`version.env` still 1.3.1 / build 5) and nothing was committed; the
  existing `Downmix.zip` was not re-packaged.
- If a future bed needs real top-middle/top-rear semantics, a **tag-based** layout would
  be required, and the driver must preserve it — BlackHole currently normalises it.
- Optional hardening: surface `bedLayoutInstalled == false` in the status pill, and
  offer a "Reinstall 9.1.6 layout" action in Settings.
