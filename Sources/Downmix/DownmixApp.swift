import AppKit
import SwiftUI

@main
struct DownmixApp: App {
  @State private var appState: AppState

  init() {
    Self.yieldToRunningInstance()
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "development"
    let build = info?["CFBundleVersion"] as? String ?? "-"
    DownmixLog.shared.beginSession(
      version: "\(version) (\(build))",
      details: ["executable=\(Bundle.main.bundlePath)"])
    let state = AppState(
      musicRateMonitor: MusicTrackRateMonitor(), audioSourceMonitor: AudioSourceMonitor(),
      decoderRateMonitorFactory: { DecoderRateMonitor() },
      sourceFileMonitorFactory: { SourceFileMonitor() },
      systemOutputRouter: SystemOutputRouter())
    state.logStartupSummary()
    _appState = State(initialValue: state)
  }

  /// Two copies (e.g. ~/Applications and a fresh build) would both open the same input and
  /// DAC, double the audio, and fight over the Mac's sound output. Hand over to the copy
  /// already running instead.
  private static func yieldToRunningInstance() {
    guard let bundleID = Bundle.main.bundleIdentifier else { return }
    let me = ProcessInfo.processInfo.processIdentifier
    guard
      let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first(where: { $0.processIdentifier != me && !$0.isTerminated })
    else { return }
    other.activate()
    exit(0)
  }

  var body: some Scene {
    Window("Downmix", id: "main") {
      ContentView()
        .environment(appState)
        .frame(minWidth: 900, minHeight: 680)
    }
    .defaultSize(width: 1_040, height: 760)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandMenu("Transport") {
        Button(appState.isRunning ? "Stop" : "Start") {
          appState.toggle()
        }
        .keyboardShortcut(.space, modifiers: [.command, .shift])

        Button("Retry Saved Route") {
          appState.retrySavedRoute()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(!appState.canRetrySavedRoute)

        Divider()

        Button("Show Diagnostic Log") {
          DiagnosticLogActions.reveal()
        }
      }
    }

    Settings {
      SettingsView()
        .environment(appState)
    }

    MenuBarExtra {
      MenuBarView()
        .environment(appState)
    } label: {
      MenuBarStatusIcon(source: appState.meterSource, isRunning: appState.isRunning)
    }
    .menuBarExtraStyle(.window)
  }
}
