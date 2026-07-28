import SwiftUI

struct ContentView: View {
  @Environment(AppState.self) private var state
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    @Bindable var state = state

    ZStack {
      DownmixTheme.backgroundGradient.ignoresSafeArea()
      Rectangle()
        .fill(.ultraThinMaterial)
        .opacity(0.34)
        .ignoresSafeArea()

      VStack(spacing: 16) {
        header
        mainGrid
        if let error = state.errorMessage {
          errorBanner(error)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .padding(20)
    }
    .animation(motion(.smooth(duration: 0.24)), value: state.status.phase)
    .animation(motion(.spring(response: 0.32, dampingFraction: 0.86)), value: state.errorMessage)
    .task {
      state.startAutomaticallyIfNeeded()
    }
    .sheet(isPresented: $state.showEQSheet) {
      EQEditorView()
        .environment(state)
        .frame(minWidth: 820, minHeight: 600)
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 16) {
      HStack(spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DownmixTheme.accentSoft)
            .frame(width: 42, height: 42)
          Image(systemName: "waveform.path")
            .font(.system(size: 21, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(DownmixTheme.accent)
            .symbolEffect(
              .variableColor.iterative,
              options: .repeating,
              isActive: state.isRunning && !reduceMotion
            )
        }
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 3) {
          Text("Downmix")
            .font(DownmixTheme.TypeScale.wordmark)
            .tracking(0.25)
            .foregroundStyle(DownmixTheme.textPrimary)
          Text("9.1.6 → stereo  ·  native Core Audio")
            .font(DownmixTheme.TypeScale.body)
            .foregroundStyle(DownmixTheme.textSecondary)
        }
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
      }
      .buttonStyle(TransportButtonStyle(isRunning: state.isRunning, reduceMotion: reduceMotion))
      .accessibilityHint(
        state.isRunning ? "Stops audio rendering" : "Starts audio rendering"
      )
    }
    .padding(16)
    .downmixRaisedPanel(cornerRadius: 18)
  }

  private var statusPill: some View {
    HStack(spacing: 8) {
      ZStack {
        if state.isRunning, !reduceMotion {
          Circle()
            .stroke(statusColor.opacity(0.34), lineWidth: 2)
            .frame(width: 18, height: 18)
            .transition(.scale.combined(with: .opacity))
        }
        Circle()
          .fill(statusColor)
          .frame(width: 8, height: 8)
          .shadow(color: statusColor.opacity(0.75), radius: state.isRunning ? 6 : 0)
      }
      Text(state.status.message)
        .font(DownmixTheme.TypeScale.bodyStrong)
        .foregroundStyle(DownmixTheme.textPrimary)
        .lineLimit(1)
        .contentTransition(.opacity)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(DownmixTheme.surfaceWell.opacity(0.9), in: Capsule())
    .overlay(Capsule().stroke(statusColor.opacity(0.24), lineWidth: 1))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Renderer status: \(state.status.message)")
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
    HStack(alignment: .top, spacing: 16) {
      ScrollView {
        VStack(spacing: 16) {
          DevicePickerCard(
            title: "Input",
            devices: state.inputDevices.filter { $0.inputChannelCount >= 2 },
            selectedID: state.selectedInputID,
            emptyHint: "Install or enable a multichannel input such as BlackHole 16ch.",
            onSelect: state.selectInput
          )

          DevicePickerCard(
            title: "Output",
            devices: state.outputDevices.filter { $0.outputChannelCount >= 2 },
            selectedID: state.selectedOutputID,
            emptyHint: "Connect a stereo-capable output device.",
            onSelect: state.selectOutput
          )

          controlsCard
        }
        .padding(.bottom, 2)
      }
      .scrollIndicators(.automatic)
      .frame(width: 350)

      NativeMeteringView(source: state.meterSource)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxHeight: .infinity)
  }

  private var controlsCard: some View {
    @Bindable var state = state

    return VStack(alignment: .leading, spacing: 14) {
      Label("Render controls", systemImage: "slider.horizontal.3")
        .font(DownmixTheme.TypeScale.headline)
        .foregroundStyle(DownmixTheme.textPrimary)

      preampControl

      Divider()
        .overlay(DownmixTheme.cardStroke)

      VStack(alignment: .leading, spacing: 7) {
        Text("BED LAYOUT")
          .font(DownmixTheme.TypeScale.label)
          .tracking(0.7)
          .foregroundStyle(DownmixTheme.textSecondary)

        Picker(
          "Bed layout",
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
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      dspOptions

      HStack(spacing: 10) {
        Button {
          state.showEQSheet = true
        } label: {
          Label("EQ / Profiles", systemImage: "waveform.badge.magnifyingglass")
        }
        .buttonStyle(SecondaryButtonStyle())

        Button {
          state.refreshDevices()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(SecondaryButtonStyle())
        .help("Rescan Core Audio devices")
      }

      advancedControls
    }
    .padding(15)
    .downmixRaisedPanel()
  }

  private var preampControl: some View {
    @Bindable var state = state

    return VStack(alignment: .leading, spacing: 9) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Preamp")
            .font(DownmixTheme.TypeScale.bodyStrong)
            .foregroundStyle(DownmixTheme.textPrimary)
          Text("Headroom before EQ and matrix processing")
            .font(DownmixTheme.TypeScale.caption)
            .foregroundStyle(DownmixTheme.textSecondary)
        }
        Spacer()
        DraggableDecibelField(
          value: $state.preferences.preampDb,
          range: -30...6,
          onCommit: state.persist
        )
      }

      Slider(value: $state.preferences.preampDb, in: -30...6, step: 0.1)
        .tint(DownmixTheme.accent)
        .onChange(of: state.preferences.preampDb) { _, _ in
          state.persist()
        }
        .accessibilityLabel("Preamp")

      PreampTickMarks(range: -30...6, markedValues: [-9.5, 0])
    }
  }

  private var dspOptions: some View {
    @Bindable var state = state

    return VStack(alignment: .leading, spacing: 12) {
      Text("DSP OPTIONS")
        .font(DownmixTheme.TypeScale.label)
        .tracking(0.7)
        .foregroundStyle(DownmixTheme.textSecondary)

      Toggle(isOn: $state.preferences.lfeLowpass) {
        optionLabel(
          title: "LFE Butterworth 125 Hz",
          detail: "4th-order low-pass with matched dry delay",
          symbol: "waveform.path.badge.minus"
        )
      }
      .toggleStyle(.switch)
      .onChange(of: state.preferences.lfeLowpass) { _, _ in state.persist() }

      Toggle(isOn: $state.preferences.swapOutputs) {
        optionLabel(
          title: "Swap L/R outputs",
          detail: "Applied before physical speaker EQ",
          symbol: "arrow.left.arrow.right"
        )
      }
      .toggleStyle(.switch)
      .onChange(of: state.preferences.swapOutputs) { _, _ in state.persist() }
    }
    .padding(12)
    .downmixRecessedWell(cornerRadius: 12)
  }

  private var advancedControls: some View {
    @Bindable var state = state

    return VStack(alignment: .leading, spacing: 0) {
      Divider()
        .overlay(DownmixTheme.cardStroke)

      Button {
        withAnimation(motion(.easeInOut(duration: 0.2))) {
          state.showAdvanced.toggle()
        }
      } label: {
        HStack {
          Label("Advanced", systemImage: "gearshape.2")
            .font(DownmixTheme.TypeScale.bodyStrong)
          Spacer()
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .rotationEffect(.degrees(state.showAdvanced ? 90 : 0))
        }
        .contentShape(Rectangle())
        .padding(.vertical, 11)
      }
      .buttonStyle(.plain)
      .foregroundStyle(DownmixTheme.textPrimary)
      .accessibilityValue(state.showAdvanced ? "Expanded" : "Collapsed")

      if state.showAdvanced {
        VStack(alignment: .leading, spacing: 11) {
          stepperRow(
            title: "Frames per buffer",
            value: $state.preferences.framesPerBuffer,
            range: 32...1024,
            step: 32
          )
          Toggle(isOn: $state.preferences.keepOutputAlive) {
            optionLabel(
              title: "Keep output awake",
              detail: "Prevents supported DACs from sleeping",
              symbol: "moon.zzz.fill"
            )
          }
          .toggleStyle(.switch)
          .onChange(of: state.preferences.keepOutputAlive) { _, on in
            state.persist()
            if on {
              state.startKeepAliveIfNeeded()
            } else if !state.isRunning {
              state.stop()
            }
          }
          Text("128 frames balances low latency with lower CPU use.")
            .font(DownmixTheme.TypeScale.caption)
            .foregroundStyle(DownmixTheme.textSecondary)
        }
        .padding(12)
        .downmixRecessedWell(cornerRadius: 12)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }

  private func optionLabel(title: String, detail: String, symbol: String) -> some View {
    HStack(spacing: 9) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(DownmixTheme.accent)
        .frame(width: 18)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(DownmixTheme.TypeScale.body)
          .foregroundStyle(DownmixTheme.textPrimary)
        Text(detail)
          .font(DownmixTheme.TypeScale.caption)
          .foregroundStyle(DownmixTheme.textSecondary)
      }
    }
  }

  private func stepperRow(
    title: String,
    value: Binding<Int>,
    range: ClosedRange<Int>,
    step: Int
  ) -> some View {
    HStack {
      Text(title)
        .font(DownmixTheme.TypeScale.body)
        .foregroundStyle(DownmixTheme.textSecondary)
      Spacer()
      Stepper(value: value, in: range, step: step) {
        Text("\(value.wrappedValue)")
          .font(DownmixTheme.TypeScale.liveValue)
          .foregroundStyle(DownmixTheme.textPrimary)
          .frame(width: 42, alignment: .trailing)
      }
      .onChange(of: value.wrappedValue) { _, _ in
        state.persist()
      }
    }
  }

  private func errorBanner(_ text: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .symbolRenderingMode(.hierarchical)
      Text(text)
        .font(DownmixTheme.TypeScale.body)
      Spacer()
      Button {
        state.errorMessage = nil
      } label: {
        Label("Dismiss", systemImage: "xmark")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss error")
    }
    .foregroundStyle(DownmixTheme.bad)
    .padding(12)
    .background(DownmixTheme.bad.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(DownmixTheme.bad.opacity(0.28), lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Error: \(text)")
  }

  private func motion(_ animation: Animation) -> Animation? {
    reduceMotion ? nil : animation
  }
}

private struct TransportButtonStyle: ButtonStyle {
  let isRunning: Bool
  let reduceMotion: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .semibold))
      .padding(.horizontal, 18)
      .padding(.vertical, 10)
      .background(
        Capsule()
          .fill(isRunning ? DownmixTheme.bad : DownmixTheme.accent)
      )
      .overlay(
        Capsule()
          .stroke(Color.white.opacity(configuration.isPressed ? 0.5 : 0.22), lineWidth: 1)
      )
      .foregroundStyle(isRunning ? DownmixTheme.onBad : DownmixTheme.onAccent)
      .shadow(
        color: (isRunning ? DownmixTheme.bad : DownmixTheme.accent)
          .opacity(isRunning ? 0.34 : 0.25),
        radius: isRunning ? 12 : 7
      )
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
      .opacity(configuration.isPressed ? 0.86 : 1)
      .animation(
        reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.7),
        value: configuration.isPressed
      )
  }
}

private struct DraggableDecibelField: View {
  @Binding var value: Double
  let range: ClosedRange<Double>
  let onCommit: () -> Void

  @State private var draftValue: Double
  @State private var dragOrigin: Double?
  @FocusState private var isEditing: Bool

  init(
    value: Binding<Double>,
    range: ClosedRange<Double>,
    onCommit: @escaping () -> Void
  ) {
    _value = value
    self.range = range
    self.onCommit = onCommit
    _draftValue = State(initialValue: value.wrappedValue)
  }

  var body: some View {
    HStack(spacing: 3) {
      TextField(
        "Preamp",
        value: $draftValue,
        format: .number.precision(.fractionLength(1))
      )
      .textFieldStyle(.plain)
      .multilineTextAlignment(.trailing)
      .frame(width: 43)
      .focused($isEditing)
      .onSubmit {
        commit()
      }
      .onChange(of: isEditing) { wasEditing, isEditing in
        if wasEditing, !isEditing {
          commit()
        }
      }
      Text("dB")
        .foregroundStyle(DownmixTheme.textSecondary)
    }
    .font(DownmixTheme.TypeScale.liveValue)
    .foregroundStyle(DownmixTheme.textPrimary)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .downmixRecessedWell(cornerRadius: 8)
    .simultaneousGesture(
      DragGesture(minimumDistance: 3)
        .onChanged { gesture in
          if dragOrigin == nil { dragOrigin = value }
          guard let dragOrigin else { return }
          let draggedValue = min(
            range.upperBound,
            max(range.lowerBound, dragOrigin + gesture.translation.width * 0.05)
          )
          draftValue = draggedValue
          value = draggedValue
        }
        .onEnded { _ in
          dragOrigin = nil
          onCommit()
        }
    )
    .onChange(of: value) { _, newValue in
      if !isEditing, dragOrigin == nil {
        draftValue = newValue
      }
    }
    .help("Type a value or drag horizontally")
    .accessibilityLabel("Preamp decibels")
  }

  private func commit() {
    let clamped = min(range.upperBound, max(range.lowerBound, draftValue))
    draftValue = clamped
    value = clamped
    onCommit()
  }
}

private struct PreampTickMarks: View {
  let range: ClosedRange<Double>
  let markedValues: [Double]

  var body: some View {
    GeometryReader { geometry in
      ForEach(markedValues, id: \.self) { value in
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        VStack(spacing: 2) {
          Rectangle()
            .fill(value == 0 ? DownmixTheme.accent : DownmixTheme.textSecondary.opacity(0.55))
            .frame(width: 1, height: 4)
          Text(value == -9.5 ? "−9.5 default" : "0 dB")
            .font(DownmixTheme.TypeScale.label.monospacedDigit())
            .foregroundStyle(
              value == 0 ? DownmixTheme.accent : DownmixTheme.textSecondary
            )
            .fixedSize()
        }
        .position(x: geometry.size.width * fraction, y: 8)
      }
    }
    .frame(height: 18)
    .accessibilityHidden(true)
  }
}
