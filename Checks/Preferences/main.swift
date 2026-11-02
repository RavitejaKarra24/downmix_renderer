import Foundation

func require(_ condition: Bool, _ message: String) {
  guard condition else { fatalError("FAIL: \(message)") }
}

func decode(_ json: String) throws -> AppPreferences {
  try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))
}

func requireThrows(_ message: String, _ operation: () throws -> Void) {
  do {
    try operation()
  } catch {
    return
  }
  fatalError("FAIL: \(message)")
}

let defaults = AppPreferences()
require(try decode("{}") == defaults, "empty object retains every default")
require(defaults.sampleRateMode == .automatic, "new preferences use Automatic")
require(defaults.fixedSampleRate == 48000, "default fixed rate is 48 kHz")
require(defaults.matchMusicSampleRate, "Music adapter is allowed by default")
require(
  AppPreferences.selectableSampleRates == [
    8000, 16000, 44100, 48000, 88200, 96000, 176400, 192000,
    352800, 384000, 705600, 768000,
  ], "selectable rates match the approved bounded list")

let populated = AppPreferences(
  inputDeviceUID: "input-uid", outputDeviceUID: "output-uid",
  inputDeviceName: "Input", outputDeviceName: "Output",
  layoutPresetName: "7.1.4", framesPerBuffer: 256, preampDb: -3,
  inputLatencyMs: 12, outputLatencyMs: 15,
  keepOutputAlive: true, lfeLowpass: false, swapOutputs: true, autoStart: true,
  sampleRateMode: .fixed, fixedSampleRate: 96000)
let populatedData = try JSONEncoder().encode(populated)
require(
  try JSONDecoder().decode(AppPreferences.self, from: populatedData) == populated,
  "all fields round-trip in memory")

let populatedObject = try JSONSerialization.jsonObject(with: populatedData) as! [String: Any]
let defaultsObject =
  try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as! [String: Any]
for key in populatedObject.keys {
  var missing = populatedObject
  missing.removeValue(forKey: key)
  var expected = populatedObject
  expected[key] = defaultsObject[key]
  let missingPreferences = try JSONDecoder().decode(
    AppPreferences.self, from: JSONSerialization.data(withJSONObject: missing))
  let expectedPreferences = try JSONDecoder().decode(
    AppPreferences.self, from: JSONSerialization.data(withJSONObject: expected))
  require(
    missingPreferences == expectedPreferences, "missing \(key) defaults without losing siblings")
  require(try decode("{\"\(key)\":null}") == defaults, "null \(key) retains its default")

  // Objects are the wrong type for every scalar field; arrays for the profile map.
  // Neither may be swallowed.
  let wrongType = key == "appRateProfiles" ? "[]" : "{}"
  do {
    _ = try decode("{\"\(key)\":\(wrongType)}")
    fatalError("FAIL: malformed \(key) should throw")
  } catch DecodingError.typeMismatch(_, let context) {
    require(context.codingPath.last?.stringValue == key, "type error identifies \(key)")
  }
}

let legacy = try decode(
  """
  {"inputDeviceUID":"legacy-input","outputDeviceName":"Legacy output",
   "framesPerBuffer":256,"preampDb":-12,"futureSetting":true}
  """)
var expectedLegacy = defaults
expectedLegacy.inputDeviceUID = "legacy-input"
expectedLegacy.outputDeviceName = "Legacy output"
expectedLegacy.framesPerBuffer = 256
expectedLegacy.preampDb = -12
require(legacy == expectedLegacy, "legacy fields survive absent new fields and unknown keys")

for allowed in [true, false] {
  let migrated = try decode(
    "{\"matchMusicSampleRate\":\(allowed),\"outputDeviceUID\":\"saved-output\"}")
  require(
    migrated.sampleRateMode == (allowed ? .automatic : .followInput),
    "legacy Music adapter setting migrates to the corresponding mode")
  require(migrated.matchMusicSampleRate == allowed, "migration preserves adapter permission")
  require(migrated.fixedSampleRate == 48000, "migration supplies a default fixed rate")
  require(migrated.outputDeviceUID == "saved-output", "migration preserves saved route")
  require(
    try decode("{\"matchMusicSampleRate\":\(allowed),\"sampleRateMode\":null}").sampleRateMode
      == migrated.sampleRateMode,
    "null mode uses the legacy migration policy")

  for mode in SampleRateMode.allCases {
    let explicit = try decode(
      "{\"matchMusicSampleRate\":\(allowed),\"sampleRateMode\":\"\(mode.rawValue)\"}")
    require(explicit.sampleRateMode == mode, "explicit mode overrides legacy adapter setting")
    var preferences = populated
    preferences.matchMusicSampleRate = allowed
    preferences.sampleRateMode = mode
    let data = try JSONEncoder().encode(preferences)
    require(
      try JSONDecoder().decode(AppPreferences.self, from: data) == preferences,
      "every mode round-trips independently of adapter permission")
  }
}

for rate in AppPreferences.selectableSampleRates {
  let preferences = try decode("{\"sampleRateMode\":\"fixed\",\"fixedSampleRate\":\(rate)}")
  require(preferences.fixedSampleRate == rate, "selectable fixed rate \(rate) survives decoding")
  require(
    try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
      == preferences,
    "selectable fixed rate \(rate) round-trips")
}
for rate in [-48000.0, 0, 1, 44099, 48000.5, 123456, Double.greatestFiniteMagnitude] {
  require(
    try decode("{\"fixedSampleRate\":\(rate)}").fixedSampleRate == 48000,
    "unlisted decoded fixed rate defaults to 48 kHz")
}
let nonFiniteRateDecoder = JSONDecoder()
nonFiniteRateDecoder.nonConformingFloatDecodingStrategy = .convertFromString(
  positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
for token in ["Infinity", "-Infinity", "NaN"] {
  let preferences = try nonFiniteRateDecoder.decode(
    AppPreferences.self, from: Data("{\"fixedSampleRate\":\"\(token)\"}".utf8))
  require(preferences.fixedSampleRate == 48000, "non-finite decoded fixed rate defaults")
}
for rate in [Double.nan, .infinity, -.infinity, -1, 0, 48000.5, 123456] {
  var preferences = populated
  preferences.fixedSampleRate = rate
  let data = try JSONEncoder().encode(preferences)
  let normalized = try JSONDecoder().decode(AppPreferences.self, from: data)
  require(normalized.fixedSampleRate == 48000, "encoding sanitizes invalid fixed rates")
  require(normalized.sampleRateMode == .fixed, "sanitizing a rate preserves the selected mode")
}

// DAC bit-depth mode: Match source by default, strict decoding, round trip.
require(defaults.outputBitDepthMode == .matchSource, "DAC depth defaults to Match source")
for mode in OutputBitDepthMode.allCases {
  var preferences = defaults
  preferences.outputBitDepthMode = mode
  require(
    try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
      == preferences, "DAC depth mode \(mode) round-trips")
}
require(
  try decode("{\"outputBitDepthMode\":\"deepest\"}").outputBitDepthMode == .deepest,
  "DAC depth mode decodes")
for json in ["{\"outputBitDepthMode\":\"exact\"}", "{\"outputBitDepthMode\":24}"] {
  requireThrows("malformed DAC depth mode must throw: \(json)") { _ = try decode(json) }
}

// Per-app rate declarations persist, but only valid keys with selectable rates survive.
var profiled = defaults
profiled.appRateProfiles = ["kew": 96000, "app.zen-browser.zen": 48000]
require(
  try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(profiled)) == profiled,
  "saved app rate profiles round-trip")
let mixedProfiles = try decode(
  """
  {"appRateProfiles":{"kew":96000,"bad-rate":44099,"zero":0,"neg":-48000,"   ":48000,
  "huge":1e300,"\(String(repeating: "k", count: 257))":48000,"ok":384000}}
  """)
require(
  mixedProfiles.appRateProfiles == ["kew": 96000, "ok": 384000],
  "invalid profile keys and unselectable rates are dropped on decode")
var unsanitized = defaults
unsanitized.appRateProfiles = ["kew": 96000, "nan": .nan, "inf": .infinity, "": 48000]
require(
  try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(unsanitized))
    .appRateProfiles == ["kew": 96000],
  "encoding sanitizes in-memory profile edits")
for json in [
  "{\"appRateProfiles\":[]}", "{\"appRateProfiles\":{\"kew\":\"96000\"}}",
  "{\"appRateProfiles\":{\"kew\":true}}", "{\"appRateProfiles\":\"kew\"}",
] {
  requireThrows("malformed profile map must throw: \(json)") { _ = try decode(json) }
}

for json in [
  "{\"framesPerBuffer\":\"128\"}", "{\"framesPerBuffer\":32.5}",
  "{\"preampDb\":\"-9.5\"}", "{\"autoStart\":1}", "{\"inputDeviceUID\":false}",
  "{\"sampleRateMode\":\"unknown\"}", "{\"sampleRateMode\":false}",
  "{\"fixedSampleRate\":\"48000\"}", "{\"fixedSampleRate\":\"NaN\"}",
  "{\"fixedSampleRate\":true}", "{\"matchMusicSampleRate\":\"false\"}",
  "[]", "null", "not json",
] {
  requireThrows("malformed JSON/types must throw: \(json)") { _ = try decode(json) }
}

for (input, expected) in [
  (Int.min, 32), (-1, 32), (0, 32), (31, 32), (32, 32), (47, 32),
  (48, 64), (63, 64), (64, 64), (127, 128), (128, 128), (129, 128),
  (1007, 992), (1008, 1024), (1024, 1024), (1025, 1024), (Int.max, 1024),
] {
  require(
    try decode("{\"framesPerBuffer\":\(input)}").framesPerBuffer == expected,
    "buffer \(input) normalizes to \(expected)")
}
for frames in stride(from: 32, through: 1024, by: 32) {
  require(
    try decode("{\"framesPerBuffer\":\(frames)}").framesPerBuffer == frames,
    "valid buffer \(frames) stays unchanged")
}
for (input, expected) in [(-100.0, -30.0), (-30, -30), (-9.5, -9.5), (6, 6), (100, 6)] {
  require(
    try decode("{\"preampDb\":\(input)}").preampDb == expected,
    "preamp \(input) normalizes to \(expected)")
}
let nonFiniteDecoder = JSONDecoder()
nonFiniteDecoder.nonConformingFloatDecodingStrategy = .convertFromString(
  positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
for token in ["Infinity", "-Infinity", "NaN"] {
  let preferences = try nonFiniteDecoder.decode(
    AppPreferences.self, from: Data("{\"preampDb\":\"\(token)\"}".utf8))
  require(preferences.preampDb == defaults.preampDb, "non-finite decoded preamp defaults")
}
for preset in LayoutPreset.all {
  for name in [preset.name, preset.id] {
    require(
      try decode("{\"layoutPresetName\":\"\(name)\"}").layoutPresetName == preset.name,
      "known layout names and IDs canonicalize")
  }
}
for name in ["unknown-layout", ""] {
  require(
    try decode("{\"layoutPresetName\":\"\(name)\"}").layoutPresetName == defaults.layoutPresetName,
    "unknown layout defaults")
}
for preamp in [Double.nan, .infinity, -.infinity] {
  var preferences = populated
  preferences.preampDb = preamp
  let data = try JSONEncoder().encode(preferences)
  require(
    try JSONDecoder().decode(AppPreferences.self, from: data).preampDb == defaults.preampDb,
    "encoding also normalizes non-finite preamp")
}

// Explicit temporary URLs throughout: never load or save real user preferences.
let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
  "downmix-preferences-check-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
let storage = temporaryDirectory.appendingPathComponent("nested/preferences.json")
require(AppPreferences.load(from: storage) == defaults, "missing file loads defaults")
require(
  !FileManager.default.fileExists(atPath: storage.deletingLastPathComponent().path),
  "loading does not create directories")
try populated.save(to: storage)
require(AppPreferences.load(from: storage) == populated, "save creates parents and round-trips")

var unnormalized = populated
unnormalized.framesPerBuffer = Int.max
unnormalized.preampDb = 100
unnormalized.layoutPresetName = "removed-layout"
unnormalized.fixedSampleRate = .infinity
try unnormalized.save(to: storage)
var expectedNormalized = populated
expectedNormalized.framesPerBuffer = 1024
expectedNormalized.preampDb = 6
expectedNormalized.layoutPresetName = defaults.layoutPresetName
expectedNormalized.fixedSampleRate = defaults.fixedSampleRate
require(AppPreferences.load(from: storage) == expectedNormalized, "save normalizes edited values")
require(unnormalized.preampDb == 100, "saving does not mutate the caller")

let savedData = try Data(contentsOf: storage)
var unencodable = populated
unencodable.inputLatencyMs = .infinity
requireThrows("encoding errors are surfaced") { try unencodable.save(to: storage) }
require(try Data(contentsOf: storage) == savedData, "failed encoding preserves existing file")

let blocker = temporaryDirectory.appendingPathComponent("not-a-directory")
try Data("blocker".utf8).write(to: blocker)
requireThrows("directory creation errors are surfaced") {
  try populated.save(to: blocker.appendingPathComponent("preferences.json"))
}
requireThrows("atomic write errors are surfaced") { try populated.save(to: temporaryDirectory) }
require(try Data(contentsOf: storage) == savedData, "failed saves preserve unrelated preferences")

for corrupt in [
  "{\"autoStart\":\"yes\"}", "{\"sampleRateMode\":\"unknown\"}",
  "{\"fixedSampleRate\":\"48000\"}", "not json", "[]",
] {
  try Data(corrupt.utf8).write(to: storage, options: .atomic)
  require(AppPreferences.load(from: storage) == defaults, "corrupt file falls back to defaults")
}
print("Preferences checks passed")
