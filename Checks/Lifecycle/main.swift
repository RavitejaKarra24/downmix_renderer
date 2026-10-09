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

  func makeState(_ preferences: AppPreferences = AppPreferences()) -> AppState {
    AppState(
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
      installListeners: false
    )
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
    print("All AppState lifecycle checks passed (13 groups)")
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
      ready.checks.filter { $0.status == .manual }.map(\.id) == [.speakerMapping, .systemOutput],
      "Speaker mapping and system output must always remain manual, never certified")
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
    try require(
      state.setupChecklist.checks.filter { $0.status == .needsAttention }.map(\.id)
        == [.input, .inputRate, .outputRate, .output],
      "Wrong input/output channel counts and both sample rates must need attention")

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
