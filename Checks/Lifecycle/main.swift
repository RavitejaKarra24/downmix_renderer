import AVFoundation
import CoreAudio
import Foundation
import Observation

// The real AudioEngine is compiled for conformance coverage but never instantiated here.
final class FakeEngine: AudioEngineControlling {
  struct Start: Equatable {
    let input: AudioDeviceID
    let output: AudioDeviceID
    let configuration: DownmixProcessor.Configuration
    let frames: Int
    let keepAlive: Bool
  }

  enum Event: Equatable {
    case start(Start)
    case configuration(DownmixProcessor.Configuration)
    case stop
  }

  var events: [Event] = []
  var requestedRates: [Double] = []
  /// Every DAC bit-depth request (`nil` = deepest), in order.
  var requestedBitDepths: [Int?] = []
  var startFailure: Error?
  var fatalStartStatus: EngineStatus?
  private var statusHandler: ((EngineStatus) -> Void)?

  var starts: [Start] {
    events.compactMap {
      if case .start(let start) = $0 { return start }
      return nil
    }
  }

  func setStatusHandler(_ handler: @escaping (EngineStatus) -> Void) {
    statusHandler = handler
  }

  func start(
    inputDeviceID: AudioDeviceID,
    outputDeviceID: AudioDeviceID,
    configuration: DownmixProcessor.Configuration,
    framesPerBuffer: Int,
    keepAliveOnly: Bool
  ) throws {
    events.append(
      .start(
        .init(
          input: inputDeviceID, output: outputDeviceID, configuration: configuration,
          frames: framesPerBuffer, keepAlive: keepAliveOnly
        )))
    emit(EngineStatus(phase: .starting))
    if let startFailure {
      if let fatalStartStatus { emit(fatalStartStatus) }
      throw startFailure
    }
    emit(fatalStartStatus ?? EngineStatus(phase: keepAliveOnly ? .keepAlive : .running))
  }

  func updateConfiguration(_ configuration: DownmixProcessor.Configuration) {
    events.append(.configuration(configuration))
  }

  func setInputSampleRate(_ rate: Double) {
    requestedRates.append(rate)
  }

  func setOutputBitDepth(_ bits: Int?) {
    requestedBitDepths.append(bits)
  }

  func stop() {
    events.append(.stop)
    emit(EngineStatus(phase: .stopping))
    emit(EngineStatus(phase: .stopped))
  }

  func emit(_ status: EngineStatus) {
    precondition(Thread.isMainThread, "Fake status delivery must match the production contract")
    statusHandler?(status)
  }
}

@MainActor
final class Fixture {
  static let input = AudioDeviceInfo(
    id: 101, name: "BlackHole 16ch", uid: "input-1", inputChannelCount: 16,
    outputChannelCount: 0, nominalSampleRate: 48_000)
  static let secondInput = AudioDeviceInfo(
    id: 102, name: "Alternate 16ch", uid: "input-2", inputChannelCount: 16,
    outputChannelCount: 0, nominalSampleRate: 48_000)
  static let output = AudioDeviceInfo(
    id: 201, name: "Speakers", uid: "output-1", inputChannelCount: 0,
    outputChannelCount: 2, nominalSampleRate: 48_000)
  static let secondOutput = AudioDeviceInfo(
    id: 202, name: "Headphones", uid: "output-2", inputChannelCount: 0,
    outputChannelCount: 2, nominalSampleRate: 48_000)

  let engine = FakeEngine()
  var catalog = [input, secondInput, output, secondOutput]
  var enumerations = 0
  var permissionQueries = 0
  var permissionStatus = AVAuthorizationStatus.authorized
  var permissionCompletion: (@Sendable (Bool) -> Void)?
  var permissionRequests = 0
  var safeRoute = true
  var writes: [AppPreferences] = []
  var writeFailure: Error?

  func makeState(
    _ preferences: AppPreferences = AppPreferences(),
    musicRateMonitor: (any MusicRateMonitoring)? = nil,
    audioSourceMonitor: (any AudioSourceMonitoring)? = nil,
    decoderMonitors: FakeDecoderMonitors? = nil,
    fileMonitors: FakeSourceFileMonitors? = nil,
    rateMatchDelay: Duration = .zero
  ) -> AppState {
    var factory: (@MainActor () -> any DecoderRateMonitoring)?
    if let decoderMonitors { factory = { decoderMonitors.make() } }
    var fileFactory: (@MainActor () -> any SourceFileMonitoring)?
    if let fileMonitors { fileFactory = { fileMonitors.make() } }
    return AppState(
      engine: engine,
      preferences: preferences,
      deviceCatalog: { [self] in
        enumerations += 1
        return catalog
      },
      permissionStatusProvider: { [self] in
        permissionQueries += 1
        return permissionStatus
      },
      permissionRequestProvider: { [self] completion in
        permissionRequests += 1
        permissionCompletion = completion
      },
      routeSafetyProvider: { [self] _, _ in safeRoute },
      preferenceWriter: { [self] preferences in
        if let writeFailure { throw writeFailure }
        writes.append(preferences)
      },
      installListeners: false,
      musicRateMonitor: musicRateMonitor, audioSourceMonitor: audioSourceMonitor,
      decoderRateMonitorFactory: factory,
      sourceFileMonitorFactory: fileFactory,
      rateMatchDelay: rateMatchDelay
    )
  }
}

/// Records AppState's monitor lifecycle and replays Music rate observations on demand.
final class FakeMusicRateMonitor: MusicRateMonitoring {
  private(set) var starts = 0
  private(set) var stops = 0
  private(set) var callbacks: [@Sendable (MusicRateObservation) -> Void] = []
  private var report: (@Sendable (MusicRateObservation) -> Void)?

  func start(report: @escaping @Sendable (MusicRateObservation) -> Void) {
    precondition(Thread.isMainThread)
    starts += 1
    callbacks.append(report)
    self.report = report
  }

  func stop() {
    precondition(Thread.isMainThread)
    stops += 1
    report = nil
  }

  func emit(_ observation: MusicRateObservation) {
    precondition(Thread.isMainThread)
    report?(observation)
  }
}

/// Read-only client discovery fixture; callbacks are retained to exercise late reports.
final class FakeAudioSourceMonitor: AudioSourceMonitoring {
  static let music = AudioPlaybackSource(
    id: 501, name: "Music", bundleIdentifier: "com.apple.Music")
  static let kew = AudioPlaybackSource(id: 502, name: "kew", bundleIdentifier: nil)
  var observation = AudioSourceObservation(sources: [music])
  private(set) var starts: [AudioDeviceID] = []
  private(set) var stops = 0
  private(set) var callbacks: [@Sendable (AudioSourceObservation) -> Void] = []
  private var report: (@Sendable (AudioSourceObservation) -> Void)?

  func start(
    inputDeviceID: AudioDeviceID, report: @escaping @Sendable (AudioSourceObservation) -> Void
  ) {
    precondition(Thread.isMainThread)
    starts.append(inputDeviceID)
    callbacks.append(report)
    self.report = report
    report(observation)
  }

  func stop() {
    stops += 1
    report = nil
  }

  func emit(_ observation: AudioSourceObservation) {
    self.observation = observation
    report?(observation)
  }
}

final class FakeDecoderRateMonitor: DecoderRateMonitoring {
  private(set) var starts: [AudioPlaybackSource] = []
  private(set) var stops = 0
  private(set) var callbacks: [@Sendable (DecoderRateObservation) -> Void] = []
  private var report: (@Sendable (DecoderRateObservation) -> Void)?
  var isActive: Bool { report != nil }

  func start(
    source: AudioPlaybackSource, report: @escaping @Sendable (DecoderRateObservation) -> Void
  ) {
    starts.append(source)
    callbacks.append(report)
    self.report = report
  }

  func stop() {
    stops += 1
    report = nil
  }
  func emit(_ observation: DecoderRateObservation) { report?(observation) }
}

/// AppState creates one decoder monitor per routed client; this records each of them.
@MainActor
final class FakeDecoderMonitors {
  private(set) var created: [FakeDecoderRateMonitor] = []

  func make() -> any DecoderRateMonitoring {
    let monitor = FakeDecoderRateMonitor()
    created.append(monitor)
    return monitor
  }

  /// The live monitor reading this client's logs, if any.
  func active(_ pid: Int32) -> FakeDecoderRateMonitor? {
    created.last { $0.isActive && $0.starts.last?.id == pid }
  }

  var activePIDs: Set<Int32> { Set(created.filter(\.isActive).compactMap { $0.starts.last?.id }) }

  func emit(_ observation: DecoderRateObservation, for pid: Int32) {
    active(pid)?.emit(observation)
  }
}

final class FakeSourceFileMonitor: SourceFileMonitoring {
  private(set) var starts: [AudioPlaybackSource] = []
  private var report: (@Sendable (SourceFileObservation) -> Void)?
  var isActive: Bool { report != nil }

  func start(
    source: AudioPlaybackSource, report: @escaping @Sendable (SourceFileObservation) -> Void
  ) {
    starts.append(source)
    self.report = report
  }

  func stop() { report = nil }
  func emit(_ observation: SourceFileObservation) { report?(observation) }
}

/// AppState creates one open-file monitor per routed client; this records each of them.
@MainActor
final class FakeSourceFileMonitors {
  private(set) var created: [FakeSourceFileMonitor] = []

  func make() -> any SourceFileMonitoring {
    let monitor = FakeSourceFileMonitor()
    created.append(monitor)
    return monitor
  }

  var activePIDs: Set<Int32> { Set(created.filter(\.isActive).compactMap { $0.starts.last?.id }) }

  /// Reports the file a client is playing (`nil` format: nothing open).
  func play(
    _ pid: Int32, rate: Double? = nil, bits: Int? = 24, name: String = "track.flac",
    idle: Bool = false
  ) {
    let format = rate.map {
      SourceFileFormat(fileName: name, sampleRate: $0, bitDepth: bits, channels: 2)
    }
    created.last { $0.isActive && $0.starts.last?.id == pid }?.emit(
      SourceFileObservation(sourcePID: pid, format: format, isIdle: idle))
  }
}

/// Observation callbacks are Sendable; record invalidations without actor assumptions.
final class ChangeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var changes: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func record() {
    lock.lock()
    defer { lock.unlock() }
    count += 1
  }
}

struct CheckFailure: Error, LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

@main
struct LifecycleChecks {
  @MainActor
  static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(message: message) }
  }

  static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw CheckFailure(message: message) }
    return value
  }

  @MainActor
  static func main() async throws {
    try catalogChecks()
    try transportChecks()
    try selectionChecks()
    try configurationChecks()
    try automaticLaunchChecks()
    try nameOnlySavedRouteChecks()
    try disconnectChecks()
    try errorChecks()
    try setupChecks()
    try retryChecks()
    try diagnosticsChecks()
    try await persistenceChecks()
    try await permissionChecks()
    try loggingChecks()
    try musicRateChecks()
    try await universalRateChecks()
    try decoderRateChecks()
    try sourceFileChecks()
    print("All AppState lifecycle checks passed (18 groups)")
  }

  static let zen = AudioPlaybackSource(
    id: 503, name: "Zen", bundleIdentifier: "app.zen-browser.zen")

  @MainActor
  static func decoderRateChecks() throws {
    // A. Decoder evidence for a non-Music client: PID, freshness and expiry.
    let clients = FakeAudioSourceMonitor()
    clients.observation = AudioSourceObservation(sources: [FakeAudioSourceMonitor.kew])
    let monitors = FakeDecoderMonitors()
    let fixture = Fixture()
    let state = fixture.makeState(audioSourceMonitor: clients, decoderMonitors: monitors)
    state.start()
    try require(monitors.activePIDs == [502], "Auto reads logs for the routed client")
    let now = Date()
    monitors.emit(.init(sourcePID: 999, sampleRate: 96_000, date: now), for: 502)
    try require(
      fixture.engine.requestedRates.isEmpty, "A different PID's decoder cannot switch this source")
    monitors.emit(
      .init(sourcePID: 502, sampleRate: 96_000, date: now.addingTimeInterval(-20)), for: 502)
    try require(fixture.engine.requestedRates.isEmpty, "A stale decoder log cannot switch a source")
    monitors.emit(.init(sourcePID: 502, sampleRate: 96_000, date: now), for: 502)
    try require(
      fixture.engine.requestedRates == [96_000],
      "Fresh decoder input enables automatic matching outside Music")
    try require(state.reportedSourceRateText.contains("Decoder input"), "Evidence type is visible")
    monitors.emit(.init(sourcePID: 502), for: 502)
    try require(
      fixture.engine.requestedRates == [96_000], "Expired evidence holds the current device rate")
    try require(
      state.reportedSourceRateText.contains("Unknown"),
      "Expiry does not masquerade as a verified source")
    try require(
      state.sampleRateSummary.contains("no rate claimed"),
      "Expired decoder evidence returns to an explicit unknown state")

    // B. Evidence is per client: a second (silent) client no longer blocks decoder evidence.
    clients.emit(.init(sources: [FakeAudioSourceMonitor.music, FakeAudioSourceMonitor.kew]))
    try require(monitors.activePIDs == [501, 502], "Every routed client gets its own log reader")
    try require(
      monitors.created.filter { $0.starts.last?.id == 502 }.count == 1,
      "An unchanged client keeps its reader across client-set changes")
    monitors.emit(.init(sourcePID: 502, sampleRate: 192_000, date: Date()), for: 502)
    try require(
      fixture.engine.requestedRates == [96_000, 192_000],
      "Fresh decoder evidence switches while another client is routed")
    let departed = try unwrap(monitors.active(502), "kew reader is active")
    clients.emit(.init(sources: [FakeAudioSourceMonitor.music]))
    try require(!departed.isActive, "A departed client's reader stops")
    departed.callbacks.last?(.init(sourcePID: 502, sampleRate: 44_100, date: Date()))
    try require(
      fixture.engine.requestedRates == [96_000, 192_000],
      "A departed client's late log report cannot switch")
    clients.emit(.init(sources: [FakeAudioSourceMonitor.kew]))
    monitors.emit(.init(sourcePID: 502, isAvailable: false), for: 502)
    try require(
      state.sampleRateSummary.contains("unavailable"),
      "Restricted logs are explained without guessing")
    state.preferences.sampleRateMode = .followInput
    state.rateSettingsChanged()
    try require(monitors.activePIDs.isEmpty, "Follow input stops all log polling")
    for monitor in monitors.created {
      monitor.callbacks.last?(.init(sourcePID: 502, sampleRate: 192_000, date: Date()))
    }
    try require(
      fixture.engine.requestedRates == [96_000, 192_000], "Follow input ignores all log callbacks")
    state.stop()

    // C. Saved per-app rates for players that expose no evidence (Kew, browsers).
    let kewClients = FakeAudioSourceMonitor()
    kewClients.observation = AudioSourceObservation(sources: [FakeAudioSourceMonitor.kew])
    let profileFixture = Fixture()
    let profiles = profileFixture.makeState(
      audioSourceMonitor: kewClients, decoderMonitors: FakeDecoderMonitors())
    profiles.start()
    try require(
      profileFixture.engine.requestedRates.isEmpty
        && profiles.sampleRateSummary.contains("Save a rate"),
      "No evidence and no profile changes nothing and says how to fix it")
    profiles.saveRateProfile(96_000, for: "kew")
    try require(
      profileFixture.engine.requestedRates == [96_000],
      "Kew with a saved 96 kHz profile switches to 96 kHz")
    try require(
      profiles.reportedSourceRateText.contains("Saved rate for"), "The winning evidence is named")
    profiles.saveRateProfile(44_100, for: "kew")
    try require(
      profileFixture.engine.requestedRates == [96_000, 44_100], "A changed profile applies")
    try require(
      profiles.routedAppRows.first?.savedRate == 44_100, "The profile is reported per app")
    profiles.saveRateProfile(22_050, for: "kew")
    profiles.saveRateProfile(96_000, for: "  ")
    try require(
      profiles.preferences.appRateProfiles == ["kew": 44_100],
      "Unsavable rates and blank keys are rejected")
    try require(profiles.currentRateForProfile == nil, "No current rate offered without capture")
    profileFixture.engine.emit(
      EngineStatus(phase: .running, inputSampleRate: 88_200, renderSampleRate: 88_200))
    try require(profiles.currentRateForProfile == 88_200, "The live device rate is offered")
    profiles.saveCurrentRateProfile(for: "kew")
    try require(
      profiles.preferences.appRateProfiles["kew"] == 88_200,
      "One click saves the current device rate for the app")
    try require(
      profileFixture.engine.requestedRates == [96_000, 44_100],
      "Saving the rate the device already has requests nothing")
    profiles.removeRateProfile(for: "kew")
    try require(profiles.routedAppRows.first?.savedRate == nil, "A profile can be removed")
    try require(
      profiles.sampleRateSummary.contains("no rate claimed"), "Removal returns to unknown")
    profiles.stop()

    // D. A profile never overrides decoder evidence, even after that evidence expires.
    let mixedClients = FakeAudioSourceMonitor()
    mixedClients.observation = AudioSourceObservation(sources: [FakeAudioSourceMonitor.kew])
    let decoders = FakeDecoderMonitors()
    let precedenceFixture = Fixture()
    var declared = AppPreferences()
    declared.appRateProfiles = ["kew": 44_100]
    let precedence = precedenceFixture.makeState(
      declared, audioSourceMonitor: mixedClients, decoderMonitors: decoders)
    precedence.start()
    try require(precedenceFixture.engine.requestedRates == [44_100], "The profile applies first")
    decoders.emit(.init(sourcePID: 502, sampleRate: 96_000, date: Date()), for: 502)
    try require(
      precedenceFixture.engine.requestedRates == [44_100, 96_000],
      "Fresh decoder input outranks the saved profile")
    precedenceFixture.engine.emit(
      EngineStatus(phase: .running, inputSampleRate: 96_000, renderSampleRate: 96_000))
    decoders.emit(.init(sourcePID: 502), for: 502)
    try require(
      precedenceFixture.engine.requestedRates == [44_100, 96_000],
      "Decoder expiry holds instead of reverting to the profile")
    precedence.stop()

    // E. Two clients claiming different rates hold; agreement applies.
    let conflictClients = FakeAudioSourceMonitor()
    conflictClients.observation = AudioSourceObservation(
      sources: [FakeAudioSourceMonitor.kew, FakeAudioSourceMonitor.music])
    let conflictFixture = Fixture()
    let conflictState = conflictFixture.makeState(
      audioSourceMonitor: conflictClients, decoderMonitors: FakeDecoderMonitors())
    conflictState.preferences.appRateProfiles = ["kew": 44_100, "com.apple.Music": 96_000]
    conflictState.preferences.matchMusicSampleRate = false
    conflictState.start()
    try require(
      conflictFixture.engine.requestedRates.isEmpty,
      "Disagreeing clients hold the current rate instead of guessing")
    try require(
      conflictState.sampleRateSummary.contains("disagree"), "The conflict is explained")
    conflictState.preferences.appRateProfiles["com.apple.Music"] = 44_100
    conflictState.rateSettingsChanged()
    try require(
      conflictFixture.engine.requestedRates == [44_100], "Agreeing clients apply their shared rate")
    conflictState.stop()

    // F. Music switches while a browser holds a silent stream (metadata and decoder).
    let sharedClients = FakeAudioSourceMonitor()
    sharedClients.observation = AudioSourceObservation(sources: [FakeAudioSourceMonitor.music, zen])
    let sharedMusic = FakeMusicRateMonitor()
    let sharedDecoders = FakeDecoderMonitors()
    let sharedFixture = Fixture()
    let sharedState = sharedFixture.makeState(
      musicRateMonitor: sharedMusic, audioSourceMonitor: sharedClients,
      decoderMonitors: sharedDecoders)
    sharedState.start()
    try require(sharedMusic.starts == 1, "Music metadata is read even with another routed client")
    sharedMusic.emit(.playing(rate: 44_100, track: "Music with browser open"))
    try require(
      sharedFixture.engine.requestedRates == [44_100],
      "Music matching is no longer blocked by a second silent client")
    sharedDecoders.emit(.init(sourcePID: 501, sampleRate: 96_000, date: Date()), for: 501)
    try require(
      sharedFixture.engine.requestedRates == [44_100, 96_000],
      "Music decoder evidence applies while a browser is routed")
    sharedState.stop()
    try require(sharedDecoders.activePIDs.isEmpty, "Stop ends every log reader")

    // G. Music: decoder > metadata, expiry holds, a pause blocks lingering logs.
    let musicClients = FakeAudioSourceMonitor()
    let musicMonitor = FakeMusicRateMonitor()
    let decoder = FakeDecoderMonitors()
    let f = Fixture()
    let s = f.makeState(
      musicRateMonitor: musicMonitor, audioSourceMonitor: musicClients, decoderMonitors: decoder)
    s.start()
    musicMonitor.emit(.playing(rate: 44_100, track: "Library metadata"))
    decoder.emit(.init(sourcePID: 501, sampleRate: 96_000, date: Date()), for: 501)
    try require(
      f.engine.requestedRates == [44_100, 96_000],
      "Fresh decoder input takes precedence over library metadata")
    decoder.emit(.init(sourcePID: 501), for: 501)
    musicMonitor.emit(.metadataUnavailable)
    musicMonitor.emit(.playing(rate: 44_100, track: "Older cached metadata"))
    f.engine.emit(EngineStatus(phase: .running))
    try require(
      f.engine.requestedRates == [44_100, 96_000],
      "Decoder expiry never falls back to older cached Music rate")
    musicMonitor.emit(.idle)
    decoder.emit(.init(sourcePID: 501, sampleRate: 192_000, date: Date()), for: 501)
    try require(
      f.engine.requestedRates == [44_100, 96_000],
      "Paused Music cannot be switched by a lingering decoder log")
    s.stop()
    print(
      "PASS decoder/profile Auto: per-client evidence, PID/freshness, expiry hold, profiles, one-click current rate, conflicts, Music beside a silent browser, Music pause/precedence"
    )
  }

  @MainActor
  static func sourceFileChecks() throws {
    // A. Kew playing a local 96 kHz / 24-bit FLAC: rate and exact depth follow the file.
    let clients = FakeAudioSourceMonitor()
    clients.observation = AudioSourceObservation(sources: [FakeAudioSourceMonitor.kew])
    let files = FakeSourceFileMonitors()
    let fixture = Fixture()
    let state = fixture.makeState(audioSourceMonitor: clients, fileMonitors: files)
    state.start()
    try require(files.activePIDs == [502], "The routed local player's open files are read")
    try require(
      fixture.engine.requestedBitDepths.isEmpty,
      "No depth request while Auto holds with no evidence")
    files.play(502, rate: 96_000, bits: 24, name: "O Aashiqa.flac")
    try require(fixture.engine.requestedRates == [96_000], "A 96 kHz file switches the input")
    try require(
      fixture.engine.requestedBitDepths == [24], "A 24-bit file sets the DAC to 24-bit")
    try require(
      state.reportedSourceRateText.contains("O Aashiqa.flac")
        && state.reportedSourceRateText.contains("24-bit"),
      "The playing file and its format are shown: \(state.reportedSourceRateText)")
    fixture.engine.emit(
      EngineStatus(phase: .running, inputSampleRate: 96_000, renderSampleRate: 96_000))
    files.play(502, rate: 44_100, bits: 16, name: "next.flac")
    try require(
      fixture.engine.requestedRates == [96_000, 44_100]
        && fixture.engine.requestedBitDepths == [24, 16],
      "The next 16-bit / 44.1 kHz track switches rate and depth")
    files.play(502, rate: 48_000, bits: nil, name: "lossy.m4a")
    try require(
      fixture.engine.requestedBitDepths == [24, 16, nil], "A lossy file uses the deepest format")
    files.play(502)
    try require(
      fixture.engine.requestedRates == [96_000, 44_100, 48_000]
        && fixture.engine.requestedBitDepths == [24, 16, nil],
      "No open file holds both rate and depth (no flapping between tracks)")

    // B. Deepest mode never sends a source depth.
    state.preferences.outputBitDepthMode = .deepest
    state.rateSettingsChanged()
    files.play(502, rate: 96_000, bits: 16)
    try require(
      fixture.engine.requestedBitDepths.last == .some(nil), "Deepest mode ignores source depth")
    state.preferences.outputBitDepthMode = .matchSource
    state.rateSettingsChanged()
    try require(
      fixture.engine.requestedBitDepths.last == 16, "Switching back applies the source depth")
    state.stop()

    // C. A local player outranks an idle browser's saved rate; a paused file does not.
    let mixed = FakeAudioSourceMonitor()
    mixed.observation = AudioSourceObservation(sources: [FakeAudioSourceMonitor.kew, zen])
    let mixedFiles = FakeSourceFileMonitors()
    let mixedFixture = Fixture()
    var saved = AppPreferences()
    saved.appRateProfiles = ["app.zen-browser.zen": 44_100]
    let mixedState = mixedFixture.makeState(
      saved, audioSourceMonitor: mixed, fileMonitors: mixedFiles)
    mixedState.start()
    try require(mixedFixture.engine.requestedRates == [44_100], "Zen's saved rate applies alone")
    mixedFiles.play(502, rate: 96_000)
    try require(
      mixedFixture.engine.requestedRates == [44_100, 96_000],
      "A file being played outranks another app's saved rate")
    mixedFiles.play(502, rate: 96_000, idle: true)
    try require(
      mixedFixture.engine.requestedRates == [44_100, 96_000]
        && mixedState.sampleRateSummary.contains("disagree"),
      "A paused file and a saved rate disagree, so the rate holds")
    mixedState.stop()

    // D. Decoder evidence outranks the file for the same client; Follow input stops reading.
    let both = FakeAudioSourceMonitor()
    both.observation = AudioSourceObservation(sources: [FakeAudioSourceMonitor.kew])
    let bothFiles = FakeSourceFileMonitors()
    let bothDecoders = FakeDecoderMonitors()
    let bothFixture = Fixture()
    let bothState = bothFixture.makeState(
      audioSourceMonitor: both, decoderMonitors: bothDecoders, fileMonitors: bothFiles)
    bothState.start()
    bothFiles.play(502, rate: 44_100, bits: 16)
    bothDecoders.emit(
      .init(sourcePID: 502, sampleRate: 96_000, date: Date(), bitDepth: 24), for: 502)
    try require(
      bothFixture.engine.requestedRates == [44_100, 96_000]
        && bothFixture.engine.requestedBitDepths == [16, 24],
      "Decoder evidence and its depth win over the file")
    bothState.preferences.sampleRateMode = .followInput
    bothState.rateSettingsChanged()
    try require(bothFiles.activePIDs.isEmpty, "Follow input stops reading open files")
    try require(
      bothFixture.engine.requestedBitDepths.last == .some(nil),
      "Follow input uses the deepest DAC format")
    bothState.stop()
    print(
      "PASS source files: open-file rate/depth/name, track changes, lossy, hold, deepest mode, live vs saved vs paused, decoder precedence"
    )
  }

  @MainActor
  static func universalRateChecks() async throws {
    let clients = FakeAudioSourceMonitor()
    clients.observation = AudioSourceObservation(sources: [FakeAudioSourceMonitor.kew])
    let music = FakeMusicRateMonitor()
    let fixture = Fixture()
    let state = fixture.makeState(musicRateMonitor: music, audioSourceMonitor: clients)
    state.start()
    try require(clients.starts == [101], "Discovery is scoped to the selected input")
    try require(music.starts == 0, "Kew playback never starts unrelated Music automation")
    try require(
      state.sampleRateSummary.contains("no rate claimed"), "Unknown rate is explicit, not guessed")
    try require(state.playbackSourceSummary == "kew", "The routed client is visible")
    try require(fixture.engine.requestedRates.isEmpty, "Unknown source holds the device rate")

    fixture.engine.emit(
      EngineStatus(
        phase: .running, inputSampleRate: 48_000, inputChannelCount: 16, renderSampleRate: 48_000))
    try require(state.renderRateText == "48000 Hz", "Actual worker DSP rate reaches AppState")
    try require(
      state.capturedRateText == "48000 Hz", "Captured PCM is separate from original source")
    try require(state.reportedSourceRateText.contains("Unknown"), "No false original-rate claim")
    try require(
      state.rateConversionSummary.contains("upstream"), "Unknown upstream conversion stays unknown")

    state.preferences.sampleRateMode = .fixed
    state.preferences.fixedSampleRate = 96_000
    state.rateSettingsChanged()
    try require(fixture.engine.requestedRates == [96_000], "Fixed mode works for any routed app")
    fixture.engine.emit(
      EngineStatus(phase: .running, inputSampleRate: 48_000, renderSampleRate: 48_000))
    try require(fixture.engine.requestedRates == [96_000], "Pending requests are deduplicated")
    state.preferences.sampleRateMode = .followInput
    state.rateSettingsChanged()
    clients.emit(AudioSourceObservation(sources: [FakeAudioSourceMonitor.music]))
    try require(music.starts == 0, "Follow input reads no player metadata")
    try require(fixture.engine.requestedRates == [96_000], "Follow input never changes its rate")

    state.preferences.sampleRateMode = .automatic
    state.rateSettingsChanged()
    try require(music.starts == 1, "Exclusive routed Music enables its supported adapter")
    music.emit(.playing(rate: 44_100, track: "A"))
    try require(
      fixture.engine.requestedRates == [96_000, 44_100], "Auto uses exclusive Music metadata")
    let staleMusicReport = music.callbacks[0]
    clients.emit(
      AudioSourceObservation(sources: [FakeAudioSourceMonitor.music, FakeAudioSourceMonitor.kew]))
    staleMusicReport(.playing(rate: 192_000, track: "Late old adapter report"))
    try require(
      state.sampleRateSummary.contains("none claims a rate"),
      "Multiple clients without claims hold one shared rate")
    try require(state.detectedMusicRate == nil, "Competing client invalidates old Music metadata")
    music.emit(.playing(rate: 192_000, track: "Music now playing"))
    try require(
      fixture.engine.requestedRates == [96_000, 44_100, 192_000],
      "A playing Music client still claims a rate when another silent client is routed")
    clients.emit(AudioSourceObservation(isAvailable: false))
    try require(state.sampleRateSummary.contains("unavailable"), "Discovery failure fails closed")
    try require(
      fixture.engine.requestedRates == [96_000, 44_100, 192_000],
      "Discovery failure changes no rate")
    let oldReport = clients.callbacks[0]
    state.stop()
    state.start()
    oldReport(AudioSourceObservation(sources: [FakeAudioSourceMonitor.music]))
    try require(
      !state.audioSources.isAvailable, "Old-generation source reports cannot affect a new run")
    state.stop()

    let delayedFixture = Fixture()
    let delayedClients = FakeAudioSourceMonitor()
    let delayedMusic = FakeMusicRateMonitor()
    let delayed = delayedFixture.makeState(
      musicRateMonitor: delayedMusic, audioSourceMonitor: delayedClients,
      rateMatchDelay: .milliseconds(30))
    delayed.start()
    delayedMusic.emit(.playing(rate: 96_000, track: "Candidate"))
    delayedClients.emit(
      AudioSourceObservation(sources: [FakeAudioSourceMonitor.music, FakeAudioSourceMonitor.kew]))
    try await Task.sleep(for: .milliseconds(70))
    try require(
      delayedFixture.engine.requestedRates.isEmpty,
      "A new competing source cancels a pending rate switch")
    delayedClients.emit(AudioSourceObservation(sources: [FakeAudioSourceMonitor.music]))
    delayedMusic.emit(.playing(rate: 96_000, track: "Loading"))
    delayedMusic.emit(.playing(rate: 44_100, track: "Settled"))
    try await Task.sleep(for: .milliseconds(70))
    try require(
      delayedFixture.engine.requestedRates == [44_100],
      "Rapid metadata changes apply only the settled rate")
    delayedMusic.emit(.playing(rate: 96_000, track: "A"))
    try await Task.sleep(for: .milliseconds(70))
    delayedMusic.emit(.playing(rate: 44_100, track: "B"))
    delayedMusic.emit(.playing(rate: 96_000, track: "A again"))
    delayedMusic.emit(.playing(rate: 44_100, track: "B settled"))
    try await Task.sleep(for: .milliseconds(70))
    try require(
      delayedFixture.engine.requestedRates.last == 44_100,
      "Revoked A/B/A requests cannot strand later B matching")
    let ratesBeforeStop = delayedFixture.engine.requestedRates
    delayedMusic.emit(.failure(.scriptFailed(-1728)))
    try require(delayed.detectedMusicRate == nil, "Adapter failure clears stale source rate")
    delayedMusic.emit(.playing(rate: 96_000, track: "Cancelled"))
    delayed.stop()
    try await Task.sleep(for: .milliseconds(70))
    try require(
      delayedFixture.engine.requestedRates == ratesBeforeStop, "Stop cancels delayed matching")

    let fixedFixture = Fixture()
    let fixedClients = FakeAudioSourceMonitor()
    let fixedState = fixedFixture.makeState(
      audioSourceMonitor: fixedClients, rateMatchDelay: .milliseconds(30))
    fixedState.preferences.sampleRateMode = .fixed
    fixedState.preferences.fixedSampleRate = 96_000
    fixedState.start()
    for index in 0..<6 {
      fixedClients.emit(
        AudioSourceObservation(
          sources: index.isMultiple(of: 2)
            ? [FakeAudioSourceMonitor.kew] : [FakeAudioSourceMonitor.music]))
      try await Task.sleep(for: .milliseconds(10))
    }
    try require(
      fixedFixture.engine.requestedRates == [96_000],
      "Client churn neither postpones nor repeats explicit Fixed")
    fixedState.stop()

    var prefs = AppPreferences()
    prefs.sampleRateMode = .fixed
    prefs.fixedSampleRate = .nan
    try require(
      SampleRateDecision.resolve(
        preferences: prefs, sources: .init(), musicRate: nil, musicFailure: nil) == .invalidRate,
      "Non-finite rate never reaches HAL")
    print(
      "PASS universal rate: unknown/multiple clients, exclusive adapters, modes, DSP status, generations and debounce"
    )
  }

  /// Matching the input device to Music's track rate is opt-in, best-effort and only
  /// active while the renderer runs. Music metadata is parsed deterministically.
  @MainActor
  static func musicRateChecks() throws {
    try require(
      MusicTrackRateMonitor.parse("96000|Sofia") == .playing(rate: 96_000, track: "Sofia"),
      "A track line carries the rate and name")
    try require(
      MusicTrackRateMonitor.parse("48000") == .playing(rate: 48_000, track: ""),
      "A rate without a name is still a rate")
    try require(
      MusicTrackRateMonitor.parse("paused") == .idle, "Only an actual pause ends the episode")
    for missing in ["no track", "", "0|Broken", "-96000|Broken"] {
      try require(
        MusicTrackRateMonitor.parse(missing) == .metadataUnavailable, "Missing output: \(missing)")
    }
    try require(
      MusicTrackRateMonitor.parse(nil) == .metadataUnavailable,
      "No script output is unknown metadata")

    let fixture = Fixture()
    let monitor = FakeMusicRateMonitor()
    let clients = FakeAudioSourceMonitor()
    let state = fixture.makeState(musicRateMonitor: monitor, audioSourceMonitor: clients)
    state.start()
    try require(monitor.starts == 1, "Rendering starts Music rate monitoring")
    try require(
      state.setupChecklist.checks.first { $0.id == .musicRate }?.status == .manual,
      "The checklist waits for a track rather than claiming a match")

    monitor.emit(.playing(rate: 96_000, track: "Sofia"))
    try require(
      fixture.engine.requestedRates == [96_000],
      "A 96 kHz track requests a 96 kHz input device")
    try require(state.detectedMusicRate == 96_000, "The detected rate is observable")
    try require(
      state.setupChecklist.checks.first { $0.id == .musicRate }?.status == .manual,
      "A pending switch stays manual, never verified")

    monitor.emit(.playing(rate: 96_000, track: "Sofia again"))
    try require(
      fixture.engine.requestedRates.count == 1,
      "Repeated readings do not repeat the rate request")

    fixture.catalog[0] = AudioDeviceInfo(
      id: Fixture.input.id, name: Fixture.input.name, uid: Fixture.input.uid,
      inputChannelCount: 16, outputChannelCount: 0, nominalSampleRate: 96_000)
    state.refreshDevices()
    try require(
      state.setupChecklist.checks.first { $0.id == .musicRate }?.status == .manual,
      "A new catalog nominal rate alone cannot verify a running capture")
    fixture.engine.emit(
      EngineStatus(phase: .running, inputSampleRate: 96_000, renderSampleRate: 96_000))
    try require(
      state.setupChecklist.checks.first { $0.id == .musicRate }?.status == .verified,
      "A matched running capture rate is verified")

    monitor.emit(.playing(rate: 44_100, track: "Older"))
    try require(
      fixture.engine.requestedRates == [96_000, 44_100],
      "A different track rate requests a different device rate")

    monitor.emit(.idle)
    try require(state.detectedMusicRate == nil, "Pausing Music clears the detected rate")
    try require(
      fixture.engine.requestedRates == [96_000, 44_100],
      "Pausing Music does not change the device rate")

    monitor.emit(.failure(.automationDenied))
    try require(
      state.setupChecklist.checks.first { $0.id == .musicRate }?.status == .needsAttention,
      "Denied Automation access needs attention instead of a silent failure")
    try require(
      state.setupChecklist.checks.first { $0.id == .musicRate }?
        .guidance.contains("Automation") == true,
      "Guidance names the Automation permission")

    state.stop()
    try require(monitor.stops == 1, "Stopping the renderer stops rate monitoring")

    state.start()
    try require(monitor.starts == 2, "Restarting resumes rate monitoring")
    state.preferences.matchMusicSampleRate = false
    state.persist()
    try require(monitor.stops == 2, "Turning matching off stops monitoring")
    try require(
      state.detectedMusicRate == nil && state.musicRateFailure == nil,
      "Turning matching off clears Music state")
    state.stop()
    print("PASS music rate: parse, monitor lifecycle, request deduplication and checklist states")
  }

  /// The diagnostics log must stay silent in tests, record failures, detect an abrupt
  /// stop on the next launch, and bound its own size.
  @MainActor
  static func loggingChecks() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("downmix-log-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DownmixLog(directory: directory)
    try require(!log.isEnabled, "Logging stays silent until the app opens a session")
    log.log(.info, "test", "must be dropped")
    try require(
      !FileManager.default.fileExists(atPath: log.fileURL.path),
      "Nothing is written before a session starts")

    log.beginSession(version: "1.4.0 (6)", details: ["executable=check"])
    log.log(.info, "devices", "selected input=Fixture")
    log.logFailure(
      "The selected input disconnected.", context: "run failed", diagnostics: nil)
    log.flush()
    let first = try String(contentsOf: log.fileURL, encoding: .utf8)
    try require(
      first.contains("session start version=1.4.0 (6)"),
      "Session start is recorded with its version")
    try require(first.contains("selected input=Fixture"), "Ordinary lines are recorded")
    try require(
      first.contains("ERROR[engine] run failed: The selected input disconnected."),
      "Failures are recorded with level, category and message")
    try require(!first.contains("clean exit"), "An abrupt stop leaves no clean-exit marker")

    // The next launch reports the previous abrupt stop.
    let second = DownmixLog(directory: directory)
    second.beginSession(version: "1.4.0 (7)")
    second.flush()
    var text = try String(contentsOf: second.fileURL, encoding: .utf8)
    try require(
      text.contains("previous session ended without a clean exit"),
      "An unclean previous session is reported on the next launch")
    second.endSession(reason: "check")
    let afterCleanExit = try String(contentsOf: second.fileURL, encoding: .utf8)
    try require(
      afterCleanExit.contains("clean exit reason=check"), "A clean exit is recorded")

    let third = DownmixLog(directory: directory)
    third.beginSession(version: "1.4.0 (8)")
    third.flush()
    text = try String(contentsOf: third.fileURL, encoding: .utf8)
    let lines = text.split(separator: "\n")
    let sessionStart = lines.lastIndex { $0.contains("session start version=1.4.0 (8)") } ?? 0
    let currentSession = lines[sessionStart...]
    try require(
      !currentSession.contains(where: { $0.contains("without a clean exit") }),
      "A clean previous session produces no warning")

    // Rotation keeps the file bounded and preserves the previous file.
    for index in 0..<700 {
      third.log(.info, "rotation", String(repeating: "x", count: 1_000) + "\(index)")
    }
    third.flush()
    let archive = directory.appendingPathComponent("downmix.1.log")
    let mainSize =
      (try FileManager.default.attributesOfItem(atPath: third.fileURL.path)[.size] as? NSNumber)?
      .intValue ?? 0
    try require(
      FileManager.default.fileExists(atPath: archive.path),
      "An oversized log is rotated instead of growing without bound")
    try require(
      mainSize < DownmixLog.maximumFileBytes + 2_000,
      "The active log stays near its size limit after rotation")
    third.endSession()
    print(
      "PASS diagnostics log: silent until session start, failures, unclean-stop detection, clean exit, rotation"
    )
  }

  @MainActor
  static func permissionChecks() async throws {
    let fixture = Fixture()
    fixture.permissionStatus = .notDetermined
    let state = fixture.makeState()
    state.start()
    state.start()
    try require(
      state.isRunning && fixture.engine.starts.isEmpty,
      "Wait for authorization before opening audio")
    try require(fixture.permissionRequests == 1, "Only one authorization request may be pending")
    state.refreshDevices()
    try require(
      state.status.phase == .starting,
      "Unrelated device refresh must preserve authorization request")
    state.stop()
    fixture.permissionStatus = .authorized
    fixture.permissionCompletion?(true)
    try await Task.sleep(for: .milliseconds(20))
    try require(
      state.status.phase == .stopped && fixture.engine.starts.isEmpty,
      "Stop cancels a delayed authorization completion")

    fixture.permissionStatus = .notDetermined
    state.start()
    fixture.permissionStatus = .authorized
    fixture.permissionCompletion?(true)
    try await Task.sleep(for: .milliseconds(20))
    try require(
      state.status.phase == .running && fixture.engine.starts.count == 1,
      "Authorized request resumes start once")
    state.stop()
    fixture.permissionStatus = .denied
    state.start()
    try require(
      state.status.phase == .error && fixture.engine.starts.count == 1,
      "Denied authorization never opens audio")
    try require(
      state.errorMessage?.contains("System Settings") == true,
      "Denied authorization explains recovery")
    fixture.permissionStatus = .notDetermined
    state.start()
    fixture.engine.emit(EngineStatus(phase: .error, message: "Fatal while authorizing"))
    fixture.permissionStatus = .authorized
    fixture.permissionCompletion?(true)
    try await Task.sleep(for: .milliseconds(20))
    try require(
      state.status.phase == .error && fixture.engine.starts.count == 1,
      "Fatal status must cancel a pending authorization completion rather than auto-restart")
    print(
      "PASS permission: single request, hotplug stability, delayed-completion cancellation, allow/deny, fatal cancellation"
    )
  }

  @MainActor
  static func catalogChecks() throws {
    let fixture = Fixture()
    let state = fixture.makeState()
    try require(fixture.enumerations == 1, "Initialization must enumerate exactly once")
    try require(state.selectedInputID == Fixture.input.id, "Resolve the default multichannel input")
    try require(state.selectedOutputID == Fixture.output.id, "Resolve the default stereo output")
    state.refreshDevices()
    try require(fixture.enumerations == 2, "Refresh must reuse one catalog for both selections")
    try require(
      fixture.permissionQueries == 0 && fixture.writes.isEmpty,
      "Refresh has no permission or persistence side effects")

    var saved = AppPreferences()
    saved.inputDeviceUID = "missing-input"
    saved.outputDeviceUID = "missing-output"
    saved.inputDeviceName = Fixture.input.name
    saved.outputDeviceName = Fixture.output.name
    let missingFixture = Fixture()
    let missing = missingFixture.makeState(saved)
    try require(
      missing.selectedInputID == nil && missing.selectedOutputID == nil,
      "Missing saved UIDs must not fall back to matching names/defaults")
    try require(missing.preferences == saved, "Missing saved identities must be retained")
    missing.start()
    try require(
      missing.status.phase == .error && missingFixture.engine.starts.isEmpty,
      "Missing route must fail without opening hardware")
    print("PASS catalog: one enumeration per refresh; missing saved UID never falls back")
  }

  @MainActor
  static func transportChecks() throws {
    var preferences = AppPreferences()
    preferences.keepOutputAlive = true
    let fixture = Fixture()
    let state = fixture.makeState(preferences)
    state.start()
    try require(state.isRunning, "Synchronous running status must be visible immediately")
    state.stop()
    try require(
      state.status.phase == .keepAlive,
      "Stop must enter keep-alive after synchronous stopped status")
    try require(
      fixture.engine.events.count == 3,
      "Stop then keep-alive must have exactly start/stop/start calls")
    try require(
      fixture.engine.events[1] == .stop && fixture.engine.starts.last?.keepAlive == true,
      "Keep-alive must follow stop")
    try require(
      fixture.engine.starts.last?.output == Fixture.output.id,
      "Keep-alive must retain selected output")
    state.preferences.keepOutputAlive = false
    state.persist()
    state.stop()
    try require(
      state.status.phase == .stopped && !state.isKeepingOutputAwake,
      "Disabling keep-alive then stop must truly stop")
    try require(fixture.engine.starts.count == 2, "Disabled keep-alive must never restart")
    print("PASS transport: stop → keep-alive; disabling keep-alive → stopped")
  }

  @MainActor
  static func selectionChecks() throws {
    let fixture = Fixture()
    let state = fixture.makeState()
    state.start()
    let originalEvents = fixture.engine.events.count
    state.selectInput(Fixture.input)
    state.selectOutput(Fixture.output)
    try require(
      fixture.engine.events.count == originalEvents,
      "Reselecting the active route must not interrupt playback")
    state.selectOutput(Fixture.secondOutput)
    try require(
      state.isRunning && fixture.engine.starts.count == 2,
      "Changing output while running must restart")
    try require(fixture.engine.events[1] == .stop, "Output selection must stop before restarting")
    try require(
      fixture.engine.starts.last?.output == Fixture.secondOutput.id,
      "Restart must use the new output")
    state.selectInput(Fixture.secondInput)
    try require(
      state.isRunning && fixture.engine.starts.count == 3,
      "Changing input while running must restart")
    try require(fixture.engine.events[3] == .stop, "Input selection must stop before restarting")
    try require(
      fixture.engine.starts.last?.input == Fixture.secondInput.id, "Restart must use the new input")
    try require(
      fixture.engine.starts.last?.output == Fixture.secondOutput.id,
      "Input change must retain output")
    try require(
      !fixture.engine.events.contains {
        if case .configuration = $0 { return true }
        return false
      }, "Selection must not update the old route configuration")
    print("PASS selection: running input/output changes restart onto the new route")
  }

  @MainActor
  static func configurationChecks() throws {
    let fixture = Fixture()
    let state = fixture.makeState()
    state.start()
    state.preferences.preampDb = -12
    state.persist()
    try require(
      fixture.engine.starts.count == 1 && fixture.engine.events.count == 2,
      "Preamp must update configuration without restart")
    if case .configuration(let configuration) = fixture.engine.events.last {
      try require(configuration.preampDb == -12, "Updated preamp must reach the engine")
    } else {
      throw CheckFailure(message: "Expected configuration update")
    }
    state.preferences.framesPerBuffer = 256
    state.persist()
    try require(
      fixture.engine.events[2] == .stop && fixture.engine.starts.count == 2,
      "Buffer size change must stop then restart")
    try require(
      fixture.engine.starts.last?.frames == 256
        && fixture.engine.starts.last?.configuration.preampDb == -12,
      "Restart must use new buffer size and current DSP settings")
    state.preferences.keepOutputAlive = true
    state.stop()
    state.preferences.framesPerBuffer = 512
    state.persist()
    try require(
      state.isKeepingOutputAwake && fixture.engine.starts.last?.frames == 512,
      "Buffer change must restart keep-alive too")
    print("PASS configuration: preamp updates DSP; buffer size restarts renderer/keep-alive")
  }

  @MainActor
  static func automaticLaunchChecks() throws {
    var preferences = AppPreferences()
    preferences.keepOutputAlive = true
    let fixture = Fixture()
    let state = fixture.makeState(preferences)
    state.startAutomaticallyIfNeeded()
    state.startAutomaticallyIfNeeded()
    try require(
      state.isKeepingOutputAwake && fixture.engine.starts.count == 1,
      "Automatic launch must start keep-alive only once")
    try require(
      fixture.permissionQueries == 0, "Keep-alive must not request microphone authorization")
    let eventCount = fixture.engine.events.count
    state.startKeepAliveIfNeeded()
    try require(
      fixture.engine.events.count == eventCount,
      "Starting the same keep-alive route must be idempotent")

    preferences.autoStart = true
    let autoFixture = Fixture()
    let autoState = autoFixture.makeState(preferences)
    autoState.startAutomaticallyIfNeeded()
    autoState.startAutomaticallyIfNeeded()
    try require(
      autoState.isRunning && autoFixture.engine.starts.count == 1,
      "Auto-start renderer must take precedence over keep-alive and run once")
    print("PASS automatic launch: keep-alive/auto-start are idempotent")
  }

  @MainActor
  static func nameOnlySavedRouteChecks() throws {
    // Decode real legacy name-only JSON rather than setting UIDs on a fresh model.
    for autoStart in [false, true] {
      let data = Data(
        """
        {"inputDeviceName":"Absent 16ch", "outputDeviceName":"Absent DAC",
         "autoStart":\(autoStart), "keepOutputAlive":true}
        """.utf8)
      let saved = try JSONDecoder().decode(AppPreferences.self, from: data)
      let fixture = Fixture()
      let state = fixture.makeState(saved)
      state.startAutomaticallyIfNeeded()
      state.startKeepAliveIfNeeded()
      try require(
        state.selectedInputID == nil && state.selectedOutputID == nil
          && fixture.engine.starts.isEmpty && state.preferences == saved,
        "Absent name-only saved devices must never auto-start or keep alive a different route")
      state.refreshDevices()
      try require(
        state.selectedInputID == nil && state.selectedOutputID == nil
          && fixture.engine.starts.isEmpty && state.preferences == saved,
        "Refresh must not overwrite missing legacy names with new default UIDs")
    }
    // A missing saved input still permits output-only keep-alive on the exact saved
    // output, but automatic renderer startup must not substitute another input.
    let saved = try JSONDecoder().decode(
      AppPreferences.self,
      from: Data(
        """
        {"inputDeviceName":"Absent 16ch", "outputDeviceName":"Speakers",
         "autoStart":true, "keepOutputAlive":true}
        """.utf8))
    let fixture = Fixture()
    let state = fixture.makeState(saved)
    state.startAutomaticallyIfNeeded()
    try require(
      state.selectedInputID == nil && fixture.engine.starts.isEmpty,
      "Name-only missing input must not auto-start the renderer on a different input")
    state.startKeepAliveIfNeeded()
    try require(
      fixture.engine.starts.count == 1 && fixture.engine.starts[0].keepAlive
        && fixture.engine.starts[0].output == Fixture.output.id,
      "Output-only keep-alive can use an existing saved-name output, never another route")
    print("PASS legacy saved names: absent devices never auto-start/keep alive different routes")
  }

  @MainActor
  static func disconnectChecks() throws {
    for disconnectInput in [false, true] {
      var preferences = AppPreferences()
      preferences.keepOutputAlive = true
      let fixture = Fixture()
      let state = fixture.makeState(preferences)
      state.start()
      fixture.catalog.removeAll {
        $0.id == (disconnectInput ? Fixture.input.id : Fixture.output.id)
      }
      state.refreshDevices()
      try require(
        state.status.phase == .error && state.errorMessage != nil,
        "Disconnect must stop with an error")
      try require(
        fixture.engine.events.last == .stop && fixture.engine.starts.count == 1,
        "Disconnect must never switch output or start keep-alive")
      try require(
        state.preferences.outputDeviceUID == Fixture.output.uid,
        "Disconnect must retain saved output identity")
      if !disconnectInput {
        try require(
          state.selectedOutputID == nil, "Output disconnect must not select another output")
      }
    }
    var preferences = AppPreferences()
    preferences.keepOutputAlive = true
    let fixture = Fixture()
    let state = fixture.makeState(preferences)
    state.startAutomaticallyIfNeeded()
    fixture.catalog.removeAll { $0.id == Fixture.output.id }
    state.refreshDevices()
    try require(
      state.status.phase == .error && fixture.engine.starts.count == 1,
      "Keep-alive output disconnect must fail without fallback")
    print("PASS disconnect: renderer/keep-alive stop with errors; never switch outputs")
  }

  @MainActor
  static func errorChecks() throws {
    let fixture = Fixture()
    let state = fixture.makeState()
    state.start()
    var meters = MeterSnapshot.empty
    meters.outputPeakLDb = -3
    meters.clipL = true
    fixture.engine.emit(EngineStatus(phase: .running, meters: meters))
    try require(
      state.meterSource.snapshot() == meters, "Running meters must reach the meter source")
    fixture.engine.emit(EngineStatus(phase: .error, message: "Lost route", meters: meters))
    try require(
      state.errorMessage == "Lost route" && !state.isRunning,
      "Backend error must immediately clear running state")
    try require(
      state.meterSource.snapshot() == .empty,
      "Error must clear meters even if the backend supplies stale peaks")
    let resetRevision = state.meterSource.resetRevision()
    fixture.engine.emit(EngineStatus(phase: .running, meters: .empty))
    try require(
      state.meterSource.resetRevision() == resetRevision,
      "Normal running silence must not reset native meter ballistics")
    state.stop()
    try require(
      state.meterSource.resetRevision() > resetRevision,
      "Explicit Stop must signal a ballistic reset even when the snapshot is already empty")

    let failureFixture = Fixture()
    failureFixture.engine.startFailure = CheckFailure(message: "Open failed")
    let failed = failureFixture.makeState()
    failed.start()
    try require(
      failed.status.phase == .error && failed.errorMessage == "Open failed",
      "Thrown start failure must stop and preserve its error")
    try require(
      failureFixture.engine.events.last == .stop, "Start failure must clean up the backend")

    let unsafeFixture = Fixture()
    var unsafePreferences = AppPreferences()
    unsafePreferences.inputDeviceUID = Fixture.input.uid
    unsafePreferences.outputDeviceUID = Fixture.output.uid
    unsafeFixture.safeRoute = false
    let unsafe = unsafeFixture.makeState(unsafePreferences)
    unsafe.start()
    try require(
      unsafe.status.phase == .error && unsafeFixture.engine.starts.isEmpty,
      "Unsafe route must be rejected before starting")
    print(
      "PASS errors: stale meters cleared; thrown start failure cleaned up; unsafe routes rejected")
  }

  @MainActor
  static func setupChecks() throws {
    let fixture = Fixture()
    let state = fixture.makeState()
    let ready = state.setupChecklist
    try require(
      ready.checks.filter { $0.status == .verified }.count == 5,
      "Selected 16-channel/48k/safe stereo/authorized route must pass automatic checks")
    try require(
      ready.checks.filter { $0.status == .manual }.map(\.id)
        == [.musicRate, .speakerMapping, .systemOutput],
      "Music matching, speaker mapping and system output must remain manual, never certified")
    try require(
      fixture.enumerations == 1 && fixture.engine.events.isEmpty && fixture.permissionRequests == 0,
      "Checklist must not enumerate hardware, start audio, or eagerly request permission")

    fixture.permissionStatus = .notDetermined
    let undetermined = state.setupChecklist
    try require(
      undetermined.canRequestPermission
        && undetermined.checks.first { $0.id == .authorization }?.status == .permissionRequired,
      "Undetermined authorization must offer an explicit Start action")
    try require(
      fixture.permissionRequests == 0, "Reading permission guidance never requests access")
    state.promptStart()
    try require(
      fixture.permissionRequests == 1 && fixture.engine.starts.isEmpty,
      "Only the explicit Start action requests permission")
    let pendingEnumerations = fixture.enumerations
    state.retrySavedRoute()
    try require(
      fixture.permissionRequests == 1 && fixture.enumerations == pendingEnumerations,
      "Retry while authorization is pending must be a no-op")
    state.stop()

    for authorization in [AVAuthorizationStatus.denied, .restricted] {
      fixture.permissionStatus = authorization
      let checklist = state.setupChecklist
      try require(
        !checklist.canRequestPermission
          && checklist.checks.first { $0.id == .authorization }?.status == .needsAttention,
        "Denied/restricted authorization must show settings guidance, not a permission prompt")
    }

    // The checklist must report the live run's speech-layout certificate, not a stale claim.
    state.start()
    fixture.engine.emit(
      EngineStatus(
        phase: .running, message: "Stereo renderer running · 44.1 kHz → 48 kHz",
        bedLayoutInstalled: true, inputSampleRate: 44_100, inputChannelCount: 16))
    try require(
      state.setupChecklist.checks.first { $0.id == .speakerMapping }?.status == .verified,
      "A running run with an accepted bed layout certifies the speaker mapping")
    try require(
      state.status.inputSampleRate == 44_100 && state.status.inputChannelCount == 16,
      "Live input format reaches AppState")
    fixture.engine.emit(
      EngineStatus(phase: .running, message: "Stereo renderer running", bedLayoutInstalled: false))
    try require(
      state.setupChecklist.checks.first { $0.id == .speakerMapping }?.status == .needsAttention,
      "A refused bed layout needs attention instead of staying manual")
    state.stop()

    fixture.permissionStatus = .authorized
    fixture.safeRoute = false
    state.refreshDevices()
    try require(
      state.setupChecklist.checks.first { $0.id == .output }?.status == .needsAttention,
      "Checklist must use injected route-safety checks rather than certify by channel count")
    fixture.safeRoute = true
    fixture.catalog = [
      AudioDeviceInfo(
        id: Fixture.input.id, name: Fixture.input.name, uid: Fixture.input.uid,
        inputChannelCount: 8, outputChannelCount: 0, nominalSampleRate: 44_100),
      AudioDeviceInfo(
        id: Fixture.output.id, name: Fixture.output.name, uid: Fixture.output.uid,
        inputChannelCount: 0, outputChannelCount: 1, nominalSampleRate: 96_000),
    ]
    state.refreshDevices()
    var narrow = state.setupChecklist
    try require(
      narrow.checks.filter { $0.status == .needsAttention }.map(\.id) == [.input, .output],
      "Narrow input and mono output must need attention, but other rates must not")
    try require(
      narrow.checks.first { $0.id == .inputRate }?
        .guidance.contains("renders at this rate") == true
        && narrow.checks.first { $0.id == .outputRate }?.status == .verified,
      "Non-48 kHz devices are described as passthrough, not as failures")
    try require(
      narrow.checks.first { $0.id == .input }?
        .guidance.contains("only that many bed slots") == true,
      "A narrow input explains which slots are fed")

    // A player rate switch must stay usable; only an impossible rate needs attention.
    fixture.catalog = [
      AudioDeviceInfo(
        id: Fixture.input.id, name: Fixture.input.name, uid: Fixture.input.uid,
        inputChannelCount: 16, outputChannelCount: 0, nominalSampleRate: 96_000),
      AudioDeviceInfo(
        id: Fixture.output.id, name: Fixture.output.name, uid: Fixture.output.uid,
        inputChannelCount: 0, outputChannelCount: 2, nominalSampleRate: 44_100),
    ]
    state.refreshDevices()
    try require(
      state.setupChecklist.checks.filter { $0.status == .needsAttention }.isEmpty,
      "44.1/96 kHz devices with the bed width are fully ready")
    fixture.catalog[0] = AudioDeviceInfo(
      id: Fixture.input.id, name: Fixture.input.name, uid: Fixture.input.uid,
      inputChannelCount: 16, outputChannelCount: 0, nominalSampleRate: 4_000)
    state.refreshDevices()
    narrow = state.setupChecklist
    try require(
      narrow.checks.first { $0.id == .inputRate }?.status == .needsAttention,
      "Rates outside the supported band must need attention")

    fixture.catalog = []
    state.refreshDevices()
    let missing = state.setupChecklist
    try require(
      missing.checks.filter { $0.status == .needsAttention }.count == 4,
      "Missing devices must not appear ready")
    try require(
      missing.checks.first { $0.id == .input }?.guidance.contains("reconnect") == true
        && missing.checks.first { $0.id == .output }?.guidance.contains("reconnect") == true,
      "Missing devices must have actionable guidance")

    let refreshed = ChangeRecorder()
    withObservationTracking {
      _ = state.setupChecklist
    } onChange: {
      refreshed.record()
    }
    state.refreshDevices()
    try require(
      refreshed.changes == 1,
      "Refresh must recheck external permission state with unchanged devices")
    print(
      "PASS setup: selected-device checks, injected safety/permissions, manual-only guidance, no eager prompt"
    )
  }

  @MainActor
  static func retryChecks() throws {
    var preferences = AppPreferences()
    preferences.inputDeviceUID = Fixture.input.uid
    preferences.outputDeviceUID = Fixture.output.uid
    preferences.inputDeviceName = Fixture.input.name
    preferences.outputDeviceName = Fixture.output.name
    preferences.keepOutputAlive = true
    let fixture = Fixture()
    let state = fixture.makeState(preferences)
    for phase in [EnginePhase.stopped, .error, .keepAlive] {
      fixture.engine.emit(EngineStatus(phase: phase))
      try require(state.canRetrySavedRoute, "Retry must be available in \(phase)")
    }
    for phase in [EnginePhase.starting, .running, .stopping] {
      fixture.engine.emit(EngineStatus(phase: phase))
      let beforeEvents = fixture.engine.events
      let beforeEnumerations = fixture.enumerations
      try require(!state.canRetrySavedRoute, "Retry must be disabled in \(phase)")
      state.retrySavedRoute()
      try require(
        fixture.engine.events == beforeEvents && fixture.enumerations == beforeEnumerations,
        "Disabled Retry must not enumerate or send transport commands in \(phase)")
    }
    fixture.engine.emit(EngineStatus())
    state.start()
    let events = fixture.engine.events
    let enumerations = fixture.enumerations
    fixture.catalog.removeAll { $0.uid == Fixture.output.uid }
    state.retrySavedRoute()
    try require(
      fixture.engine.events == events && fixture.enumerations == enumerations && state.isRunning,
      "Retry while running must not even refresh or interrupt a good route")
    state.refreshDevices()
    let afterDisconnect = fixture.enumerations
    state.retrySavedRoute()
    try require(
      fixture.enumerations == afterDisconnect + 1 && fixture.engine.starts.count == 1
        && state.status.phase == .error && state.selectedOutputID == nil,
      "Disconnected retry must rescan once and never use another available stereo output")
    try require(
      state.preferences.outputDeviceUID == Fixture.output.uid,
      "Failed retry must retain saved UID")

    let reconnectedOutput = AudioDeviceInfo(
      id: 299, name: "Renamed Speakers", uid: Fixture.output.uid, inputChannelCount: 0,
      outputChannelCount: 2, nominalSampleRate: 48_000)
    fixture.catalog.append(reconnectedOutput)
    state.refreshDevices()
    try require(
      state.selectedOutputID == reconnectedOutput.id && state.status.phase == .error
        && fixture.engine.starts.count == 1,
      "Reconnect with the same UID/new device ID must not auto-resume renderer or keep-alive")
    let beforeRetry = fixture.enumerations
    state.retrySavedRoute()
    try require(
      fixture.enumerations == beforeRetry + 1 && state.isRunning
        && fixture.engine.starts.last?.output == reconnectedOutput.id
        && fixture.engine.starts.last?.input == Fixture.input.id,
      "Explicit retry must resolve saved UID rather than old ID or name")

    state.preferences.keepOutputAlive = false
    state.stop()
    fixture.catalog.removeAll { $0.uid == Fixture.input.uid }
    fixture.catalog.append(
      AudioDeviceInfo(
        id: 399, name: Fixture.input.name, uid: "impostor-input", inputChannelCount: 16,
        outputChannelCount: 0, nominalSampleRate: 48_000))
    state.retrySavedRoute()
    try require(
      state.status.phase == .error && fixture.engine.starts.count == 2,
      "Missing saved input must not fall back even to an identical name")
    fixture.catalog.append(Fixture.input)
    fixture.safeRoute = false
    state.retrySavedRoute()
    try require(
      state.status.phase == .error && fixture.engine.starts.count == 2,
      "Retry must rerun route safety before opening audio")
    fixture.safeRoute = true
    fixture.permissionStatus = .denied
    state.retrySavedRoute()
    try require(
      state.status.phase == .error && fixture.engine.starts.count == 2,
      "Retry must rerun permission checks before opening audio")
    print(
      "PASS retry: running/pending no-op, one rescan, saved UID only, explicit reconnect, safety/permission revalidation"
    )
  }

  @MainActor
  static func diagnosticsChecks() throws {
    let fixture = Fixture()
    let state = fixture.makeState()
    state.start()
    var diagnostics = EngineDiagnostics.empty
    diagnostics.underrunCount = 3
    diagnostics.overrunCount = 2
    diagnostics.rejectedSliceCount = 1
    diagnostics.renderErrorCount = 4
    diagnostics.underrunFrames = 192
    diagnostics.overrunFrames = 128
    diagnostics.queuedFrames = 480
    diagnostics.requestedBufferFrames = 128
    diagnostics.inputBufferFrames = 256
    diagnostics.outputBufferFrames = 64
    diagnostics.driftCorrectionEnabled = true
    diagnostics.isPriming = true
    diagnostics.correctionPPM = -125.5
    diagnostics.rebufferCount = 2
    let transport = ChangeRecorder()
    let changed = ChangeRecorder()
    withObservationTracking {
      _ = state.status
    } onChange: {
      transport.record()
    }
    withObservationTracking {
      _ = state.diagnostics
    } onChange: {
      changed.record()
    }
    fixture.engine.emit(EngineStatus(phase: .running, diagnostics: diagnostics))
    try require(
      state.diagnostics == diagnostics && changed.changes == 1,
      "Diagnostics must reach separate observed state")
    try require(
      transport.changes == 0, "Diagnostics-only updates must not invalidate transport status")
    try require(
      abs(state.diagnostics.queueLatencyMs - 10) < 0.001,
      "480 queued frames at 48k must estimate 10 ms")

    let unchanged = ChangeRecorder()
    withObservationTracking {
      _ = state.diagnostics
    } onChange: {
      unchanged.record()
    }
    fixture.engine.emit(EngineStatus(phase: .running, diagnostics: diagnostics))
    var meters = MeterSnapshot.empty
    meters.outputPeakLDb = -12
    fixture.engine.emit(EngineStatus(phase: .running, meters: meters, diagnostics: diagnostics))
    try require(
      unchanged.changes == 0,
      "Identical diagnostics and meter-only updates must not invalidate diagnostics")
    fixture.engine.emit(EngineStatus(phase: .stopped, meters: meters, diagnostics: diagnostics))
    try require(
      state.diagnostics == .empty && state.meterSource.snapshot() == .empty,
      "Stopped status must discard stale diagnostics and meters")
    state.start()
    try require(state.diagnostics == .empty, "Restart must not retain previous-run counters")
    fixture.engine.emit(EngineStatus(phase: .running, diagnostics: diagnostics))
    fixture.engine.emit(EngineStatus(phase: .error, message: "Fatal", diagnostics: diagnostics))
    var failureDiagnostics = diagnostics
    failureDiagnostics.queuedFrames = 0
    failureDiagnostics.isPriming = false
    try require(
      state.diagnostics == failureDiagnostics && !state.isRunning && !state.isKeepingOutputAwake
        && state.meterSource.snapshot() == .empty && state.errorMessage == "Fatal",
      "Fatal errors must preserve final failure counts but clear queued latency, meters and active route"
    )
    state.retrySavedRoute()
    try require(state.isRunning && state.diagnostics == .empty, "Retry starts a new empty run")

    let throwing = Fixture()
    throwing.engine.startFailure = CheckFailure(message: "Published failure then thrown")
    throwing.engine.fatalStartStatus = EngineStatus(
      phase: .error, message: "Callback failure", diagnostics: diagnostics)
    let throwingState = throwing.makeState()
    throwingState.start()
    try require(
      throwingState.status.phase == .error && throwingState.diagnostics == failureDiagnostics,
      "An error publication followed by a thrown start failure must retain diagnostics across cleanup"
    )

    let disconnected = Fixture()
    let disconnectedState = disconnected.makeState()
    disconnectedState.start()
    disconnected.engine.emit(EngineStatus(phase: .running, diagnostics: diagnostics))
    disconnected.catalog.removeAll { $0.uid == Fixture.output.uid }
    disconnectedState.refreshDevices()
    try require(
      disconnectedState.status.phase == .error
        && disconnectedState.diagnostics == failureDiagnostics,
      "Device-list disconnect cleanup must preserve the last observed counters, with zero queued audio"
    )
    state.preferences.keepOutputAlive = true
    state.stop()
    var keepAliveDiagnostics = EngineDiagnostics.empty
    keepAliveDiagnostics.requestedBufferFrames = 128
    keepAliveDiagnostics.outputBufferFrames = 128
    fixture.engine.emit(EngineStatus(phase: .keepAlive, diagnostics: keepAliveDiagnostics))
    try require(
      state.diagnostics == keepAliveDiagnostics && state.diagnostics.underrunCount == 0,
      "Keep-alive exposes output sizes without inventing underruns for intentional silence")

    let fatalFixture = Fixture()
    fatalFixture.engine.fatalStartStatus = EngineStatus(phase: .error, message: "Fatal start")
    let fatal = fatalFixture.makeState()
    fatal.start()
    try require(
      !fatal.isRunning && fatal.status.phase == .error && fatal.diagnostics == .empty,
      "Synchronous fatal start must not leave a running route")
    fatal.preferences.keepOutputAlive = true
    fatal.startKeepAliveIfNeeded()
    try require(
      !fatal.isKeepingOutputAwake && fatal.status.phase == .error,
      "Synchronous fatal keep-alive start must not leave an awake route")
    print(
      "PASS diagnostics: isolated observation, buffer sizes, queue estimate, failure history, stop/restart reset"
    )
  }

  @MainActor
  static func persistenceChecks() async throws {
    let fixture = Fixture()
    let state = fixture.makeState()
    state.preferences.preampDb = -10
    state.persist()
    state.preferences.preampDb = -11
    state.persist()
    try require(fixture.writes.isEmpty, "Persistence must be deferred, not synchronous")
    // Flush is deterministic: it cancels all pending saves and writes the latest snapshot.
    state.flushPreferences()
    try require(
      fixture.writes == [state.preferences], "Flush must persist exactly the latest snapshot")
    try await Task.sleep(for: .milliseconds(400))
    try require(
      fixture.writes.count == 1, "Cancelled debounce tasks must not write again after flush")

    state.preferences.preampDb = -13
    state.persist()
    state.preferences.preampDb = -14
    state.persist()
    // Allow the main actor's debounce to finish; timing isn't used to infer backend state.
    try await Task.sleep(for: .milliseconds(400))
    try require(
      fixture.writes.count == 2 && fixture.writes.last?.preampDb == -14,
      "Debounce must coalesce edits into the latest snapshot")
    fixture.writeFailure = CheckFailure(message: "Disk full")
    state.flushPreferences()
    try require(
      state.persistenceErrorMessage == "Could not save settings: Disk full"
        && state.errorMessage == nil && state.status.phase == .stopped,
      "Preference write errors must be separately observable, not audio failures")
    let changed = ChangeRecorder()
    withObservationTracking {
      _ = state.persistenceErrorMessage
    } onChange: {
      changed.record()
    }
    let beforeEvents = fixture.engine.events
    let beforeEnumerations = fixture.enumerations
    state.retrySavePreferences()
    try require(
      fixture.engine.events == beforeEvents && fixture.enumerations == beforeEnumerations
        && fixture.writes.count == 2 && state.persistenceErrorMessage != nil,
      "Failed Retry Save must only call the writer, never transport/configuration/catalog")
    fixture.engine.emit(EngineStatus(phase: .error, message: "Engine failure"))
    fixture.writeFailure = nil
    state.retrySavePreferences()
    try require(
      state.persistenceErrorMessage == nil && changed.changes == 1
        && state.errorMessage == "Engine failure" && state.status.phase == .error
        && fixture.engine.events == beforeEvents && fixture.writes.count == 3,
      "Successful Retry Save clears only save error, preserving engine error and transport")
    fixture.writeFailure = CheckFailure(message: "Read-only volume")
    state.flushPreferences()
    state.dismissPersistenceError()
    try require(
      state.persistenceErrorMessage == nil && state.errorMessage == "Engine failure"
        && fixture.engine.events == beforeEvents,
      "Dismissing a save error must not dismiss an audio failure or touch transport")
    // Successful ordinary debounced saves clear the same error, not just explicit Retry.
    state.flushPreferences()
    fixture.writeFailure = nil
    state.persist()
    try await Task.sleep(for: .milliseconds(400))
    try require(
      state.persistenceErrorMessage == nil && state.errorMessage == "Engine failure"
        && fixture.engine.events == beforeEvents && fixture.writes.count == 4,
      "Successful debounced save clears save error only")
    state.start()
    let runningEvents = fixture.engine.events
    fixture.writeFailure = CheckFailure(message: "Disk full while rendering")
    state.flushPreferences()
    fixture.writeFailure = nil
    state.retrySavePreferences()
    try require(
      state.status.phase == .running && state.persistenceErrorMessage == nil
        && fixture.engine.events == runningEvents && fixture.engine.starts.count == 1,
      "Retry Save during rendering must neither restart nor reconfigure the active renderer")
    state.stop()
    print(
      "PASS persistence: debounce/flush, observable save-only failures, Retry Save, dismiss, engine isolation"
    )
  }
}
