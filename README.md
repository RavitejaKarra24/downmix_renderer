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
installed speaker layout, Music rate matching, and manual routing
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
Device setup and cleanup run in the background; Stop mutes future callbacks without
waiting for cleanup (already-buffered hardware audio may finish).

After an error, reconnect the saved devices and use **Retry** (⌘⇧R). Retry never picks a
different output automatically. Failure counters remain visible until a new run or an explicit stop.

### Sample rates and 96 kHz files

macOS gives every audio device **one** nominal sample rate at a time, and Music does not
switch it per track. If BlackHole is at 48,000 Hz while you play a 96 kHz file, macOS
converts it to 48 kHz before Downmix ever receives it: Downmix correctly shows 48 kHz, and
it cannot see the file's own rate through Core Audio.

Downmix can follow Music for you. **Settings → Audio → Match Apple Music's track rate**
(on by default) reads the current Music track's rate, sets the **selected input device** to
it, and sets the **selected output device** to the same rate. The whole pipeline — input,
DSP and output — then runs at the same nominal rate, without a fixed 48 kHz conversion.
Small adaptive resampling still compensates for independent device clocks; this is not
bit-perfect playback. Both audio units are recreated for a rate switch so stale device-side
timing cannot cause ongoing dropouts. System routing is never touched.

- The first time it runs, macOS asks whether Downmix may control Music. Allow it in
  **System Settings → Privacy & Security → Automation**; denying it only disables matching.
- Music reports a rate for Apple Music streams and tracks in your library. A file opened
  outside the library may not report one — add the folder to Music
  (**File → Add to Library**, with "Copy files to library" off) to get native-rate playback.
- The DSP runs at the input rate, so a 96 kHz track is downmixed at 96 kHz and the DAC
  receives 96 kHz. If the output device cannot accept the input rate, Downmix renders at
  48 kHz and the status line says **output limit** (an explicit nominal-rate conversion).
- With matching off, set the device rate yourself in **Audio MIDI Setup** (for example
  96,000 Hz); Downmix follows it and sets the output device to match.

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

**It still shows 48 kHz for my 96 kHz files.** Check the Setup Checklist row **Music rate
matching**: it shows the rate Music reported and the input device's current rate. Matching
needs the track to be in the Music library, and it also needs Automation permission. With
matching off, or for another player, set the rate in Audio MIDI Setup yourself. If the
status says **output limit**, the DAC refused the source rate and Downmix fell back to
48 kHz.

**macOS asks whether Downmix may control Music.** That is how the track rate is read. Allow
it in **System Settings → Privacy & Security → Automation**; refusing it only turns off
automatic rate matching.

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
- a heartbeat every 20 seconds while rendering;
- a marker from a pre-opened file descriptor if the process dies on a fatal signal.

The log rotates at 512 KB and keeps two older files (`downmix.1.log`, `downmix.2.log`).
Open it from **Transport → Show Diagnostic Log**, **Advanced → Show diagnostic log**, or
**Settings → Advanced → Diagnostics**. Logging failures never interrupt audio.

## Privacy

Downmix processes audio entirely on your Mac. It has no network code and sends nothing
anywhere. It changes two system audio settings only when **Match Apple Music's track rate**
is on: the **selected input and output devices'** nominal sample rates, so both follow the
track. It never changes the default output or your routing — you choose those yourself in
System Settings. Its own settings live in a single file at
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

- Passthrough: the DSP runs at the input device's rate (8–768 kHz); the output device and
  client format follow it, so 44.1/48/96/192 kHz sources are not resampled. 48 kHz is the
  fallback when the output device refuses the rate.
- Optional input-device rate matching from Music's current track (AppleScript, opt-out in
  Settings); it sets both the input and output device rates.
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
- Automatic rate matching reads Music only. Other players report no rate, so use Audio MIDI
  Setup (or a switcher) for those; Downmix still follows whatever rate they set.
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
