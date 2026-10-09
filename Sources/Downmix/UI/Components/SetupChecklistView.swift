import AppKit
import SwiftUI

/// Only this subview observes live diagnostics; transport and meters do not depend on them.
struct EngineDiagnosticsView: View {
  @Environment(AppState.self) private var state

  var body: some View {
    let diagnostics = state.diagnostics

    VStack(alignment: .leading, spacing: 8) {
      Text(state.status.phase == .error ? "Last-run diagnostics" : "Current-run diagnostics")
        .font(.headline)
      diagnosticRow("Underruns", value: "\(diagnostics.underrunCount)")
      diagnosticRow("Underrun frames", value: "\(diagnostics.underrunFrames)")
      diagnosticRow("Overruns", value: "\(diagnostics.overrunCount)")
      diagnosticRow("Overrun frames", value: "\(diagnostics.overrunFrames)")
      diagnosticRow("Rejected slices", value: "\(diagnostics.rejectedSliceCount)")
      diagnosticRow("Render errors", value: "\(diagnostics.renderErrorCount)")
      diagnosticRow("Requested I/O buffer", value: "\(diagnostics.requestedBufferFrames) frames")
      diagnosticRow("Actual input buffer", value: "\(diagnostics.inputBufferFrames) frames")
      diagnosticRow("Actual output buffer", value: "\(diagnostics.outputBufferFrames) frames")
      diagnosticRow(
        "Clock correction", value: diagnostics.driftCorrectionEnabled ? "Enabled" : "Inactive")
      diagnosticRow("Priming", value: diagnostics.isPriming ? "Waiting for input" : "No")
      diagnosticRow(
        "Clock adjustment", value: String(format: "%+.1f ppm", diagnostics.correctionPPM))
      diagnosticRow("Rebuffers", value: "\(diagnostics.rebufferCount)")
      diagnosticRow("Queued audio", value: "\(diagnostics.queuedFrames) frames")
      diagnosticRow(
        "Approx. queue latency", value: String(format: "%.2f ms", diagnostics.queueLatencyMs))
      Text(
        "Queue latency is an estimate, not end-to-end latency. Buffer sizes are recorded at startup; zero means no measurement."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Text(
        "Counters reset each run. Initial priming and keep-alive silence are intentional; all recovery silence counts as missing audio. Clock correction adds a reservoir of at least 42.7 ms."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("diagnostics")
    .accessibilityLabel(
      state.status.phase == .error
        ? "Last-run audio engine diagnostics" : "Current-run audio engine diagnostics")
  }

  private func diagnosticRow(_ title: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Text(value)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }
    .font(.caption)
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isStaticText)
    .accessibilityLabel(title)
    .accessibilityIdentifier("diagnostics.\(title)")
    .accessibilityValue(value)
  }
}

struct SetupChecklistButton: View {
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented = true
    } label: {
      Label("Setup Checklist", systemImage: "checklist")
    }
    .accessibilityIdentifier("setup.open")
    .help("Check the selected devices and see manual setup steps")
    .sheet(isPresented: $isPresented) {
      SetupChecklistView()
    }
  }
}

struct SetupChecklistView: View {
  @Environment(AppState.self) private var state
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL

  var body: some View {
    let checklist = state.setupChecklist

    VStack(alignment: .leading, spacing: 12) {
      Text("Setup Checklist")
        .font(.title2.bold())
      Text(
        "Checks apply to the currently selected devices. Speaker mapping and playback routing still need manual verification."
      )
      .font(.callout)
      .foregroundStyle(.secondary)

      Form {
        ForEach(checklist.checks) { check in
          Section {
            SetupCheckRow(check: check)
          }
        }
      }
      .formStyle(.grouped)

      if let error = state.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .foregroundStyle(DownmixTheme.bad)
          .accessibilityElement(children: .combine)
      }

      if checklist.canRequestPermission {
        Button("Start and Request Microphone Access") {
          state.promptStart()
        }
        .disabled(state.isRunning)
        .accessibilityIdentifier("setup.requestPermission")
        .accessibilityHint("Validates the selected route before requesting microphone access")
      }

      HStack {
        Button("Audio MIDI Setup…") {
          NSWorkspace.shared.open(
            URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
        }
        .accessibilityIdentifier("setup.audioMIDI")
        Button("Microphone Settings…") {
          if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
          {
            openURL(url)
          }
        }
        .accessibilityIdentifier("setup.microphoneSettings")
      }
      Text("These buttons open system tools; Downmix does not change your system routes.")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack {
        Button("Refresh Checks") { state.refreshDevices() }
          .accessibilityIdentifier("setup.refresh")
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("setup.done")
      }
    }
    .padding(20)
    .frame(width: 540, height: 640)
  }
}

private struct SetupCheckRow: View {
  let check: SetupCheck

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Image(systemName: symbol)
          .foregroundStyle(color)
          .accessibilityHidden(true)
        Text(check.title)
          .font(.body.bold())
        Spacer()
        Text(check.status.rawValue)
          .font(.caption)
          .foregroundStyle(color)
      }
      Text(check.guidance)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isStaticText)
    .accessibilityIdentifier("setup.row.\(check.id.rawValue)")
    .accessibilityLabel(check.title)
    .accessibilityValue(check.status.rawValue)
    .accessibilityHint(check.guidance)
  }

  private var symbol: String {
    switch check.status {
    case .verified: "checkmark.circle.fill"
    case .needsAttention: "exclamationmark.triangle"
    case .permissionRequired: "lock.circle"
    case .manual: "hand.point.up"
    }
  }

  private var color: Color {
    switch check.status {
    case .verified: DownmixTheme.good
    case .needsAttention, .permissionRequired: DownmixTheme.warn
    case .manual: .secondary
    }
  }
}
