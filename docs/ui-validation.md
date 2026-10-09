# Native UI and accessibility release checks

## Automated commands

```sh
Scripts/check_ui.sh             # format, product typecheck, native hosting/layout smoke tests
Scripts/check_ui.sh --rendered  # additionally exercise native accessibility controls/actions
```

Both commands compile the actual `Sources/Downmix` Swift sources into a temporary
fixture bundle. The app entry and its Transport commands are typechecked; the
executable replaces only `DownmixApp.swift` with `Checks/UI/main.swift`. SDK selection
respects `DOWNMIX_UI_SDKROOT`, then `SDKROOT`, then the installed stable macOS 26.5
CLT SDK (avoiding SDK27's missing SwiftUI State macro plugin), or the selected Xcode
SDK. Do not edit compiler inputs during a run.

The default mode creates real `NSHostingView`/`NSWindow` instances and lays out
ContentView, SettingsView, MenuBarView, SetupChecklistView, EngineDiagnosticsView,
and MenuBarStatusIcon. It is **hosting/layout coverage, not rendered interaction
coverage**. It prints that distinction. AppKit still requires a usable macOS
session; this is not a Linux/headless replacement for UI testing.

`--rendered` orders only fixture windows offscreen, pumps the main run loop, and
walks actual in-process native AX descendants (cycle/depth guarded), including
window toolbars and the `AXTabs`/`AXContents` collections. AppKit controls use
`NSAccessibilityProtocol`; SwiftUI virtual nodes and native toolbar segments may
not declare the full protocol, so checked optional Objective-C lookup calls their
modern AX getters/actions without requiring protocol conformance. The ambiguous
object-valued `accessibilityValue` getter uses a selector checked with `responds(to:)`;
primitive action returns use typed calls. No legacy attribute queries are sent to
arbitrary descendants. Setup/diagnostic rows explicitly have static-text semantics
so native AX clients can retrieve their values, not unknown-role containers.

The fixture explicitly enables SwiftUI's accessibility environment and sets
`AXEnhancedUserInterface` on **its own NSApplication only**, using AppKit's legacy
application setter (a compiler deprecation warning is expected). This is necessary
for SwiftUI to construct its virtual AX nodes without a remote accessibility client.
It does not turn on VoiceOver, request trust, or change system preferences. This
fixture-only runtime/SDK dependency must fail visibly if a future OS stops supporting it.
Controls are looked up by stable identifiers, with roles, labels and values checked.
Actions use `accessibilityPerformPress` for SwiftUI virtual buttons and native
`NSControl.performClick` for AppKit buttons/switches, plus native slider increment.
A native NSSwitch on this OS can execute AX press while returning false; the
fixture does not retry that false result and inadvertently toggle twice. Toolbar
tab segments can likewise dispatch while returning false; they are pressed once
and success is verified from the actual rendered destination pane. No source grep,
test-side closure invocation, remote
`AXUIElement`, System Events, or external automation permission is involved.

Rendered scenarios:

- Main: Start → Stop, running input/output selections restart the fake route,
  Advanced expands/collapses diagnostics, and error-banner Retry recovers.
- Favorites/search: deterministic visible-neighbor ordering plus native named AX move/
  favorite actions, search and boundary availability with input/output/offline favorites
  interleaved; persisted hidden entries are preserved.
- Settings: native tab selection; auto-start, preamp increment and swap controls
  change the model; swap exposes its on state. Native transport, buffer increment and
  keep-alive actions verify fake route restarts/output-only transitions exactly once.
- Menu content: Start/Stop labels and actions; Retry refuses another output when
  the saved output is missing and recovers after reconnection; Refresh rescans.
- Retry warmup: actual main-window/menu-content AX controls remain disabled during
  output-only startup, without enumerating or cancelling that pending route, and become
  enabled after keep-alive startup completes. The global Transport command uses the
  same model eligibility; actual scene/keyboard dispatch remains manual.
- Save recovery: actual main/Settings/menu banners expose writer failures; native Retry
  Save retries only persistence, success removes every banner and preserves independent
  audio errors. Dismiss does not write or affect transport.
- Setup: speaker mapping and playback routing remain **Manual check**, with
  guidance; pending microphone permission remains **Permission required**;
  Refresh is read-only apart from fixture enumeration. Opening/dismissing the actual
  setup sheet and its Start permission action use fake authorization replies; Stop
  invalidates a delayed grant without starting a route.
- Diagnostics: rendered counter/queue values and last-run error label; errors
  clear queued audio while retaining failure counters.
- Reduce Motion: the injected environment retains ContentView actions/diagnostics
  and the status icon's accessible content. SDK26.5 exposes its public environment
  value as read-only; the fixture alone uses the SDK's underscored writable
  `_accessibilityReduceMotion` shim. Production views use the public read-only API. This is **not** a measurement of
  animation timing, frames or absence of visual motion.

A failed assertion, unavailable native action/tree, missing SDK or logged-in
WindowServer session exits nonzero. There is no fallback that labels compilation
or model tests as a passing rendered run. The runner has a 120-second execution
timeout; compilation is separate.

## Isolation and safety

The temporary `.app` gets a unique `com.local.downmix.UIchecks.<UUID>` bundle ID.
All AppState dependencies are supplied explicitly: fake engine, in-memory
preferences, catalog, authorization query/request, route-safety callback and writer;
listeners are disabled. The real engine is compiled but **never instantiated**.
No audio hardware, device observers, TCC prompt, preferences JSON, default route,
or Audio MIDI Setup changes are used. Startup/keep-alive preferences are explicitly
off. `@AppStorage` favorites resolve the unique fixture domain, which is removed
before/after normal execution. Fixture windows close on completion/failure and the
script removes its temporary bundle/source snapshot. SDK/toolchain-keyed compiler
modules are retained under `.build/ui-check-module-cache` to avoid rebuilding
AppKit on every run. The fixture never invokes Quit, Show
Downmix or system-tool buttons. Permission actions invoke only the injected fake
request/reply provider, never AVCaptureDevice/TCC. No VoiceOver or system
accessibility preference is automatically enabled.

## Identifier contract

Identifiers are on controls, not merely their surrounding cards:

- `main.transport`, `main.status`, `main.layout`, `main.preamp.field`,
  `main.preamp.slider`, `main.lfeLowpass`, `main.swapOutputs`, `main.refresh`,
  `main.advanced`, `main.framesPerBuffer`, `main.keepOutputAlive`, `main.retry`,
  `main.dismissError`, `main.error`.
- `device.<input|output>.<deviceUID>` uses persistent device identity (not a
  transient Core Audio ID); `.favorite`, `.moveUp` and `.moveDown` identify its
  context-menu actions.
  `device.<input|output>.filter` and `.picker` identify search/group surfaces.
- `settings.tabs`, `settings.autoStart`, `settings.transport`, `settings.input`,
  `settings.output`, `settings.layout`, `settings.preamp`, `settings.lfeLowpass`,
  `settings.swapOutputs`, `settings.refresh`, `settings.framesPerBuffer`,
  `settings.keepOutputAlive`.
- `menu.transport`, `menu.retry`, `menu.refresh`, `menu.showWindow`, `menu.quit`,
  `menu.status`, `menu.statusIcon`, `menu.stereoMeter`.
- `setup.open`, `setup.row.<SetupCheck.ID>`, `setup.requestPermission`,
  `setup.audioMIDI`, `setup.microphoneSettings`, `setup.refresh`, `setup.done`.
- `<main|settings|menu>.saveError`, `.retrySave` and `.dismissSaveError` identify
  persistence-only error/recovery surfaces, distinct from audio-route Retry.
- `diagnostics` and `diagnostics.<row title>`; row titles are currently fixed.

Favorites have context-menu and named accessibility actions for pin/unpin and
moving up/down, so drag reordering is not the only path. Preamp also has a typed
field and native slider alternative to dragging.

The full rendered suite reports **11 groups: 1 deterministic favorite-ordering and
10 rendered native groups**. `Scripts/check_release.sh` and universal packaging require it.
`Scripts/check_metering.sh` separately tests actual native meter reset/ballistics/settled
Timer behavior in debug and optimized builds; see `Checks/Metering/README.md`.

## Manual release gate (still required)

Use the packaged real app with deliberate user-selected devices and permissions.
Do not interpret these checks as complete VoiceOver certification.

1. **Keyboard:** with keyboard navigation enabled, Tab/Shift-Tab through transport,
   input/output rows, filter, preamp field/slider, layout popup, switches, Refresh,
   Setup and Advanced. Space/Return activates focused buttons; arrows operate
   sliders/pickers/steppers. Focus remains visible and can leave each control.
   Open device context menus by keyboard, pin/unpin and reorder favorites.
2. **Global commands:** Transport Start/Stop is Cmd-Shift-Space. Retry Saved Route
   is Cmd-Shift-R, owned only by the global Transport command. Verify from main
   and Settings windows, and with the menu-bar popup open; no duplicate local
   Retry shortcut should steal it. Retry is disabled while starting/running/stopping.
   Cmd-comma opens Settings; Escape closes the setup sheet; sheet focus returns
   to its invoking button. The fixture typechecks commands but does not simulate
   the SwiftUI App scene/global menu dispatch.
3. **VoiceOver (enable manually):** verify readable control names, selected device
   and switch states, status changes, errors/recovery, setup guidance and
   diagnostics. Traversal order should follow the visual hierarchy without
   decorative icons becoming extra stops. Check Settings tabs and popup choices,
   native meters, and the actual menu-bar extra in its real scene. Confirm speech,
   announcements and rotor/custom-action usability; a native AX snapshot cannot
   verify these behaviors.
4. **Truthful setup:** automatic device/rate/permission checks may be Verified;
   speaker mapping and playback routing must remain Manual check, never green
   certification. Use system-tool buttons only when intentionally validating them.
5. **Motion/appearance:** manually enable Reduce Motion and verify no decorative
   transport pulse/scale or menu icon running-state transition. Content and actions
   must be unchanged. Also inspect light/dark, Increase Contrast, larger text,
   minimum window size and scroll reachability. Restore preferences yourself.
6. **Recovery:** intentionally remove/reconnect a chosen route; verify errors,
   saved-route-only Retry, no silent fallback and no unsolicited permission prompt.

The offscreen fixture does not certify pixel colors/contrast, physical keyboard
focus, animation behavior, live hardware, TCC UI, actual Settings/MenuBarExtra scene
integration, or full VoiceOver speech. Full Xcode/XCTest is not required for the
in-process harness, but can supply complementary end-to-end scene tests.
