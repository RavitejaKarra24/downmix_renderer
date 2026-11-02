# Downmix

Downmix takes spatial 9.1.6 audio — the kind Apple Music and streaming apps send to a
surround system — and folds it down to clean stereo for your headphones or speakers,
in real time.

- **Just want to use it?** Read [Install and use](#install-and-use).
- **Want to read or change the code?** Read [For developers](#for-developers).

Requirements: macOS 15 or later, on Apple silicon or Intel.

---

# Install and use

Downmix needs a helper called **BlackHole** to hear the surround audio. Part 1 sets that
up. You only do parts 1 and 2 once.

## Part 1 — Set up BlackHole

BlackHole is a free, open-source audio driver. macOS has no built-in way to hand
16 channels of audio from one app to another, so this fills that gap.

1. Go to [existential.audio/blackhole](https://existential.audio/blackhole/) and download
   **BlackHole 16ch**. (The site asks for an email address; the download link arrives by
   mail. There is also a free download on its
   [GitHub releases page](https://github.com/ExistentialAudio/BlackHole/releases) if you
   would rather skip that.)
2. Open the downloaded installer and follow its steps. It will ask for your password —
   installing an audio driver requires it.
3. Restart your Mac.
4. Open **Audio MIDI Setup** (press <kbd>⌘</kbd><kbd>Space</kbd>, type its name, press Return).
5. Select **BlackHole 16ch** in the list on the left.
6. Click **Configure Speakers**.
7. Set the arrangement to **9.1.6** and make sure channels **1 through 16** are assigned.
   Click **Apply**, then **Done**.

Downmix also installs this 9.1.6 bed layout on the selected input device each time you
press **Start**, so players deliver every bed channel instead of a stereo fallback. The
manual steps above are only needed to check or reorder the assignment yourself; the
**Setup Checklist** shows whether the installed layout was accepted.

## Part 2 — Install Downmix

**Before you start:** macOS will show a security warning the first time you open Downmix.
This is expected. It means the app has not paid for Apple's notarization service, not
that anything is wrong with it. Steps 4 through 7 walk you through it, and you only do
this once.

1. [**Download Downmix.zip**](https://github.com/RavitejaKarra24/downmix_renderer/raw/main/Downmix.zip).
2. Open your **Downloads** folder and double-click **Downmix.zip**. A **Downmix** app icon
   appears next to it.
3. Drag **Downmix** into your **Applications** folder.
4. Double-click **Downmix**. A dialog appears saying *"Apple could not verify 'Downmix' is
   free of malware that may harm your Mac or compromise your privacy."* Click **Done**.
   (Do **not** click "Move to Trash".)
5. Open **System Settings** → **Privacy & Security**. Scroll down to the **Security**
   section near the bottom. You will see a line saying *"Downmix" was blocked to protect
   your Mac.* Click **Open Anyway** next to it.
6. Confirm with Touch ID or your password.
7. One more dialog appears. Click **Open Anyway**.
8. When you first click **Start**, Downmix asks for **microphone access**. Click **Allow**.
   macOS classes every audio input as a microphone, and Downmix needs to open BlackHole
   as an input to hear your audio.
   Nothing is recorded and no sound is sent anywhere.

From now on, Downmix opens normally with a double-click.

> If **Open Anyway** is not in System Settings, try opening Downmix again first. macOS only
> shows the button for a few minutes after a blocked launch.

## Where Downmix appears

Downmix opens a window, puts an icon in your Dock, and adds a small **level meter to your
menu bar** at the top right of the screen. Closing the window does not quit the app — the
menu-bar meter stays, and clicking it brings back the controls.

## Using it

1. Open Downmix.
2. Set **Input** to **BlackHole 16ch**.
3. Set **Output** to your headphones or speakers.
4. Leave **Preamp** at **-9.5 dB** to start. Lower it if the sound distorts.
5. Click **Start**. The meters begin moving when audio is playing.
6. In **System Settings → Sound → Output**, choose **BlackHole 16ch** so your Mac sends its
   audio through Downmix.

To stop, click **Stop** in Downmix and set your Sound output back to your headphones or
speakers.

If your device list is long, use the filter box. You can pin the devices you use most from
their right-click menu and drag them into the order you like.

**Setup Checklist** explains the selected devices, their live sample rates, permission, the
installed speaker layout, sample-rate policy, and manual routing
requirements. Device rates do not have to be 48 kHz: Downmix follows the input device's
rate, runs its DSP at that rate, and sets the output device to match — so 44.1 kHz in goes to
the DAC at 44.1 kHz, 96 kHz at 96 kHz. Apple Music moving BlackHole between 44.1, 48 and
96 kHz no longer stops rendering; a brief re-prime follows the switch. **Advanced** shows
buffer negotiation and current-run diagnostics. Queue latency
is only the audio waiting inside Downmix, not your total listening latency.
Small differences between the two device clocks are corrected automatically.
This uses a reservoir of at least **42.7 ms**, increasing with larger device buffers;
initial priming is silent. Rates between 8 kHz and 768 kHz are accepted; the DSP and the
output device run at the input rate whenever the DAC accepts it (48 kHz otherwise).
Downmix also sets the DAC's **bit depth** at that rate. In **Settings → Audio → DAC bit
depth**: **Match source** (default) uses the playing file's own depth (16/24-bit) whenever
Automatic can read it — from the open file's header or a decoder record — or the nearest
deeper depth the DAC offers; lossy files, browsers and unknown sources get the deepest.
**Deepest available** always uses the deepest (e.g. 32-bit integer), which keeps every bit of
the 32-bit float mix; at 16-bit the preamp-scaled mix is rounded to 16 bits. A DAC that
refuses the change keeps its own format; the **Signal path → DAC** row shows the depth in use.
Device setup and cleanup run in the background; Stop mutes future callbacks without
waiting for cleanup (already-buffered hardware audio may finish).

After an error, reconnect the saved devices and use **Retry** (⌘⇧R). Retry never picks a
different output automatically. Failure counters remain visible until a new run or an explicit stop.

### Any player: routing and sample rates

Downmix accepts decoded PCM from **any app routed to its selected input**: Kew, Music,
Spotify, browsers, YouTube Music and other local/streaming players.

1. Select **BlackHole 16ch** as Mac Sound output, or as the player's own output device.
2. Select BlackHole as Downmix input and your physical DAC/headphones as Downmix output.
3. Start Downmix. Do not select BlackHole as Downmix output; that could create feedback.
   Downmix never changes your default system output or an app's routing.

**Settings → Audio → Sample rate** provides three modes:

| Mode | Behavior |
|---|---|
| **Automatic** | For every app routed to the input: fresh decoder-input logs, then the header of the audio file a local player has open, then a rate you saved for that app, then Music track metadata. Never guesses an app's default rate. |
| **Follow input** | Never requests an input-rate change; DSP and output follow the captured device PCM. |
| **Fixed** | Requests your chosen input rate while rendering, for any player. The selected output follows when supported. |

Automatic reads public Core Audio process activity on a utility queue and collects a rate
claim from each routed app. A browser tab or paused player that merely holds a silent
stream claims nothing, so it no longer blocks Music or another app that does. If exactly one
rate is claimed, the input switches to it; if two apps claim different rates, or nothing is
claimed, or discovery fails, the current rate is held and the Sample-rate panel says why.
Activity means running output IO, not proof of audible content; polling and a short
settling delay make this best-effort rather than an atomic per-track guarantee.

**Local files (Kew, Elmedia, VLC, IINA…).** For each routed app, Downmix lists the audio
files it has open (public `libproc`, same-user processes only) and reads the playing file's
header through Core Audio: its real sample rate, bit depth and channel count. WAV, AIFF, CAF,
FLAC, ALAC/AAC (M4A/MP4/MOV) and MP3 are read; MKV/WebM/Opus/DSD are not. When a gapless
player opens the next track early, the track whose read position is advancing (or, failing
that, the one already playing) stays current; files that disagree with no way to tell which
is playing hold the rate. Nothing is logged except the format, and file contents beyond the
header are never read. Something playing now (a file being read, a decoder log, Music's
current track) outranks another app's saved rate; a paused file does not.

**Saved app rates.** Browsers and Spotify expose no rate Downmix can read: YouTube and
other web audio is decoded and resampled inside the browser before macOS sees it (YouTube is
almost always 48 kHz Opus). In
**Settings → Audio → Sample rate**, every routed app has a rate menu: pick a rate, or choose
**Use current rate** to save the rate the input is running at right now. Automatic then
applies that rate whenever the app is routed and no other app claims a different one. This
is your declaration, not detection: a saved 96 kHz rate makes a 44.1 kHz file play at 96 kHz
(upsampled by the player/Core Audio). Fresh decoder evidence for the same app always wins
over its saved rate.

**Decoder-input Auto** reads recent local unified logs for each routed client's PID (up to six
clients). It currently recognizes a narrowly defined explicit ALAC decoder input
diagnostic—not generic AudioQueue/client/device formats or arbitrary numbers labelled Hz.
Evidence expires after four seconds; stale, conflicting, unavailable or missing records
hold the rate. Once an app has produced decoder evidence, expiry holds the rate rather than
falling back to that app's saved rate or older Music metadata. A new client starts with only a 1.5-second overlap, and switches settle
briefly before dispatch. Downmix/coreaudiod output logs cannot confirm themselves.
OSLog access can be restricted; players may emit no usable decoder logs, even while audio
works. Source names alone never trigger 44.1/48/96 kHz guesses.

**Music metadata** is opt-out and read whenever Music is one of the routed clients; a paused
Music claims nothing. macOS may ask for Automation permission. A denied prompt, paused Music or missing
metadata never stops audio. Music's reported rate can change while a streaming track loads;
it is reported metadata, not independent proof of the original encoded stream's format.

**Kew on this Mac (4.4.2)** has no verified public current-file/source-Hz interface.
Its macOS Now Playing fields do not expose those values, and playback speed is not Hz.
Kew's open FLAC/WAV/MP3 files are read directly (see Local files above), so Kew switches
automatically; a saved app rate is only a fallback for files Downmix cannot read. Downmix does not guess from titles, open files, persistent IDs,
private APIs or app defaults. Browser/Spotify original rates may likewise remain unknown.

The **Signal path** panel separates the discovered app, reported source rate, captured PCM,
DSP rate and selected output's nominal-rate snapshot. A 96 kHz file played into a 44.1 kHz
device may already be resampled by the player/Core Audio. Downmix then receives 44.1 kHz:
setting the DAC to 96 kHz afterward cannot recover the original signal.

For a known local 96 kHz file, select Fixed **96 kHz** (or configure a player that switches
BlackHole itself). For a 48 kHz file, use **48 kHz** instead; blindly selecting 96 kHz would
not make it native 96 kHz audio. Stereo/5.1/7.1 channel count is independent of rate and bit
depth. BlackHole's 16ch capacity does not establish the file's channel count.

DSP normally runs at the captured rate. An unsupported DAC rate produces an explicit
**output limit** fallback. Adaptive resampling still corrects independent device clocks;
downmix/gain/filtering also alter samples, so matching nominal rates is not bit-perfect
playback. Rate changes recreate both audio units and briefly re-prime the queue.

## Updating

Download the zip again, drag the new **Downmix** into **Applications**, and click **Replace**
when asked. There is no automatic updater — the version number is shown in
**Downmix → About Downmix**, so you can check what you are running.

Two things to expect after an update:

- The security steps 4 through 7 may repeat. That is normal for an app distributed this way.
- macOS may ask for microphone access again. Click **Allow**.

## Uninstalling

1. Quit Downmix.
2. Drag **Downmix** from **Applications** to the Trash.
3. Optional: in Finder press <kbd>⌘</kbd><kbd>⇧</kbd><kbd>G</kbd>, enter
   `~/Library/Application Support/`, and delete the **Downmix** folder. That is where your
   settings are stored.

BlackHole is a separate program with its own uninstaller; removing Downmix leaves it in
place.

## Troubleshooting

**Nothing happens when I double-click the app.** You are probably still at the security
step. Go back to steps 4 through 7 above.

**The meters never move.** Your Mac is not sending audio to Downmix. Check that
**System Settings → Sound → Output** is set to **BlackHole 16ch**, and that **Input** in
Downmix is also **BlackHole 16ch**.

**I hear nothing at all.** Check that **Output** in Downmix is your actual headphones or
speakers, and that Downmix says **Stop** (meaning it is running) rather than **Start**.

**The sound is distorted or crackly.** Lower the **Preamp** value. If it still crackles,
raise the buffer size in **Settings**.

**Only some speakers seem to be coming through.** If only L and R move in Downmix, your
player sent a stereo stream — it uses the input device's speaker layout to choose its output
channel count, and a layout it cannot convert makes it fall back to stereo. Press **Start** in
Downmix (it installs the 9.1.6 bed layout) and reopen the file, or play the next file; a player
that was already playing keeps its old stereo stream until it reopens the device. If it still
happens, set **9.1.6** in **Audio MIDI Setup → Configure Speakers** and restart the player.

**Left and right are swapped.** Turn on **Swap L/R** in **Settings**.

**It stopped working after I unplugged my headphones.** Downmix stops rather than silently
switching outputs. Reconnect your saved device or select another output, then click **Start**.
Saved device selections are retained while disconnected.

**It says settings could not be saved.** Use **Retry Save** in the window, Settings, or
menu controls after correcting the file/access problem. This saves settings only; it
does not start audio. Audio-route **Retry** is separate.

**It says microphone access is required.** Enable **Downmix** in **System Settings →
Privacy & Security → Microphone**, then retry **Start**.

**A rate switch made the sound drop out briefly.** When Music rate matching (or another
sample-rate switcher, or you in Audio MIDI Setup) changes the input device's rate, Downmix
reopens the input and output at the new rate and continues rendering. The output keeps
playing buffered audio and then re-primes for roughly a quarter of a second. A track change
hides this gap.

**It shows 44.1/48 kHz for my 96 kHz file.** Read the Signal path panel. Capture reports
device PCM, not a file header. For a known local file, select Fixed at the file's actual
rate, or let a rate-switching player configure BlackHole. Automatic cannot discover every
browser/stream/file rate; unknown sources hold the current rate. An **output limit**
means the DAC could not accept the captured rate.

**macOS asks whether Downmix may control Music.** That permits the optional Music metadata
adapter. Refusing it leaves audio and the Follow input/Fixed modes working. Automatic
does not use Music to guess another app's source rate.

**It says the input or output rate is not supported.** Rates from 8 kHz to 768 kHz are
accepted. Set the device to a normal rate such as 44,100 or 48,000 Hz in **Audio MIDI
Setup**, then press **Start** again.

**Something went wrong and I want details.** Open **Transport → Show Diagnostic Log** (or
**Advanced → Show diagnostic log**). Nothing is uploaded; the file stays on your Mac.

## Diagnostic log

Downmix keeps a local log at `~/Library/Logs/Downmix/downmix.log`. It records:

- session start and clean exit, so the next launch can report whether the previous session
  ended abruptly (crash, forced quit or power loss);
- every failure with the run's counters (buffer sizes, underruns, overruns, rejected slices,
  render errors, rebuffers, queued frames);
- device selections and their sample rates, including rate changes;
- routed audio-client app names and automatic/fixed rate requests;
- a heartbeat every 20 seconds while rendering;
- a marker from a pre-opened file descriptor if the process dies on a fatal signal.

The log rotates at 512 KB and keeps two older files (`downmix.1.log`, `downmix.2.log`).
Open it from **Transport → Show Diagnostic Log**, **Advanced → Show diagnostic log**, or
**Settings → Advanced → Diagnostics**. Logging failures never interrupt audio.

## Privacy

Downmix processes audio entirely on your Mac. It has no network code and sends nothing
anywhere. While rendering it may change the selected input's nominal rate in Automatic
or Fixed mode; the selected output follows the captured/DSP rate when supported, in all
modes. It never changes default system output or app routing. Source discovery reads
public process/device activity and app identity, not browser tabs, cookies or source files.
In Automatic mode it reads narrowly filtered recent audio logs for the sole routed client;
raw messages are not retained or uploaded. Music metadata requires macOS Automation permission. Its settings live at
`~/Library/Application Support/Downmix/preferences.json`; its diagnostic log stays in
`~/Library/Logs/Downmix/`.

---

# For developers

Native macOS **9.1.6 → stereo** downmixer. A clean-room rebuild of
[peqdb/macos Downmix Renderer](https://github.com/peqdb/macos) with:

- **SwiftUI** interface (no Python, no WebKit, no localhost server)
- **Core Audio** dual-device engine
- ADC2-direct bed matrix + Butterworth LFE path
- Ballistic 9.1.6 activity meters with peak hold and stereo dBFS grid
- Adaptive Light/Dark appearance, native materials, and an inline menu-bar meter
- Low idle CPU (audio runs only when started)

## Clone, build, run

Requires the Xcode Command Line Tools (`xcode-select --install`) and Swift 6.2 or later.
Use a complete stable macOS SDK; the local macOS 27 beta Command Line Tools currently lack a
SwiftUI macro plugin. If affected, select an installed stable SDK with `SDKROOT` as shown in
[future.md](future.md).

```bash
git clone https://github.com/RavitejaKarra24/downmix_renderer.git
cd downmix_renderer
./install.sh          # builds, installs to ~/Applications, launches
```

`OPEN_APP=0` installs without launching; `INSTALL_DIR=/path/to/apps` overrides the
destination.

## Everyday commands

```bash
Scripts/check.sh              # formatting/shell/build and deterministic source/archive regressions
Scripts/check_release.sh      # additionally requires rendered native UI; desktop session required
Scripts/verify_archive.sh     # read-only signature, universal metadata and build-input digest check
Scripts/check_realtime.sh --tsan        # concurrent mailbox tests with Thread Sanitizer
Scripts/check_audio_transport.sh --tsan # callback safety/counter tests with Thread Sanitizer
Scripts/check_clock_drift.sh --tsan     # offline resampler/clock checks with Thread Sanitizer
Scripts/check_hal.sh --tsan             # actual engine with isolated HAL API stubs, no real devices
Scripts/check_metering.sh               # native reset/ballistics and settled repaint timer checks
Scripts/check_ui.sh --rendered          # native AX/action checks; fake backend, desktop session required
Scripts/compile_and_run.sh    # package ad-hoc signed .app and relaunch
Scripts/package_app.sh release  # build the .app only
Scripts/package_zip.sh        # build universal, sign, archive, re-verify Downmix.zip
```

A locally built app is never quarantined, so you will not see the Gatekeeper prompt that
the install section describes. To reproduce what a user sees, download the zip from GitHub
on another machine or a fresh user account.

## Layout

| Path | What it is |
|---|---|
| `Sources/Downmix/DownmixApp.swift` | App entry point: main window, Settings, menu-bar extra |
| `Sources/Downmix/AppState.swift` | Observable app state, start/stop, meter plumbing |
| `Sources/Downmix/Audio/AudioEngine.swift` | Serial-queue dual-device Core Audio worker |
| `Sources/Downmix/Audio/AsyncAudioEngineController.swift` | Main-actor intent, cancellation and stale-delivery filtering |
| `Sources/Downmix/Audio/AdaptiveStereoResampler.swift` | Preallocated sinc reconstruction and adaptive clock correction |
| `Sources/Downmix/Audio/DeviceManager.swift` | Device enumeration and change notifications |
| `Sources/Downmix/Audio/RingBuffer.swift` | Lock-free buffer between input and output callbacks |
| `Sources/Downmix/Audio/RealtimeMailbox.swift` | Preallocated POD configuration/meter transport |
| `Sources/Downmix/Audio/AudioDiagnostics.swift` | Atomic per-run callback counters |
| `Sources/Downmix/Audio/StereoOutputRenderer.swift` | Byte-bounded stereo playback/silence and underrun accounting |
| `Sources/Downmix/DSP/DownmixProcessor.swift` | Bed matrix, LFE path, preamp |
| `Sources/Downmix/DSP/Biquad.swift` | Butterworth sections |
| `Sources/Downmix/Models/` | Bed layout, device info, persisted preferences |
| `Sources/Downmix/UI/` | SwiftUI views, meters, theme |
| `Checks/main.swift` | DSP and stereo ring-buffer regression checks |
| `Checks/Preferences/`, `Checks/Lifecycle/` | Isolated preference, setup/retry/diagnostics and transport/device lifecycle checks |
| `Checks/Realtime/`, `Checks/AudioTransport/` | POD mailbox/DSP concurrency and output-buffer safety checks |
| `Checks/ClockDrift/`, `Checks/AsyncControl/`, `Checks/UI/` | Offline clocks, delayed control/catalog, native hosted/rendered UI checks |
| `Checks/HAL/`, `Checks/Metering/`, `Checks/Release/` | Isolated actual-engine safety/lifetime, native meter/timer and failure-gated archive regressions |
| `docs/profiling.md`, `docs/ui-validation.md` | Runtime profiling and automated/manual UI qualification |
| `.github/workflows/check.yml` | Stable macOS lint/build/regression/sanitizer CI |
| `todo.md` | Active checklist: completed engineering, remaining qualification and stopped scope |
| `future.md` | Original engineering plan and historical implementation/verification record |
| `Scripts/` | Build, package, icon, and check scripts |
| `version.env` | `CFBundleShortVersionString`, bundle ID, min OS |
| `Downmix.zip` | The committed download artifact (see below) |

## Distribution model

Downmix is **ad-hoc signed** (`codesign --sign -`) and shipped as a zip committed at the
repo root. There is no Developer ID and no notarization, because both require a paid
$99/year Apple Developer membership. That is a deliberate trade-off, not an oversight —
please don't add notarization steps to the build scripts, as they cannot be run.

The consequence is the one-time Gatekeeper detour documented in the install section, and
that macOS may re-prompt for microphone access after an update, since TCC grants are tied
to a code signature that changes with every ad-hoc build.

`Scripts/package_zip.sh` is the only supported way to regenerate the download. It builds a
universal binary, ad-hoc signs it, verifies the signature, archives with
`ditto -c -k --keepParent` — never `zip`, which drops the metadata the signature depends on
and produces an app that silently fails to launch — then unpacks its own output to a temp
directory and re-verifies there. Packaging requires the rendered native UI gate and a logged-in
macOS desktop session. The extracted app must match the expected version/build, bundle ID,
minimum OS, microphone permission text and both architectures. A signed `SourceDigest` records
current Swift/build inputs (including uncommitted files); stale downloads fail local/CI
verification. This is a stale-artifact guard, not independent build provenance or hardware qualification.

When making a user-facing change: bump `MARKETING_VERSION` in `version.env`, run
`Scripts/package_zip.sh`, and commit the regenerated `Downmix.zip` in the same commit. Git
will not warn you about a stale artifact. If the app ever outgrows ~10 MB, move the zip to
GitHub Releases instead of committing it.

## DSP notes

- DSP runs at the captured input rate (8–768 kHz); the output device/client follow it
  without a fixed-48-kHz conversion when supported. Adaptive clock resampling remains.
  Unsupported output rates use the explicit 48/44.1 kHz fallback.
- Player-independent Follow input and Fixed modes; conservative Automatic uses supported
  decoder-input log evidence or Music metadata only for an exclusive routed client. No
  app-default heuristics or generic device-format inference.
- Bed order: `L R C LFE Ls Rs Lrs Rrs Lw Rw Ltf Rtf Ltm Rtm Ltr Rtr`
- Center: `-3 dB` to both sides (`0.7071`)
- Surround/height: hard-panned L/R
- LFE: fixed ADC2 coefficient `2.26464431`, optional 125 Hz 4th-order Butterworth + 172-sample dry delay
- Output order: matrix + master preamp → optional L/R swap

## Efficiency vs original

| Original | Downmix |
|---|---|
| Python + pywebview + WebKit | Native SwiftUI |
| Local HTTP + SSE status | Direct in-process meters |
| Always-on launcher stack | Audio stopped unless rendering/keep-alive; settled meter repaint timers sleep |
| Web meter relayout | Native AppKit meter surface |
| Default 64-frame buffer | Default **128** frames |

An earlier build measured about **1% CPU minimized while rendering**, and **0% settled CPU
when stopped** on the development Mac. The new mailbox/diagnostics release has not yet been
hardware-profiled; see [profiling instructions](docs/profiling.md) rather than assuming the same numbers.

## Limitations

- Input rates outside 8–768 kHz are rejected. A live rate or channel-width switch reopens
  both units, which costs a brief (~0.25 s) audible gap while the reservoir re-primes.
- Input devices narrower than 16 channels render only the bed slots they expose.
- Original rates are unknown for many players/streams. Automatic supports strict ALAC
  decoder-input diagnostics and Music metadata; Fixed/Follow input work for every routed player. Public HAL discovery can
  report silent running clients or miss a transient between polls, so matching is best-effort.
- Configuration/meters now use preallocated POD mailboxes instead of a shared DSP lock.
  Off-main setup/teardown and bounded independent-device clock correction are implemented.
  Runtime Instruments/CPU profiling and hardware qualification remain pending in
  [todo.md](todo.md); all-day dropout-free playback is not yet certified.
- Changing devices or buffer size restarts the active route; a brief interruption is expected.
- Requires BlackHole 16ch configured as 9.1.6; no other virtual device is detected specially.
- No auto-update mechanism.
- Equalization is out of scope. To add it, run **EQ for Mac** after Downmix: keep BlackHole
  as the macOS default, select a physical stereo output in Downmix, then toggle EQ for Mac
  on. It uses a device-scoped tap on Downmix's saved physical output, so it no longer mutes
  or collapses the 16-channel BlackHole feed.

## License

Personal experiment. Not affiliated with peqdb.
