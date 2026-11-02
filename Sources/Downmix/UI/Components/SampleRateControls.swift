import SwiftUI

struct SampleRateControls: View {
  @Environment(AppState.self) private var state

  var body: some View {
    @Bindable var state = state

    Picker("Mode", selection: $state.preferences.sampleRateMode) {
      ForEach(SampleRateMode.allCases) { mode in
        Text(mode.title).tag(mode)
      }
    }
    .pickerStyle(.menu)
    .accessibilityLabel("Sample rate mode")
    .accessibilityIdentifier("settings.sampleRateMode")
    .onChange(of: state.preferences.sampleRateMode) { _, _ in
      state.rateSettingsChanged()
    }

    if state.preferences.sampleRateMode == .fixed {
      Picker("Fixed rate", selection: $state.preferences.fixedSampleRate) {
        ForEach(AppPreferences.selectableSampleRates, id: \.self) { rate in
          Text("\(rate / 1000, format: .number) kHz").tag(rate)
        }
      }
      .pickerStyle(.menu)
      .accessibilityLabel("Fixed sample rate")
      .accessibilityIdentifier("settings.fixedSampleRate")
      .onChange(of: state.preferences.fixedSampleRate) { _, _ in
        state.rateSettingsChanged()
      }
    }

    Picker("DAC bit depth", selection: $state.preferences.outputBitDepthMode) {
      ForEach(OutputBitDepthMode.allCases) { mode in
        Text(mode.title).tag(mode)
      }
    }
    .pickerStyle(.menu)
    .accessibilityLabel("DAC bit depth")
    .accessibilityIdentifier("settings.outputBitDepth")
    .onChange(of: state.preferences.outputBitDepthMode) { _, _ in
      state.rateSettingsChanged()
    }
    Text(
      state.preferences.outputBitDepthMode == .matchSource
        ? "The DAC runs at the playing file's own bit depth (16/24-bit) when Automatic can read it, otherwise at its deepest. Note: at 16-bit the preamp-scaled mix is rounded to 16 bits."
        : "The DAC always runs at its deepest bit depth, which keeps every bit of the mix."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)

    Toggle(isOn: $state.preferences.matchMusicSampleRate) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Use Apple Music rate metadata")
        Text("Allows the Music adapter in Automatic mode. macOS may ask for Automation permission.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .toggleStyle(.switch)
    .accessibilityLabel("Use Apple Music rate metadata")
    .accessibilityIdentifier("settings.matchMusicRate")
    .onChange(of: state.preferences.matchMusicSampleRate) { _, _ in
      state.rateSettingsChanged()
    }

    Text(state.sampleRateSummary)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("settings.musicRateStatus")

    if !state.routedAppRows.isEmpty {
      Text("Routed apps")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ForEach(state.routedAppRows, id: \.source.id) { row in
        AppRateProfileRow(source: row.source, savedRate: row.savedRate)
      }
    }

    Text(
      "Automatic reads, for every routed app: decoder-input logs, the header of the audio file a local player (Kew, Elmedia, VLC…) is playing, a saved app rate, then Music track metadata. Something playing now outranks another app\u{2019}s saved rate. Browsers and streaming apps expose no source rate: save one for them (YouTube is almost always 48 kHz). Nothing is guessed; live sources claiming different rates hold the current rate."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// Explicit user declaration for one app: its own playback rate, saved by choice.
private struct AppRateProfileRow: View {
  @Environment(AppState.self) private var state
  let source: AudioPlaybackSource
  let savedRate: Double?

  private var key: String { SampleRateDecision.profileKey(for: source) }

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(source.name)
          .font(.callout)
        Text(savedRate.map { "Saved: \(Int($0.rounded())) Hz" } ?? "No saved rate")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Menu {
        if let current = state.currentRateForProfile {
          Button("Use current rate (\(Int(current.rounded())) Hz)") {
            state.saveCurrentRateProfile(for: key)
          }
          .accessibilityIdentifier("rate.app.\(key).useCurrent")
          Divider()
        }
        ForEach(AppPreferences.selectableSampleRates, id: \.self) { rate in
          Button("\(Int(rate.rounded())) Hz") {
            state.saveRateProfile(rate, for: key)
          }
        }
        if savedRate != nil {
          Divider()
          Button("Remove saved rate") { state.removeRateProfile(for: key) }
        }
      } label: {
        Text(savedRate.map { "\(Int($0.rounded())) Hz" } ?? "Set rate")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityIdentifier("rate.app.\(key)")
      .accessibilityLabel("Playback rate for \(source.name)")
    }
  }
}

/// Read-only signal-path evidence shared by Settings and the main window.
struct RateSignalPathView: View {
  @Environment(AppState.self) private var state

  var body: some View {
    let stages: [(title: String, value: String, identifier: String)] = [
      ("Source", state.playbackSourceSummary, "rate.source"),
      ("Reported", state.reportedSourceRateText, "rate.reported"),
      ("Captured", state.capturedRateText, "rate.capture"),
      ("DSP", state.renderRateText, "rate.render"),
      ("DAC", state.dacRateText, "rate.dac"),
    ]

    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(stages.enumerated()), id: \.element.identifier) { index, stage in
          rateRow(
            stage.title,
            value: stage.value,
            identifier: stage.identifier,
            isFirst: index == 0,
            isLast: index == stages.count - 1
          )
        }
      }

      Text(state.rateConversionSummary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("rate.conversion")

      Text(
        "Any app routed to the selected BlackHole works. Browsers and Spotify may not expose the original rate. 16ch is device capacity, not the file's channel count."
      )
      .font(.caption)
      .foregroundStyle(.tertiary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// One stage of the pipeline: a node on a vertical rail, its name and value.
  private func rateRow(
    _ title: String,
    value: String,
    identifier: String,
    isFirst: Bool,
    isLast: Bool
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(title.uppercased())
        .font(DownmixTheme.TypeScale.label)
        .tracking(0.6)
        .foregroundStyle(DownmixTheme.textSecondary)
        .frame(width: 72, alignment: .leading)
      Text(value)
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(DownmixTheme.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.leading, 20)
    .padding(.vertical, 6)
    .background(alignment: .leading) {
      VStack(spacing: 0) {
        Rectangle()
          .fill(isFirst ? Color.clear : DownmixTheme.accent.opacity(0.28))
          .frame(width: 1.5, height: 7)
        Circle()
          .fill(isLast ? DownmixTheme.good : DownmixTheme.panelTop)
          .overlay(
            Circle().strokeBorder(
              isLast ? DownmixTheme.good : DownmixTheme.accent.opacity(0.75), lineWidth: 1.5)
          )
          .shadow(color: isLast ? DownmixTheme.good.opacity(0.6) : .clear, radius: 4)
          .frame(width: 8, height: 8)
        Rectangle()
          .fill(isLast ? Color.clear : DownmixTheme.accent.opacity(0.28))
          .frame(width: 1.5)
          .frame(maxHeight: .infinity)
      }
      .frame(width: 8)
      .accessibilityHidden(true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title): \(value)")
    .accessibilityIdentifier(identifier)
  }
}
