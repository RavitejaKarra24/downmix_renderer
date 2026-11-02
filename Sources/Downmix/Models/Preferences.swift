import Foundation

enum SampleRateMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case automatic
  case followInput
  case fixed

  var id: Self { self }

  var title: String {
    switch self {
    case .automatic: "Automatic"
    case .followInput: "Follow input"
    case .fixed: "Fixed"
    }
  }
}

/// How the DAC's bit depth is chosen at each output rate.
enum OutputBitDepthMode: String, Codable, CaseIterable, Identifiable, Sendable {
  /// The source's own bit depth when known (open file header or decoder record),
  /// the nearest deeper one if the DAC lacks it, and the deepest for unknown sources.
  case matchSource
  /// Always the deepest the DAC offers; never truncates the float mix.
  case deepest

  var id: Self { self }

  var title: String {
    switch self {
    case .matchSource: "Match source"
    case .deepest: "Deepest available"
    }
  }
}

struct AppPreferences: Codable, Equatable, Sendable {
  var inputDeviceUID: String = ""
  var outputDeviceUID: String = ""
  var inputDeviceName: String = ""
  var outputDeviceName: String = ""
  var layoutPresetName: String = LayoutPreset.all[0].name
  var framesPerBuffer: Int = 128
  var preampDb: Double = -9.5
  var inputLatencyMs: Double = 10
  var outputLatencyMs: Double = 10
  var keepOutputAlive: Bool = false
  var lfeLowpass: Bool = true
  var swapOutputs: Bool = false
  var autoStart: Bool = false
  /// Allow the Music metadata adapter to inspect track rates. This does not select a rate mode.
  var matchMusicSampleRate: Bool = true
  var sampleRateMode: SampleRateMode = .automatic
  var fixedSampleRate: Double = 48000
  /// Explicit per-app rate declarations, keyed by bundle identifier or app name.
  /// These are user statements, not heuristics, and rank below decoder evidence.
  var appRateProfiles: [String: Double] = [:]
  var outputBitDepthMode: OutputBitDepthMode = .matchSource

  static let selectableSampleRates: [Double] = [
    8000, 16000, 44100, 48000, 88200, 96000, 176400, 192000,
    352800, 384000, 705600, 768000,
  ]

  static let storageURL: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
      .appendingPathComponent("Downmix", isDirectory: true)
    return dir.appendingPathComponent("preferences.json")
  }()

  static func load(from url: URL = storageURL) -> AppPreferences {
    guard let data = try? Data(contentsOf: url) else { return AppPreferences() }
    return (try? JSONDecoder().decode(AppPreferences.self, from: data)) ?? AppPreferences()
  }

  /// Encoding, directory creation, and atomic-write failures are reported to the caller.
  func save(to url: URL = Self.storageURL) throws {
    let data = try JSONEncoder().encode(self)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }

  private func normalized() -> AppPreferences {
    var result = self
    // Clamp before rounding to avoid overflow, including for Int.min/Int.max.
    // Round to the nearest multiple of 32; ties round upward.
    let clampedFrames = min(1024, max(32, framesPerBuffer))
    result.framesPerBuffer = ((clampedFrames + 16) / 32) * 32
    result.preampDb = preampDb.isFinite ? min(6, max(-30, preampDb)) : AppPreferences().preampDb
    result.layoutPresetName = LayoutPreset.named(layoutPresetName).name
    result.fixedSampleRate =
      fixedSampleRate.isFinite && Self.selectableSampleRates.contains(fixedSampleRate)
      ? fixedSampleRate : AppPreferences().fixedSampleRate
    result.appRateProfiles = appRateProfiles.filter { key, rate in
      !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && key.count <= 256
        && rate.isFinite && Self.selectableSampleRates.contains(rate)
    }
    return result
  }
}

// Keep Codable customization in an extension to preserve the memberwise initializer.
extension AppPreferences {
  private enum CodingKeys: String, CodingKey {
    case inputDeviceUID, outputDeviceUID, inputDeviceName, outputDeviceName
    case layoutPresetName, framesPerBuffer, preampDb, inputLatencyMs, outputLatencyMs
    case keepOutputAlive, lfeLowpass, swapOutputs, autoStart, matchMusicSampleRate
    case sampleRateMode, fixedSampleRate, appRateProfiles, outputBitDepthMode
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init()
    // Missing and null fields retain defaults. Incorrect types still throw so corrupt
    // preferences are not silently accepted as a partially decoded configuration.
    inputDeviceUID =
      try container.decodeIfPresent(String.self, forKey: .inputDeviceUID) ?? inputDeviceUID
    outputDeviceUID =
      try container.decodeIfPresent(String.self, forKey: .outputDeviceUID) ?? outputDeviceUID
    inputDeviceName =
      try container.decodeIfPresent(String.self, forKey: .inputDeviceName) ?? inputDeviceName
    outputDeviceName =
      try container.decodeIfPresent(String.self, forKey: .outputDeviceName) ?? outputDeviceName
    layoutPresetName =
      try container.decodeIfPresent(String.self, forKey: .layoutPresetName) ?? layoutPresetName
    framesPerBuffer =
      try container.decodeIfPresent(Int.self, forKey: .framesPerBuffer) ?? framesPerBuffer
    preampDb = try container.decodeIfPresent(Double.self, forKey: .preampDb) ?? preampDb
    inputLatencyMs =
      try container.decodeIfPresent(Double.self, forKey: .inputLatencyMs) ?? inputLatencyMs
    outputLatencyMs =
      try container.decodeIfPresent(Double.self, forKey: .outputLatencyMs) ?? outputLatencyMs
    keepOutputAlive =
      try container.decodeIfPresent(Bool.self, forKey: .keepOutputAlive) ?? keepOutputAlive
    lfeLowpass = try container.decodeIfPresent(Bool.self, forKey: .lfeLowpass) ?? lfeLowpass
    swapOutputs = try container.decodeIfPresent(Bool.self, forKey: .swapOutputs) ?? swapOutputs
    autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? autoStart
    matchMusicSampleRate =
      try container.decodeIfPresent(Bool.self, forKey: .matchMusicSampleRate)
      ?? matchMusicSampleRate
    // Legacy opt-out meant keeping the input's rate, not disabling universal playback.
    sampleRateMode =
      try container.decodeIfPresent(SampleRateMode.self, forKey: .sampleRateMode)
      ?? (matchMusicSampleRate ? .automatic : .followInput)
    fixedSampleRate =
      try container.decodeIfPresent(Double.self, forKey: .fixedSampleRate) ?? fixedSampleRate
    appRateProfiles =
      try container.decodeIfPresent([String: Double].self, forKey: .appRateProfiles)
      ?? appRateProfiles
    outputBitDepthMode =
      try container.decodeIfPresent(OutputBitDepthMode.self, forKey: .outputBitDepthMode)
      ?? outputBitDepthMode
    self = normalized()
  }

  func encode(to encoder: Encoder) throws {
    let preferences = normalized()
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(preferences.inputDeviceUID, forKey: .inputDeviceUID)
    try container.encode(preferences.outputDeviceUID, forKey: .outputDeviceUID)
    try container.encode(preferences.inputDeviceName, forKey: .inputDeviceName)
    try container.encode(preferences.outputDeviceName, forKey: .outputDeviceName)
    try container.encode(preferences.layoutPresetName, forKey: .layoutPresetName)
    try container.encode(preferences.framesPerBuffer, forKey: .framesPerBuffer)
    try container.encode(preferences.preampDb, forKey: .preampDb)
    try container.encode(preferences.inputLatencyMs, forKey: .inputLatencyMs)
    try container.encode(preferences.outputLatencyMs, forKey: .outputLatencyMs)
    try container.encode(preferences.keepOutputAlive, forKey: .keepOutputAlive)
    try container.encode(preferences.lfeLowpass, forKey: .lfeLowpass)
    try container.encode(preferences.swapOutputs, forKey: .swapOutputs)
    try container.encode(preferences.autoStart, forKey: .autoStart)
    try container.encode(preferences.matchMusicSampleRate, forKey: .matchMusicSampleRate)
    try container.encode(preferences.sampleRateMode, forKey: .sampleRateMode)
    try container.encode(preferences.fixedSampleRate, forKey: .fixedSampleRate)
    try container.encode(preferences.appRateProfiles, forKey: .appRateProfiles)
    try container.encode(preferences.outputBitDepthMode, forKey: .outputBitDepthMode)
  }
}
