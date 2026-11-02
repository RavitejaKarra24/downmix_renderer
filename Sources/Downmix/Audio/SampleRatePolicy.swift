import Foundation

/// Where a rate claim came from. Evidence outranks a user declaration, which outranks a
/// supported player's own metadata. Nothing is inferred from app identity or device PCM.
enum SampleRateEvidence: Equatable, Sendable {
  case decoder(pid: Int32)
  /// Header of the audio file the client has open (local players such as Kew).
  case file(pid: Int32, fileName: String)
  case profile(app: String)
  case music

  var label: String {
    switch self {
    case .decoder: "Decoder input log"
    case .file(_, let fileName): "Playing file \u{201C}\(fileName)\u{201D}"
    case .profile(let app): "Saved rate for \u{201C}\(app)\u{201D}"
    case .music: "Music track metadata"
    }
  }
}

/// Pure control-side policy. Source metadata is never inferred from device PCM or app
/// names; only a supported adapter or an explicit user profile for the routed client may
/// match. Multiple clients are allowed as long as their claims agree.
enum SampleRateDecision: Equatable, Sendable {
  case followingInput
  case fixed(Double)
  case matching(Double, SampleRateEvidence)
  case conflictingRates([Double])
  case decoderLogsUnavailable
  case discoveryUnavailable
  case awaitingSource
  case multipleSources
  case unknownSource
  case awaitingMetadata
  case automationDenied
  case invalidRate

  var requestedRate: Double? {
    switch self {
    case .fixed(let rate): rate
    case .matching(let rate, _): rate
    default: nil
    }
  }

  var sourceRate: Double? {
    if case .matching(let rate, _) = self { return rate }
    return nil
  }

  static func profileKey(for source: AudioPlaybackSource) -> String {
    if let bundle = source.bundleIdentifier, !bundle.isEmpty { return bundle }
    return source.name
  }

  static let musicBundleIdentifier = "com.apple.Music"

  /// `decoderRates` holds the latest decoder-log observation per routed client PID.
  /// `decoderEvidencePIDs` are clients that produced fresh decoder evidence during the
  /// current playback episode: once a client has spoken through its decoder, only its
  /// decoder may speak for it, so expiry holds the rate instead of falling back to a
  /// lower-priority profile or older player metadata.
  static func resolve(
    preferences: AppPreferences, sources: AudioSourceObservation,
    musicRate: Double?, musicFailure: MusicRateFailure?,
    decoderRates: [Int32: DecoderRateObservation] = [:],
    decoderEvidencePIDs: Set<Int32> = [],
    sourceFiles: [Int32: SourceFileObservation] = [:],
    musicIsIdle: Bool = false, now: Date = Date()
  ) -> SampleRateDecision {
    switch preferences.sampleRateMode {
    case .followInput: return .followingInput
    case .fixed:
      return InputRateConverter.supportedDeviceRates.contains(preferences.fixedSampleRate)
        ? .fixed(preferences.fixedSampleRate) : .invalidRate
    case .automatic:
      guard sources.isAvailable else { return .discoveryUnavailable }
      guard !sources.sources.isEmpty else { return .awaitingSource }

      // A live claim comes from something playing now (decoder log, an open file being
      // read, Music's current track). A passive claim is a standing declaration (a saved
      // app rate) or a paused file. Live claims outrank other apps' passive ones, so an
      // idle browser with a saved rate cannot block a local player; claims disagreeing
      // within the deciding tier still hold the rate.
      var claims: [(rate: Double, evidence: SampleRateEvidence, live: Bool)] = []
      var sawUnsupportedEvidence = false
      var heldByExpiredDecoder = false
      let supported: (Double) -> Bool = InputRateConverter.supportedDeviceRates.contains
      for source in sources.sources {
        let isMusic = source.bundleIdentifier == musicBundleIdentifier
        // A paused Music client is not playing anything, so it claims nothing —
        // not through lingering decoder logs, a profile, or cached metadata.
        if isMusic, musicIsIdle { continue }
        if let decoder = decoderRates[source.id], decoder.isAvailable,
          decoder.sourcePID == source.id, let rate = decoder.sampleRate,
          let date = decoder.date, DecoderInputRateParser.isFresh(date, now: now)
        {
          if supported(rate) {
            claims.append((rate, .decoder(pid: source.id), true))
          } else {
            sawUnsupportedEvidence = true
          }
          continue
        }
        if decoderEvidencePIDs.contains(source.id) {
          heldByExpiredDecoder = true
          continue
        }
        // The open file's header is the source's own format, not a declaration.
        if let file = sourceFiles[source.id], file.sourcePID == source.id,
          let format = file.format
        {
          if supported(format.sampleRate) {
            claims.append(
              (
                format.sampleRate, .file(pid: source.id, fileName: format.fileName),
                !file.isIdle
              ))
          } else {
            sawUnsupportedEvidence = true
          }
          continue
        }
        let key = profileKey(for: source)
        if let profile = preferences.appRateProfiles[key], supported(profile) {
          claims.append((profile, .profile(app: source.name), false))
          continue
        }
        if isMusic, preferences.matchMusicSampleRate, musicFailure == nil, let rate = musicRate {
          if supported(rate) {
            claims.append((rate, .music, true))
          } else {
            sawUnsupportedEvidence = true
          }
        }
      }

      if claims.isEmpty {
        if sawUnsupportedEvidence { return .invalidRate }
        if decoderRates.values.contains(where: { !$0.isAvailable }) {
          return .decoderLogsUnavailable
        }
        if musicFailure == .automationDenied { return .automationDenied }
        if sources.sources.count > 1 { return .multipleSources }
        if heldByExpiredDecoder { return .unknownSource }
        if sources.sources[0].bundleIdentifier == musicBundleIdentifier, !musicIsIdle {
          return .awaitingMetadata
        }
        return .unknownSource
      }

      // Highest-priority evidence for each distinct rate wins the comparison.
      let deciding = claims.contains(where: \.live) ? claims.filter(\.live) : claims
      let ordered = deciding.sorted { priority($0.evidence) < priority($1.evidence) }
      let distinct = Set(ordered.map(\.rate))
      guard distinct.count == 1, let first = ordered.first else {
        return .conflictingRates(distinct.sorted())
      }
      return .matching(first.rate, first.evidence)
    }
  }

  private static func priority(_ evidence: SampleRateEvidence) -> Int {
    switch evidence {
    case .decoder: 0
    case .file: 1
    case .profile: 2
    case .music: 3
    }
  }
}
