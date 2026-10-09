import AppKit
import Combine
import CoreAudio
import SwiftUI

struct MenuBarView: View {
  @Environment(AppState.self) private var state
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label {
        Text(state.status.message)
          .lineLimit(1)
      } icon: {
        Image(systemName: statusSymbol)
          .foregroundStyle(statusColor)
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("menu.status")

      Label {
        CompactStereoMeter(source: state.meterSource)
      } icon: {
        Image(systemName: "waveform")
          .foregroundStyle(.secondary)
      }

      Label(
        String(format: "Preamp %.1f dB", state.preferences.preampDb),
        systemImage: "slider.horizontal.3"
      )
      .foregroundStyle(.secondary)

      if state.isKeepingOutputAwake {
        Label("DAC awake", systemImage: "moon.zzz.fill")
          .foregroundStyle(.secondary)
      }

      Divider()

      Button {
        state.toggle()
      } label: {
        Label(
          state.isRunning ? "Stop Renderer" : "Start Renderer",
          systemImage: state.isRunning ? "stop.fill" : "play.fill"
        )
      }
      .accessibilityIdentifier("menu.transport")

      if state.errorMessage != nil || state.status.phase == .error {
        Button {
          state.retrySavedRoute()
        } label: {
          Label("Retry Saved Route", systemImage: "arrow.clockwise.circle")
        }
        .accessibilityIdentifier("menu.retry")
        .disabled(!state.canRetrySavedRoute)
        .accessibilityHint("Rescans devices without falling back to another route")
      }

      PersistenceFailureView(surface: "menu")

      Button {
        state.refreshDevices()
      } label: {
        Label("Refresh Devices", systemImage: "arrow.clockwise")
      }
      .accessibilityIdentifier("menu.refresh")

      Button {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
      } label: {
        Label("Show Downmix", systemImage: "macwindow")
      }
      .accessibilityIdentifier("menu.showWindow")

      Divider()

      Button {
        NSApplication.shared.terminate(nil)
      } label: {
        Label("Quit Downmix", systemImage: "power")
      }
      .accessibilityIdentifier("menu.quit")
    }
    .frame(width: 240, alignment: .leading)
    .padding(.vertical, 4)
  }

  private var statusSymbol: String {
    switch state.status.phase {
    case .running: "waveform.circle.fill"
    case .keepAlive: "moon.zzz.fill"
    case .starting, .stopping: "arrow.triangle.2.circlepath.circle.fill"
    case .error: "exclamationmark.triangle.fill"
    case .stopped: "waveform.circle"
    }
  }

  private var statusColor: Color {
    switch state.status.phase {
    case .running: DownmixTheme.good
    case .keepAlive: DownmixTheme.accent
    case .starting, .stopping: DownmixTheme.warn
    case .error: DownmixTheme.bad
    case .stopped: DownmixTheme.textSecondary
    }
  }
}

struct MenuBarStatusIcon: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let source: MeterSource
  let isRunning: Bool

  @State private var snapshot = MeterSnapshot.empty

  var body: some View {
    HStack(spacing: 2) {
      Image(systemName: isRunning ? "waveform.circle.fill" : "waveform.circle")
      if isRunning {
        HStack(alignment: .bottom, spacing: 1) {
          levelBar(snapshot.outputPeakLDb)
          levelBar(snapshot.outputPeakRDb)
        }
        .frame(height: 10)
        .transition(.opacity)
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isRunning)
    .onAppear(perform: updateSnapshot)
    .onReceive(
      NotificationCenter.default.publisher(for: .downmixMetersDidChange, object: source)
        .receive(on: RunLoop.main)
    ) { _ in
      updateSnapshot()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(isRunning ? "Downmix is rendering" : "Downmix is stopped")
    .accessibilityIdentifier("menu.statusIcon")
  }

  private func levelBar(_ db: Float) -> some View {
    Capsule()
      .fill(.primary)
      .frame(width: 2, height: max(2, 10 * level(for: db)))
  }

  private func level(for db: Float) -> CGFloat {
    CGFloat(min(1, max(0, (db + 60) / 60)))
  }

  private func updateSnapshot() {
    snapshot = source.snapshot()
  }
}

private struct CompactStereoMeter: View {
  let source: MeterSource

  @State private var snapshot = MeterSnapshot.empty

  var body: some View {
    VStack(spacing: 4) {
      meterRow(label: "L", db: snapshot.outputPeakLDb, isClipping: snapshot.clipL)
      meterRow(label: "R", db: snapshot.outputPeakRDb, isClipping: snapshot.clipR)
    }
    .onAppear(perform: updateSnapshot)
    .onReceive(
      NotificationCenter.default.publisher(for: .downmixMetersDidChange, object: source)
        .receive(on: RunLoop.main)
    ) { _ in
      updateSnapshot()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Stereo output level")
    .accessibilityIdentifier("menu.stereoMeter")
    .accessibilityValue(accessibilityValue)
  }

  private func meterRow(label: String, db: Float, isClipping: Bool) -> some View {
    HStack(spacing: 6) {
      Text(label)
        .font(.caption2.monospaced().weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 10, alignment: .leading)

      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(.quaternary)

          Capsule()
            .fill(isClipping ? DownmixTheme.bad : DownmixTheme.accent)
            .frame(width: geometry.size.width * level(for: db))
        }
      }
      .frame(height: 5)

      if isClipping {
        Image(systemName: "exclamationmark")
          .font(.caption2.bold())
          .foregroundStyle(DownmixTheme.bad)
          .frame(width: 10)
          .accessibilityHidden(true)
      } else {
        Color.clear
          .frame(width: 10, height: 1)
      }
    }
  }

  private func level(for db: Float) -> CGFloat {
    CGFloat(min(1, max(0, (db + 60) / 60)))
  }

  private func updateSnapshot() {
    snapshot = source.snapshot()
  }

  private var accessibilityValue: String {
    let left = snapshot.clipL ? "clipping" : String(format: "%.1f decibels", snapshot.outputPeakLDb)
    let right =
      snapshot.clipR ? "clipping" : String(format: "%.1f decibels", snapshot.outputPeakRDb)
    return "Left \(left), right \(right)"
  }
}

private enum DownmixSettingsTab: Hashable {
  case general
  case audio
  case advanced
  case about
}

struct SettingsView: View {
  @State private var selection: DownmixSettingsTab = .general

  var body: some View {
    VStack(spacing: 0) {
      PersistenceFailureView(surface: "settings")
        .padding(.horizontal, 12)
      TabView(selection: $selection) {
        GeneralSettingsPane()
          .tabItem {
            Label("General", systemImage: "gearshape")
          }
          .tag(DownmixSettingsTab.general)

        AudioSettingsPane()
          .tabItem {
            Label("Audio", systemImage: "speaker.wave.2")
          }
          .tag(DownmixSettingsTab.audio)

        AdvancedSettingsPane()
          .tabItem {
            Label("Advanced", systemImage: "slider.horizontal.3")
          }
          .tag(DownmixSettingsTab.advanced)

        AboutSettingsPane()
          .tabItem {
            Label("About", systemImage: "info.circle")
          }
          .tag(DownmixSettingsTab.about)
      }
      .accessibilityIdentifier("settings.tabs")
    }
    .frame(width: 560, height: 430)
  }
}

private struct GeneralSettingsPane: View {
  @Environment(AppState.self) private var state

  var body: some View {
    @Bindable var state = state

    SettingsForm {
      Section("Startup") {
        Toggle(isOn: $state.preferences.autoStart) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Auto-start renderer when launched")
            Text("Starts Downmix automatically with the last selected devices.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .toggleStyle(.switch)
        .accessibilityLabel("Auto-start renderer when launched")
        .accessibilityIdentifier("settings.autoStart")
        .onChange(of: state.preferences.autoStart) { _, _ in
          state.persist()
        }
      }

      Section("Renderer") {
        LabeledContent("Status") {
          Label(state.status.message, systemImage: rendererStatusSymbol)
            .foregroundStyle(rendererStatusColor)
        }

        Button {
          state.toggle()
        } label: {
          Label(
            state.isRunning ? "Stop Renderer" : "Start Renderer",
            systemImage: state.isRunning ? "stop.fill" : "play.fill"
          )
        }
        .accessibilityIdentifier("settings.transport")
      }
    }
  }

  private var rendererStatusSymbol: String {
    switch state.status.phase {
    case .running: "checkmark.circle.fill"
    case .keepAlive: "moon.zzz.fill"
    case .starting, .stopping: "arrow.triangle.2.circlepath"
    case .error: "exclamationmark.triangle.fill"
    case .stopped: "circle"
    }
  }

  private var rendererStatusColor: Color {
    switch state.status.phase {
    case .running: DownmixTheme.good
    case .keepAlive: DownmixTheme.accent
    case .starting, .stopping: DownmixTheme.warn
    case .error: DownmixTheme.bad
    case .stopped: DownmixTheme.textSecondary
    }
  }
}

private struct AudioSettingsPane: View {
  @Environment(AppState.self) private var state

  var body: some View {
    @Bindable var state = state

    SettingsForm {
      Section("Devices") {
        Picker("Input", selection: inputSelection) {
          Text("Select input").tag(Optional<AudioDeviceID>.none)
          ForEach(state.inputDevices.filter { $0.inputChannelCount >= 16 }) { device in
            Text(device.name)
              .tag(Optional(device.id))
          }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("settings.input")

        Picker("Output", selection: outputSelection) {
          Text("Select output").tag(Optional<AudioDeviceID>.none)
          ForEach(state.outputDevices.filter { $0.outputChannelCount >= 2 }) { device in
            Text(device.name)
              .tag(Optional(device.id))
          }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("settings.output")

        HStack {
          Spacer()
          Button {
            state.refreshDevices()
          } label: {
            Label("Refresh Devices", systemImage: "arrow.clockwise")
          }
          .accessibilityIdentifier("settings.refresh")
        }
      }

      Section("Setup") {
        SetupChecklistButton()
      }

      Section("Downmix") {
        Picker(
          "Speaker layout",
          selection: Binding(
            get: { state.selectedLayout },
            set: { state.selectedLayout = $0 }
          )
        ) {
          ForEach(LayoutPreset.all) { preset in
            Text(preset.name)
              .tag(preset)
          }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("settings.layout")

        LabeledContent("Preamp") {
          HStack(spacing: 12) {
            Slider(value: $state.preferences.preampDb, in: -30...6, step: 0.1)
              .accessibilityLabel("Preamp")
              .accessibilityIdentifier("settings.preamp")
              .frame(width: 220)
            Text(String(format: "%.1f dB", state.preferences.preampDb))
              .monospacedDigit()
              .foregroundStyle(.secondary)
              .frame(width: 58, alignment: .trailing)
          }
        }
        .onChange(of: state.preferences.preampDb) { _, _ in
          state.persist()
        }

        Toggle(isOn: $state.preferences.lfeLowpass) {
          VStack(alignment: .leading, spacing: 2) {
            Text("LFE Butterworth 125 Hz")
            Text("Applies a fourth-order low-pass filter with a matched dry delay.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .toggleStyle(.switch)
        .accessibilityLabel("LFE Butterworth 125 Hz")
        .accessibilityIdentifier("settings.lfeLowpass")
        .onChange(of: state.preferences.lfeLowpass) { _, _ in
          state.persist()
        }

        Toggle("Swap left and right outputs", isOn: $state.preferences.swapOutputs)
          .toggleStyle(.switch)
          .accessibilityIdentifier("settings.swapOutputs")
          .onChange(of: state.preferences.swapOutputs) { _, _ in
            state.persist()
          }
      }
    }
  }

  private var inputSelection: Binding<AudioDeviceID?> {
    Binding(
      get: { state.selectedInputID },
      set: { id in
        guard
          let id,
          let device = state.inputDevices.first(where: { $0.id == id })
        else { return }
        state.selectInput(device)
      }
    )
  }

  private var outputSelection: Binding<AudioDeviceID?> {
    Binding(
      get: { state.selectedOutputID },
      set: { id in
        guard
          let id,
          let device = state.outputDevices.first(where: { $0.id == id })
        else { return }
        state.selectOutput(device)
      }
    )
  }
}

private struct AdvancedSettingsPane: View {
  @Environment(AppState.self) private var state

  var body: some View {
    @Bindable var state = state

    SettingsForm {
      Section("Audio Engine") {
        LabeledContent("I/O buffer") {
          Stepper(
            value: $state.preferences.framesPerBuffer,
            in: 32...1024,
            step: 32
          ) {
            Text("\(state.preferences.framesPerBuffer) frames")
              .monospacedDigit()
              .frame(width: 86, alignment: .trailing)
          }
          .accessibilityLabel("I/O buffer")
          .accessibilityIdentifier("settings.framesPerBuffer")
        }
        .onChange(of: state.preferences.framesPerBuffer) { _, _ in
          state.persist()
        }

        Text(
          "128 frames balances latency and power use. Changing this restarts the active audio route."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Diagnostics") {
        EngineDiagnosticsView()
      }

      Section("Output") {
        Toggle(isOn: $state.preferences.keepOutputAlive) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Keep output awake")
            Text("Sends silence while the renderer is stopped so the DAC stays active.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .toggleStyle(.switch)
        .accessibilityLabel("Keep output awake")
        .accessibilityIdentifier("settings.keepOutputAlive")
        .onChange(of: state.preferences.keepOutputAlive) { _, isEnabled in
          state.persist()
          if isEnabled {
            state.startKeepAliveIfNeeded()
          } else if !state.isRunning {
            state.stop()
          }
        }
      }
    }
  }
}

private struct AboutSettingsPane: View {
  var body: some View {
    SettingsForm {
      Section {
        VStack(spacing: 10) {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)

          Text("Downmix")
            .font(.title2.weight(.semibold))

          Text("Native 9.1.6 → stereo downmixer")
            .foregroundStyle(.secondary)

          Text(versionDescription)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
      }

      Section("Technology") {
        LabeledContent("Audio engine", value: "Core Audio")
        LabeledContent("Interface", value: "SwiftUI + AppKit")
      }
    }
  }

  private var versionDescription: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

    switch (version, build) {
    case (.some(let version), .some(let build)):
      return "Version \(version) (\(build))"
    case (.some(let version), .none):
      return "Version \(version)"
    default:
      return "Development build"
    }
  }
}

private struct SettingsForm<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    Form {
      content
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .contentMargins(.top, 8, for: .scrollContent)
  }
}
