import AppKit
import SwiftUI

struct MenuBarView: View {
  @Environment(AppState.self) private var state

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(state.status.message)
      if state.isKeepingOutputAwake {
        Label("DAC awake", systemImage: "moon.zzz.fill")
          .foregroundStyle(.secondary)
      }
      Text(String(format: "Preamp %.1f dB", state.preferences.preampDb))
      Divider()
      Button(state.isRunning ? "Stop renderer" : "Start renderer") {
        state.toggle()
      }
      Button("Refresh devices") {
        state.refreshDevices()
      }
      Divider()
      Button("Quit Downmix") {
        NSApplication.shared.terminate(nil)
      }
    }
    .padding(4)
  }
}

struct SettingsView: View {
  @Environment(AppState.self) private var state

  var body: some View {
    @Bindable var state = state
    Form {
      Section("Startup") {
        Toggle("Auto-start renderer when launched", isOn: $state.preferences.autoStart)
          .onChange(of: state.preferences.autoStart) { _, _ in state.persist() }
      }
      Section("About") {
        Text("Native 9.1.6 → stereo downmixer")
        Text("Core Audio · no WebKit · no Python")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 420, height: 220)
    .padding()
    .onAppear {
      if state.preferences.autoStart, !state.isRunning {
        state.start()
      }
    }
  }
}
