import SwiftUI

@main
struct DownmixApp: App {
  @State private var appState = AppState()

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
