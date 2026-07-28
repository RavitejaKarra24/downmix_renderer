# Downmix

Native macOS **9.1.6 → stereo** downmixer and parametric EQ.

A clean-room rebuild of [peqdb/macos Downmix Renderer](https://github.com/peqdb/macos) with:

- **SwiftUI** interface (no Python, no WebKit, no localhost server)
- **Core Audio** dual-device engine
- ADC2-direct bed matrix + Butterworth LFE path
- Structured global + speaker PEQ with a live response preview and raw Equalizer APO import
- Ballistic 9.1.6 activity meters with peak hold and stereo dBFS grid
- Adaptive Light/Dark appearance, native materials, and an inline menu-bar meter
- Low idle CPU (audio runs only when started)

## Requirements

- macOS 15+
- [BlackHole 16ch](https://existential.audio/blackhole/)
- In **Audio MIDI Setup**, configure BlackHole 16ch as **9.1.6** with channels 1–16

## Build & run

```bash
# package ad-hoc signed .app and launch
Scripts/compile_and_run.sh
```

Or:

```bash
swift build -c release
Scripts/package_app.sh release
open Downmix.app
```

## Usage

1. Allow microphone access when prompted (required to open input devices).
2. Select **BlackHole 16ch** as input and your stereo DAC/headphones as output.
3. Adjust preamp (default **-9.5 dB**).
4. Press **Start**.
5. Optionally open **EQ / Profiles** to edit filters visually, inspect the response curve,
   manage profiles, or import raw Equalizer APO text.

Device cards can be filtered when the list is long. Pin devices from their context menu,
then drag pinned devices into the order you use most.

## DSP notes

- Sample rate locked to **48 kHz**
- Bed order: `L R C LFE Ls Rs Lrs Rrs Lw Rw Ltf Rtf Ltm Rtm Ltr Rtr`
- Center: `-3 dB` to both sides (`0.7071`)
- Surround/height: hard-panned L/R
- LFE: fixed ADC2 coefficient `2.26464431`, optional 125 Hz 4th-order Butterworth + 172-sample dry delay
- EQ order: matrix + master preamp → global PEQ → L/R swap → speaker EQ

## Efficiency vs original

| Original | Downmix |
|---|---|
| Python + pywebview + WebKit | Native SwiftUI |
| Local HTTP + SSE status | Direct in-process meters |
| Always-on launcher stack | **0% settled CPU** when stopped |
| Web meter relayout | Native AppKit meter surface |
| Default 64-frame buffer | Default **128** frames |

Measured on the development Mac: about **1% CPU minimized while rendering**, and **0% settled CPU when stopped**.

## License

Personal experiment. Not affiliated with peqdb.
