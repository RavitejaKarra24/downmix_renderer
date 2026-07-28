import Foundation

struct EQProfile: Identifiable, Codable, Hashable, Sendable {
  var id: UUID = UUID()
  var name: String
  var swapOutputs: Bool
  var globalPEQText: String
  var speakerPEQText: String
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
  var globalPEQText: String = ""
  var speakerPEQText: String = ""
  var eqProfiles: [EQProfile] = []
  var activeEQProfileID: UUID?
  var autoStart: Bool = false

  static let storageURL: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
      .appendingPathComponent("Downmix", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("preferences.json")
  }()

  static func load() -> AppPreferences {
    guard let data = try? Data(contentsOf: storageURL) else { return AppPreferences() }
    return (try? JSONDecoder().decode(AppPreferences.self, from: data)) ?? AppPreferences()
  }

  func save() {
    guard let data = try? JSONEncoder().encode(self) else { return }
    try? data.write(to: Self.storageURL, options: .atomic)
  }
}
