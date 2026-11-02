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
    VStack(alignment: .leading, spacing: 8) {
      rateRow("Source", value: state.playbackSourceSummary, identifier: "rate.source")
      rateRow("Reported", value: state.reportedSourceRateText, identifier: "rate.reported")
      rateRow("Captured", value: state.capturedRateText, identifier: "rate.capture")
      rateRow("DSP", value: state.renderRateText, identifier: "rate.render")
      rateRow("DAC", value: state.dacRateText, identifier: "rate.dac")

      Text(state.rateConversionSummary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("rate.conversion")

      Text(
        "Any app routed to the selected BlackHole works. Browsers and Spotify may not expose the original rate. 16ch is device capacity, not the file's channel count."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func rateRow(_ title: String, value: String, identifier: String) -> some View {
    LabeledContent {
      Text(value)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
    } label: {
      Text(title)
    }
    .font(.callout)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(identifier)
  }
}
