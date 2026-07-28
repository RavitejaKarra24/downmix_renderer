import SwiftUI

struct ContentView: View {
  @Environment(AppState.self) private var state

  var body: some View {
    @Bindable var state = state

    ZStack {
      DownmixTheme.bg.ignoresSafeArea()

      VStack(spacing: 16) {
        header
        mainGrid
        if let error = state.errorMessage {
          errorBanner(error)
        }
      }
      .padding(20)
    }
    .preferredColorScheme(.dark)
    .sheet(isPresented: $state.showEQSheet) {
      EQEditorView()
        .environment(state)
        .frame(minWidth: 720, minHeight: 520)
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Downmix")
          .font(.system(size: 28, weight: .bold, design: .rounded))
          .foregroundStyle(DownmixTheme.textPrimary)
        Text("9.1.6 → stereo · native Core Audio")
          .font(.callout)
          .foregroundStyle(DownmixTheme.textSecondary)
      }

      Spacer()

      statusPill

      Button {
        state.toggle()
      } label: {
        Label(
          state.isRunning ? "Stop" : "Start",
          systemImage: state.isRunning ? "stop.fill" : "play.fill"
        )
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
      }
      .buttonStyle(.plain)
      .background(
        Capsule()
          .fill(state.isRunning ? DownmixTheme.bad.opacity(0.9) : DownmixTheme.accent)
      )
      .foregroundStyle(.white)
    }
    .padding(16)
    .background(card)
  }

  private var statusPill: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(statusColor)
        .frame(width: 8, height: 8)
        .shadow(color: statusColor.opacity(0.8), radius: state.isRunning ? 6 : 0)
      Text(state.status.message)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(DownmixTheme.textPrimary)
        .lineLimit(1)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Capsule().fill(Color.white.opacity(0.06)))
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

  private var mainGrid: some View {
    @Bindable var state = state

    return HStack(alignment: .top, spacing: 16) {
      VStack(spacing: 16) {
        DevicePickerCard(
          title: "Input",
          devices: state.inputDevices.filter { $0.inputChannelCount >= 2 },
          selectedID: state.selectedInputID,
          emptyHint: "No input devices found. Install BlackHole 16ch.",
          onSelect: state.selectInput
        )

        DevicePickerCard(
          title: "Output",
          devices: state.outputDevices.filter { $0.outputChannelCount >= 2 },
          selectedID: state.selectedOutputID,
          emptyHint: "No stereo output devices found.",
          onSelect: state.selectOutput
        )

        controlsCard
      }
      .frame(maxWidth: 360)

      NativeMeteringView(source: state.meterSource)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxHeight: .infinity)
  }

  private var controlsCard: some View {
    @Bindable var state = state

    return VStack(alignment: .leading, spacing: 14) {
      Text("Render controls")
        .font(.headline)
        .foregroundStyle(DownmixTheme.textPrimary)

      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Preamp")
            .foregroundStyle(DownmixTheme.textSecondary)
          Spacer()
          Text(String(format: "%.1f dB", state.preferences.preampDb))
            .font(.body.monospacedDigit().weight(.semibold))
            .foregroundStyle(DownmixTheme.textPrimary)
        }
        Slider(value: $state.preferences.preampDb, in: -30...6, step: 0.1)
          .tint(DownmixTheme.accent)
          .onChange(of: state.preferences.preampDb) { _, _ in
            state.persist()
          }
      }

      Picker(
        "Layout",
        selection: Binding(
          get: { state.selectedLayout },
          set: { state.selectedLayout = $0 }
        )
      ) {
        ForEach(LayoutPreset.all) { preset in
          Text(preset.name).tag(preset)
        }
      }
      .labelsHidden()
      .onChange(of: state.preferences.layoutPresetName) { _, _ in
        state.persist()
      }

      Toggle(isOn: $state.preferences.lfeLowpass) {
        VStack(alignment: .leading, spacing: 2) {
          Text("LFE Butterworth 125 Hz")
          Text("4th-order low-pass + dry delay")
            .font(.caption)
            .foregroundStyle(DownmixTheme.textSecondary)
        }
      }
      .toggleStyle(.switch)
      .onChange(of: state.preferences.lfeLowpass) { _, _ in state.persist() }

      Toggle(isOn: $state.preferences.swapOutputs) {
        Text("Swap L/R outputs")
      }
      .toggleStyle(.switch)
      .onChange(of: state.preferences.swapOutputs) { _, _ in state.persist() }

      HStack(spacing: 10) {
        Button("EQ / Profiles") {
          state.showEQSheet = true
        }
        .buttonStyle(SecondaryButtonStyle())

        Button("Refresh devices") {
          state.refreshDevices()
        }
        .buttonStyle(SecondaryButtonStyle())
      }

      DisclosureGroup("Advanced", isExpanded: $state.showAdvanced) {
        VStack(alignment: .leading, spacing: 10) {
          stepperRow(
            title: "Frames/buffer", value: $state.preferences.framesPerBuffer, range: 32...1024,
            step: 32)
          Toggle("Keep output awake", isOn: $state.preferences.keepOutputAlive)
            .onChange(of: state.preferences.keepOutputAlive) { _, on in
              state.persist()
              if on { state.startKeepAliveIfNeeded() } else if !state.isRunning { state.stop() }
            }
          Text("Default 128 frames is cooler than the original 64 while staying low-latency.")
            .font(.caption)
            .foregroundStyle(DownmixTheme.textSecondary)
        }
        .padding(.top, 8)
      }
      .foregroundStyle(DownmixTheme.textPrimary)
    }
    .padding(14)
    .background(card)
  }

  private func stepperRow(title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int)
    -> some View
  {
    HStack {
      Text(title)
        .foregroundStyle(DownmixTheme.textSecondary)
      Spacer()
      Stepper(value: value, in: range, step: step) {
        Text("\(value.wrappedValue)")
          .font(.body.monospacedDigit())
          .foregroundStyle(DownmixTheme.textPrimary)
      }
      .onChange(of: value.wrappedValue) { _, _ in
        state.persist()
      }
    }
  }

  private func errorBanner(_ text: String) -> some View {
    HStack {
      Image(systemName: "exclamationmark.triangle.fill")
      Text(text)
        .font(.callout)
      Spacer()
      Button("Dismiss") { state.errorMessage = nil }
        .buttonStyle(.plain)
    }
    .foregroundStyle(DownmixTheme.bad)
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(DownmixTheme.bad.opacity(0.12))
    )
  }

  private var card: some View {
    RoundedRectangle(cornerRadius: 16, style: .continuous)
      .fill(DownmixTheme.card)
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(DownmixTheme.cardStroke, lineWidth: 1)
      )
  }
}

struct SecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .semibold))
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.08))
      )
      .foregroundStyle(DownmixTheme.textPrimary)
  }
}
