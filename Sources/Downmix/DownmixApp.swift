import SwiftUI

@main
struct DownmixApp: App {
  @State private var appState = AppState()

  var body: some Scene {
    Window("Downmix", id: "main") {
      ContentView()
        .environment(appState)
        .frame(minWidth: 820, minHeight: 640)
    }
    .defaultSize(width: 920, height: 720)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandMenu("Transport") {
        Button(appState.isRunning ? "Stop" : "Start") {
          appState.toggle()
        }
        .keyboardShortcut(.space, modifiers: [])
      }
    }

    Settings {
      SettingsView()
        .environment(appState)
    }

    MenuBarExtra(
      "Downmix", systemImage: appState.isRunning ? "waveform.circle.fill" : "waveform.circle"
    ) {
      MenuBarView()
        .environment(appState)
    }
  }
}
