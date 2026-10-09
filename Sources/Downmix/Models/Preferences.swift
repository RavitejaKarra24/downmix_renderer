import Foundation

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
    return result
  }
}

// Keep Codable customization in an extension to preserve the memberwise initializer.
extension AppPreferences {
  private enum CodingKeys: String, CodingKey {
    case inputDeviceUID, outputDeviceUID, inputDeviceName, outputDeviceName
    case layoutPresetName, framesPerBuffer, preampDb, inputLatencyMs, outputLatencyMs
    case keepOutputAlive, lfeLowpass, swapOutputs, autoStart
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
  }
}
