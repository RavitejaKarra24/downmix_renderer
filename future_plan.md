# Downmix — Future Plan

This document captures ideas for improving the app going forward: a UI/visual
redesign (current look is flat, low-contrast, and generic "AI dark mode"),
plus a backlog of features that would make the app more useful. Nothing here
is committed — treat it as a menu to pull from.

Current UI surfaces, for reference:
- `Sources/Downmix/UI/ContentView.swift` — main window (device pickers, controls, meters)
- `Sources/Downmix/UI/EQEditorView.swift` — EQ / profiles sheet
- `Sources/Downmix/UI/MenuBarView.swift` — menu bar extra + Settings
- `Sources/Downmix/UI/Components/*` — device picker rows, AppKit meter canvas
- `Sources/Downmix/UI/Theme.swift` — color tokens

---

## 1. Why the current UI feels ugly

- **Theme.swift is a flat, arbitrary palette.** `bg`, `card`, and `accent` are
  hand-picked RGB triples with no relationship to each other (no consistent
  hue, no tonal ramp, no semantic naming beyond good/warn/bad). It reads as
  "default dark mode" rather than a designed product.
- **Everything is the same card.** Every panel uses the identical
  16pt-radius/1px-stroke card recipe (`ContentView.card`, `EQEditorView.card`,
  `DevicePickerCard.cardBackground`). No visual hierarchy between primary and
  secondary surfaces — it's flat and same-weight throughout.
- **No use of native macOS materials.** Nothing uses `.ultraThinMaterial`,
  vibrancy, or `NSVisualEffectView`, so the window looks like a web app
  ported to macOS rather than a native Core Audio utility.
- **Typography is default system sizes with no real type scale.** Headline,
  callout, caption are used ad hoc; there's no consistent rhythm (e.g. a
  defined 11/12/13/15/20/28 scale with matched line-heights and tracking).
- **The AppKit-drawn meter canvas (`NativeMeteringView`) hardcodes its own
  copy of the color palette** (duplicated literal RGB values instead of
  referencing `DownmixTheme`), so theme changes won't even propagate there.
- **Low color differentiation for state.** Running/stopped/error/keep-alive
  all reuse the same accent-blue-or-gray look; nothing distinguishes "armed
  and monitoring" from "actually rendering audio."
- **No light appearance support** — `.preferredColorScheme(.dark)` is forced
  everywhere, ignoring system appearance.

---

## 2. Visual redesign plan

### 2.1 New color system
Replace the arbitrary literals in `Theme.swift` with a proper token system:

- **Base neutrals**: pick one hue (e.g. a cool graphite ~`hsl(222, 14%, N%)`)
  and derive a 6–8 step tonal ramp (bg → surface → surface-raised → stroke →
  text-secondary → text-primary) instead of unrelated one-off colors.
- **Single accent hue with tints**: keep one signature accent (could stay
  blue, or move to something less "default AI app," e.g. a warm amber or
  teal that pairs well with audio/broadcast gear aesthetics) and derive
  hover/pressed/soft/on-accent variants from it programmatically
  (`Color.accent.opacity(...)` is already half-doing this — formalize it).
- **Semantic-only usage**: good/warn/bad/clip should be reserved strictly for
  status and never used decoratively, so they stay meaningful.
- **Channel-family colors**: bed/height/LFE colors should be distinct enough
  at a glance (currently LFE-orange vs. height-purple vs. bed-blue is fine,
  but should be centralized so `NativeMeteringView` doesn't hardcode its own
  copies — pass `NSColor` bridges from `DownmixTheme` instead of duplicating
  literals).
- **Support Light + Dark**: define the ramp using semantic asset colors (or
  computed values keyed off `colorScheme`) instead of one hardcoded dark set,
  and drop the forced `.preferredColorScheme(.dark)`.
- Consider running the `brand-design` or `design-taste` skill to generate/
  validate a real palette instead of hand-picking hex values again.

### 2.2 Materials & depth
- Use `.background(.ultraThinMaterial)` / `NSVisualEffectView` for the main
  window chrome and the EQ sheet so it feels like a native Core Audio /
  Audio MIDI Setup–style utility instead of a flat-colored rectangle.
- Introduce **two card elevations**: a recessed "well" style (for
  meters/visualizer, PEQ text boxes) vs. a raised "panel" style (for controls),
  rather than one card style used everywhere.
- Add soft directional shadows (not just a 1px stroke) to raised panels for
  real depth.
- On macOS 26 (Tahoe), evaluate adopting **Liquid Glass** materials for
  toolbars/sheets if/when the minimum OS version is raised — see the
  `macos-settings-ui` and `macos-design-guidelines` skills for the current
  HIG guidance.

### 2.3 Typography
- Define an explicit type scale (e.g. Title 28/Headline 15/Body 13/Caption
  11/Label 10) with consistent weights and apply it everywhere instead of
  mixing `.system(size: 28, weight: .bold, design: .rounded)`,  `.headline`,
  `.callout`, `.body`, `.caption` inconsistently.
- Use tabular/monospaced digits everywhere numbers change live (preamp dB,
  meter readouts) — already partly done, extend consistently.
- Give the wordmark ("Downmix") a bit more personality: letter-spacing,
  maybe a small waveform glyph integrated into the title lockup.

### 2.4 Iconography & branding
- Replace ad hoc SF Symbols (`waveform.circle`, `headphones`) with a
  considered icon set — one accent-tinted symbol style, consistent weight
  (`.medium`/`.semibold`), consistent size grid.
- Design a real app icon story consistent with the in-app palette (check
  `Icon.icns` against the new theme once colors are finalized).
- Add a subtle animated waveform/level glyph in the menu bar icon that
  actually reflects output level instead of a static running/stopped glyph.

### 2.5 Component-level redesign

**Header / transport**
- Replace the plain capsule Start/Stop button with a more tactile control:
  pressed-state scale/opacity animation, and a colored glow ring while
  running (subtle, not the current fixed `.shadow` only on the dot).
- Animate the status pill color/label transition (`.animation(_:value:)`)
  instead of an instant color snap.

**Device picker cards**
- Add device icons (built-in mic/speaker vs. aggregate vs. BlackHole) instead
  of a plain colored dot.
- Add inline "connected/disconnected" and sample-rate/channel-count badges.
- Add search/filter for long device lists.
- Add drag-to-reorder "favorite devices" so the most-used input/output float
  to the top.

**Render controls card**
- Turn the preamp control into a proper labeled slider with tick marks at
  0 dB / -9.5 dB (documented default) and a draggable numeric field, not just
  a bare `Slider` + text.
- Group toggles (LFE lowpass, swap L/R, keep-alive) under a visually distinct
  "DSP options" sub-section instead of a flat list of `Toggle`s.
- `DisclosureGroup("Advanced")` should get a chevron rotation animation and a
  divider so it doesn't feel bolted on.

**Meter / bed visualizer (`NativeMeteringView`)**
- This is the app's centerpiece and currently the least polished part —
  it's a manually drawn AppKit canvas with hardcoded colors and no
  animation/interpolation (levels just snap frame to frame). Priorities:
  - Interpolate meter values (attack-fast/release-slow ballistics) instead of
    snapping directly to the latest sample, so it reads like a real meter.
  - Add peak-hold indicators (small line that hangs briefly at the recent
    peak) for both the bed dots and the L/R bars.
  - Add a dB scale/gridlines to the stereo meter bars (e.g. -60/-40/-20/-6/0).
  - Give the bed layout real speaker-plan proportions (front arc wider than
    rear, height row visually elevated) instead of a generic circular
    scatter, so it reads as "9.1.6 room" at a glance.
  - Pull colors from `DownmixTheme` via `NSColor` bridging instead of
    duplicating literal RGB triples in `NativeMeteringView`.
  - Consider replacing the custom `NSView` draw loop with a `Canvas`/
    `TimelineView` SwiftUI implementation for animation easing, falling back
    to AppKit only if perf requires it.

**EQ editor**
- Replace the raw multi-line `TextEditor` PEQ boxes with a structured filter
  list UI (rows of type/freq/gain/Q with steppers) while keeping a
  "raw text" import/export escape hatch — most users don't want to
  hand-edit Equalizer APO syntax.
- Add a live frequency-response curve preview (simple `Path`/`Canvas` plot)
  above each PEQ box so changes are visually verifiable before committing.
- Profile picker: add rename, duplicate, and reorder; show a "modified since
  saved" indicator so users don't lose edits silently.

**Menu bar / Settings**
- Menu bar view is plain text rows — add the live L/R meter as a tiny inline
  bar, and use `Label`s consistently with icons for scannability.
- Settings window (`SettingsView`) is very bare — expand into tabs (General /
  Audio / Advanced) as more prefs are added (see feature list below), each
  with its own icon per macOS System Settings conventions.

### 2.6 Motion & feedback
- Add consistent transition animations for state changes (start/stop,
  device switch, error banner appear/disappear) using
  `.animation(.spring(...), value:)` — right now most state changes snap
  instantly.
- Add haptic-style visual feedback (brief scale/opacity pulse) on button
  presses and toggle flips.
- Animate the error banner in/out with a slide + fade instead of appearing
  instantly in the VStack.

### 2.7 Accessibility & polish pass
- Audit color contrast of `textSecondary` (0.62/0.66/0.72 gray) against `bg`
  and `card` — likely fails WCAG AA at small caption sizes.
- Ensure every icon-only control (mute/solo if added, stepper buttons) has an
  accessibility label; the meter canvas already sets one good example.
- Respect "Reduce Motion" for any new animations.
- Support Dynamic Type-ish scaling where feasible even though this is a
  fixed-size utility window.

---

## 3. Feature backlog

### Audio / DSP
- **Per-speaker channel EQ**, not just global + stereo speaker EQ — expose
  individual PEQ per bed channel (e.g. fix a boomy LFE independent of the
  stereo bus).
- **Real-time spectrum analyzer** (FFT view) alongside the level meters, so
  users can see what's happening spectrally, not just peak dB.
- **LUFS / loudness metering** (integrated + short-term) in addition to peak
  dBFS, useful for consistent playback levels across content.
- **Channel solo/mute** on the bed visualizer — click a channel dot to
  solo/mute it for troubleshooting a noisy speaker feed.
- **Clip history / clipping alert log** — currently clip is only a boolean
  flash; keep a small rolling log of clip events with timestamps.
- **Configurable downmix coefficients** — expose the ADC2/LFE coefficients
  and per-channel gain trims in advanced settings instead of hardcoding them,
  for users who want ITU-R BS.775 or other matrices.
- **Room correction import** — support importing measurement-based
  correction curves (e.g. from REW) into the speaker EQ, beyond
  Equalizer APO-style text.
- **A/B bypass toggle** — quickly compare processed vs. raw stereo downmix
  without stopping the engine.
- **Multiple simultaneous output routing** — send to more than one stereo
  output (e.g. speakers + headphones) with independent EQ per output.

### Profiles & configuration
- **Full config export/import** (not just PEQ text) — a single JSON/plist
  bundle covering device selection, preamp, layout, toggles, and EQ profiles
  for easy backup or sharing setups.
- **iCloud sync of EQ profiles** across machines.
- **Per-source-app or per-layout auto-profiles** — e.g. automatically switch
  EQ/preamp when the selected layout preset changes.
- **Undo/redo** in the EQ editor for filter edits.

### Reliability / diagnostics
- **In-app engine log viewer** — surface Core Audio errors/xruns/dropouts in
  a scrollable diagnostics pane instead of only a transient error banner.
- **Device health checks** — proactively warn if BlackHole isn't configured
  as 16ch/9.1.6, or if sample rate mismatches 48 kHz, before the user hits
  Start.
- **Latency readout** — show measured round-trip/buffer latency in the UI.
- **Automatic reconnect** — if the selected input/output device disappears
  and reappears (e.g. USB DAC sleep/wake), auto-restore the session.
- **Crash/error reporting opt-in** (local-only log export for bug reports).

### App lifecycle / platform integration
- **Sparkle-based auto-update** (see the `macos-auto-update` skill) — the
  README already implies manual builds; wire up an appcast for painless
  updates.
- **Launch at login** toggle (in addition to existing `autoStart`).
- **Global keyboard shortcut** to start/stop from anywhere, not just the
  Transport menu.
- **Shortcuts.app / AppleScript support** — expose start/stop/preamp/profile
  switch as Shortcuts actions for automation (e.g. "start Downmix when I open
  Plex").
- **Notification Center alerts** for clip events or engine errors when the
  window isn't focused.
- **Onboarding flow** for first launch — guided BlackHole install/check,
  Audio MIDI Setup walkthrough with screenshots, mic permission explainer.

### Nice-to-have / stretch
- **Historical level graph** (last N seconds scrolling waveform of output
  level) instead of only instantaneous meters.
- **Preset library** for common 9.1.6/7.1.4/5.1.2 layouts beyond what
  `LayoutPreset` ships today, with a visual layout picker (not just a
  dropdown of names).
- **Menu bar mini-meter** — small live L/R level bars rendered directly in
  the menu bar icon.
- **Theming options** — let advanced users pick an accent color once the
  token system in §2.1 exists.

---

## 4. Suggested sequencing

1. **Theme token overhaul** (§2.1) — highest leverage, unblocks every other
   visual fix, and is contained to `Theme.swift` + a few call sites.
2. **Meter/bed visualizer polish** (§2.5, meters) — most-viewed surface,
   currently the roughest.
3. **Materials/depth + component redesign** (§2.2–2.5) — full pass once the
   palette is settled.
4. **Structured EQ filter list UI** — biggest usability win in the EQ sheet.
5. Feature backlog, roughly in the order listed under "Audio / DSP" first
   (core value), then "Reliability," then "Platform integration."
