import AVFoundation
import CoreAudio
import Foundation
import Synchronization

struct CheckFailure: Error, LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// Only the test worker blocks, on its dedicated serial queue, with a bounded wait.
/// Test observations cross queues through Mutex; no wait/sleep ever blocks main.
final class Probe: Sendable {
  struct Start: Sendable {
    let output: AudioDeviceID
    let keepAlive: Bool
    let frames: Int
    let configuration: DownmixProcessor.Configuration
    let gate: AudioRenderGate
    let handler: @Sendable (EngineStatus) -> Void
  }

  struct State: Sendable {
    var starts: [Start] = []
    var updates: [DownmixProcessor.Configuration] = []
    var events: [String] = []
    var created = 0
    var destroyed = 0
    var blockNext = false
    var failNext = false
    var stopFailureDiagnostics: EngineDiagnostics?
    var unpublishedDiagnostics: EngineDiagnostics?
    var startReturned = 0
  }

  let state = Mutex(State())
  let release = DispatchSemaphore(value: 0)

  var snapshot: State { state.withLock { $0 } }
}

/// Unchecked Sendable is queue confinement, exactly the worker protocol contract.
/// No test reads these fields directly; shared observations live in Probe's Mutex.
final class DelayedWorker: AudioEngineWorker, @unchecked Sendable {
  private let queue: DispatchQueue
  private let probe: Probe
  private var status = EngineStatus()
  private var handler: @Sendable (EngineStatus) -> Void = { _ in }
  private var gate: AudioRenderGate?

  init(queue: DispatchQueue, probe: Probe) {
    dispatchPrecondition(condition: .onQueue(queue))
    dispatchPrecondition(condition: .notOnQueue(.main))
    self.queue = queue
    self.probe = probe
    probe.state.withLock { $0.created += 1 }
  }

  var currentStatus: EngineStatus {
    dispatchPrecondition(condition: .onQueue(queue))
    return status
  }

  var finalDiagnostics: EngineDiagnostics {
    dispatchPrecondition(condition: .onQueue(queue))
    return probe.snapshot.unpublishedDiagnostics ?? status.diagnostics
  }

  func setStatusHandler(_ handler: @escaping @Sendable (EngineStatus) -> Void) {
    dispatchPrecondition(condition: .onQueue(queue))
    self.handler = handler
  }

  func start(
    inputDeviceID: AudioDeviceID,
    outputDeviceID: AudioDeviceID,
    configuration: DownmixProcessor.Configuration,
    framesPerBuffer: Int,
    keepAliveOnly: Bool,
    renderGate: AudioRenderGate?
  ) throws {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let renderGate else { throw CheckFailure(message: "Missing per-run gate") }
    gate = renderGate
    let (block, fail) = probe.state.withLock { state in
      state.starts.append(
        .init(
          output: outputDeviceID, keepAlive: keepAliveOnly, frames: framesPerBuffer,
          configuration: configuration,
          gate: renderGate, handler: handler))
      state.events.append("start-\(outputDeviceID)")
      state.unpublishedDiagnostics = nil
      let flags = (state.blockNext, state.failNext)
      state.blockNext = false
      state.failNext = false
      return flags
    }
    emit(EngineStatus(phase: .starting, message: "Worker opening"))
    if block, probe.release.wait(timeout: .now() + 5) != .success {
      throw CheckFailure(message: "Bounded startup wait timed out")
    }
    probe.state.withLock { $0.startReturned += 1 }
    if fail {
      emit(EngineStatus(phase: .error, message: "Injected setup failure"))
      throw CheckFailure(message: "Injected setup failure")
    }
    // Intentionally misbehave like a late UnitStart: publish running even if cancelled.
    emit(EngineStatus(phase: keepAliveOnly ? .keepAlive : .running, message: "Worker running"))
  }

  func updateConfiguration(_ configuration: DownmixProcessor.Configuration) {
    dispatchPrecondition(condition: .onQueue(queue))
    probe.state.withLock {
      $0.updates.append(configuration)
      $0.events.append("config-\(configuration.preampDb)")
    }
  }

  func stop() {
    dispatchPrecondition(condition: .onQueue(queue))
    gate?.close()
    gate = nil
    let failure = probe.state.withLock {
      $0.events.append("stop")
      let failure = $0.stopFailureDiagnostics
      $0.stopFailureDiagnostics = nil
      return failure
    }
    if let failure {
      emit(EngineStatus(phase: .error, message: "Cleanup failure", diagnostics: failure))
    } else {
      emit(EngineStatus(phase: .stopped, message: "Worker disposed"))
    }
  }

  private func emit(_ status: EngineStatus) {
    self.status = status
    handler(status)
  }

  deinit {
    dispatchPrecondition(condition: .onQueue(queue))
    probe.state.withLock { $0.destroyed += 1 }
  }
}

@MainActor
final class Fixture {
  let probe = Probe()
  let queue = DispatchQueue(label: "downmix.check.async.worker")
  var statuses: [EngineStatus] = []
  var controller: AsyncAudioEngineController?

  init(block: Bool = false, fail: Bool = false) {
    probe.state.withLock {
      $0.blockNext = block
      $0.failNext = fail
    }
    controller = AsyncAudioEngineController(queue: queue) { [probe] queue in
      DelayedWorker(queue: queue, probe: probe)
    }
    controller?.setStatusHandler { [weak self] in self?.statuses.append($0) }
  }

  func start(output: AudioDeviceID = 201, keepAlive: Bool = false, preamp: Double = 0) throws {
    var config = DownmixProcessor.Configuration()
    config.preampDb = preamp
    try controller?.start(
      inputDeviceID: 101, outputDeviceID: output, configuration: config,
      framesPerBuffer: 128, keepAliveOnly: keepAlive)
  }

  func configure(_ preamp: Double) {
    var config = DownmixProcessor.Configuration()
    config.preampDb = preamp
    controller?.updateConfiguration(config)
  }

  func drainWorker() async {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume() }
    }
  }
}

/// Delayed injectable HAL queries travel through the production catalog bridge.
/// Queue-only bounded waits; all test observations use Sendable locked values.
final class CatalogProbe: Sendable {
  struct State: Sendable {
    var devices: [AudioDeviceInfo]
    var enumerations = 0
    var safetyQueries = 0
    var blockCatalog = true
    var blockSafety = true
    var safeRoute = true
  }

  let state: Mutex<State>
  let release = DispatchSemaphore(value: 0)

  init(devices: [AudioDeviceInfo]) {
    state = Mutex(State(devices: devices))
  }

  var snapshot: State { state.withLock { $0 } }

  func catalog() -> [AudioDeviceInfo] {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let (devices, block) = state.withLock {
      $0.enumerations += 1
      let block = $0.blockCatalog
      $0.blockCatalog = false
      return ($0.devices, block)
    }
    if block { _ = release.wait(timeout: .now() + 5) }
    return devices
  }

  func safety(_ output: AudioDeviceInfo, _ inputUID: String) -> Bool {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let block = state.withLock {
      $0.safetyQueries += 1
      let block = $0.blockSafety
      $0.blockSafety = false
      return block
    }
    if block { _ = release.wait(timeout: .now() + 5) }
    return state.withLock { $0.safeRoute } && output.uid != inputUID
  }
}

@main
struct AsyncControlChecks {
  @MainActor
  static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message: message) }
  }

  @MainActor
  static func eventually(_ message: String, _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
      if ContinuousClock.now >= deadline { throw CheckFailure(message: message) }
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  @MainActor
  static func main() async throws {
    try await catalogAndSafetyHeartbeat()
    try await heartbeatAndImmediateMute()
    try await queuedCancellation()
    try await cancellationRestartAndStaleDelivery()
    try await pendingConfiguration()
    try await failedStartupCleanup()
    try await keepAliveOrdering()
    try await appStateWarmup()
    try await permissionAndFailureCleanup()
    try await reentrantCommands()
    try await deinitLifetime()
    print("All async audio control checks passed (11 groups; no real HAL units opened)")
  }

  @MainActor
  static func catalogAndSafetyHeartbeat() async throws {
    let f = Fixture()
    let input = AudioDeviceInfo(
      id: 101, name: "Input", uid: "input", inputChannelCount: 16,
      outputChannelCount: 0, nominalSampleRate: 48_000)
    let oldOutput = AudioDeviceInfo(
      id: 201, name: "Output", uid: "output", inputChannelCount: 0,
      outputChannelCount: 2, nominalSampleRate: 48_000)
    let newOutput = AudioDeviceInfo(
      id: 202, name: "Reconnected Output", uid: "output", inputChannelCount: 0,
      outputChannelCount: 2, nominalSampleRate: 48_000)
    let probe = CatalogProbe(devices: [input, oldOutput])
    let provider = DeviceCatalogProvider(
      catalog: { probe.catalog() }, routeSafety: { probe.safety($0, $1) })
    var preferences = AppPreferences()
    preferences.inputDeviceUID = input.uid
    preferences.outputDeviceUID = oldOutput.uid
    preferences.autoStart = true
    let state = AppState(
      engine: f.controller!, preferences: preferences, catalogProvider: provider,
      permissionStatusProvider: { .authorized }, preferenceWriter: { _ in },
      installListeners: false)
    state.startAutomaticallyIfNeeded()
    try await eventually("Catalog did not enter off-main queue") {
      probe.snapshot.enumerations == 1
    }
    try require(
      f.probe.snapshot.starts.isEmpty && state.selectedOutputID == nil,
      "Automatic launch must wait for the initial immutable snapshot")
    for _ in 0..<8 { state.refreshDevices() }
    probe.state.withLock { $0.devices = [input, newOutput] }
    for _ in 0..<5 {
      _ = state.setupChecklist
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
    }
    try require(
      probe.snapshot.enumerations == 1 && probe.snapshot.safetyQueries == 0,
      "Main heartbeat/checklist must not wait for catalog or perform route queries")
    probe.release.signal()
    try await eventually("Safety did not enter off-main queue") {
      probe.snapshot.safetyQueries == 1
    }
    for _ in 0..<5 {
      _ = state.setupChecklist
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
    }
    try require(
      probe.snapshot.safetyQueries == 1 && f.probe.snapshot.starts.isEmpty,
      "Main heartbeat/checklist must not block on safety; auto-start still waits")
    probe.release.signal()
    try await eventually("Deferred automatic start never used latest snapshot") {
      state.status.phase == .running
    }
    try require(
      probe.snapshot.enumerations == 2 && state.selectedOutputID == newOutput.id
        && f.probe.snapshot.starts.map(\.output) == [newOutput.id],
      "Refresh storms must coalesce, discard stale snapshot, and start only saved UID's latest ID")
    let before = probe.snapshot.safetyQueries
    _ = state.setupChecklist
    try require(probe.snapshot.safetyQueries == before, "Ready checklist must use cached safety")
    state.stop()
    await f.drainWorker()
    // Production Retry from keep-alive retires that run before a delayed rescan.
    // Old output statuses and delayed stop acknowledgements cannot replace intent.
    state.preferences.keepOutputAlive = true
    state.startKeepAliveIfNeeded()
    try await eventually("Catalog fixture keep-alive did not run") {
      state.status.phase == .keepAlive
    }
    let keepAlive = f.probe.snapshot.starts.last!
    probe.state.withLock { $0.blockCatalog = true }
    let beforeRetry = probe.snapshot.enumerations
    state.retrySavedRoute()
    try await eventually("Retry rescan did not block off-main") {
      probe.snapshot.enumerations == beforeRetry + 1
    }
    let startsBeforeEdits = f.probe.snapshot.starts.count
    state.preferences.preampDb = -4
    state.persist()
    state.preferences.framesPerBuffer = 256
    state.persist()
    try require(
      state.status.phase == .starting && f.probe.snapshot.starts.count == startsBeforeEdits,
      "Gain/buffer edits must not cancel catalog Retry or start from the stale snapshot")
    keepAlive.handler(EngineStatus(phase: .keepAlive, message: "Old keep-alive tick"))
    await f.drainWorker()
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    state.retrySavedRoute()
    try require(
      !state.canRetrySavedRoute && state.status.phase == .starting && state.isRunning
        && !keepAlive.gate.isOpen,
      "Catalog retry warmup must preserve synchronous intent and central gating through old cleanup"
    )
    probe.release.signal()
    try await eventually("Production retry did not complete") { state.status.phase == .running }
    try require(
      probe.snapshot.enumerations == beforeRetry + 1,
      "Repeated warmup Retry must not enqueue a second rescan")
    try require(
      f.probe.snapshot.starts.count == startsBeforeEdits + 1
        && f.probe.snapshot.starts.last?.configuration.preampDb == -4
        && f.probe.snapshot.starts.last?.frames == 256,
      "Catalog Retry must start once with the newest gain/buffer preferences")
    state.preferences.keepOutputAlive = false
    state.stop()
    await f.drainWorker()
    // Explicit Stop cancels an initial catalog-waiting renderer intent as well.
    let stoppedProbe = CatalogProbe(devices: [input, oldOutput])
    stoppedProbe.state.withLock { $0.blockSafety = false }
    let stopped = AppState(
      engine: f.controller!, preferences: preferences,
      catalogProvider: DeviceCatalogProvider(
        catalog: { stoppedProbe.catalog() }, routeSafety: { stoppedProbe.safety($0, $1) }),
      permissionStatusProvider: { .authorized }, preferenceWriter: { _ in },
      installListeners: false)
    stopped.start()
    try require(stopped.isRunning, "Catalog-waiting Start must publish synchronous renderer intent")
    stopped.stop()
    let starts = f.probe.snapshot.starts.count
    stoppedProbe.release.signal()
    try await eventually("Cancelled catalog wait did not finish") {
      stopped.selectedOutputID != nil
    }
    try require(
      stopped.status.phase == .stopped && f.probe.snapshot.starts.count == starts,
      "Stop before snapshot must cancel pending start and not resume automatic launch")
    stoppedProbe.state.withLock { $0.safeRoute = false }
    stopped.refreshDevices()
    try await eventually("Unsafe catalog safety never reached read-only checklist") {
      stopped.setupChecklist.checks.first { $0.id == .output }?.status == .needsAttention
    }
    let queries = stoppedProbe.snapshot.safetyQueries
    stopped.start()
    stopped.preferences.keepOutputAlive = true
    stopped.startKeepAliveIfNeeded()
    try require(
      stopped.status.phase == .error && f.probe.snapshot.starts.count == starts
        && stoppedProbe.snapshot.safetyQueries == queries,
      "Production Start/keep-alive must reject cached unsafe routes without synchronous safety queries"
    )
    await f.drainWorker()
    let sharedQueue = f.queue
    let sharedProvider = f.controller!.makeDeviceCatalogProvider(
      catalog: {
        dispatchPrecondition(condition: .onQueue(sharedQueue))
        dispatchPrecondition(condition: .notOnQueue(.main))
        return [input, oldOutput]
      },
      routeSafety: { _, _ in
        dispatchPrecondition(condition: .onQueue(sharedQueue))
        return true
      })
    let shared = AppState(
      engine: f.controller!, preferences: preferences, catalogProvider: sharedProvider,
      permissionStatusProvider: { .authorized }, preferenceWriter: { _ in }, installListeners: false
    )
    shared.startAutomaticallyIfNeeded()
    try await eventually("Shared-queue catalog/automatic startup failed") {
      shared.status.phase == .running
    }
    shared.stop()
    await f.drainWorker()
    print(
      "PASS production catalog/safety heartbeat, shared HAL queue, immutable cache, stale/coalesced refresh, deferred/cancelled startup, retry gating"
    )
  }

  @MainActor
  static func heartbeatAndImmediateMute() async throws {
    let f = Fixture(block: true)
    try f.start()
    try require(f.statuses.last?.phase == .starting, "Start must synchronously publish intent")
    try await eventually("Startup never entered worker") { f.probe.snapshot.starts.count == 1 }
    var heartbeats = 0
    for _ in 0..<5 {
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
          heartbeats += 1
          continuation.resume()
        }
      }
    }
    try require(heartbeats == 5, "Main heartbeat blocked by setup")
    try require(f.probe.snapshot.startReturned == 0, "Startup did not remain blocked")
    let gate = f.probe.snapshot.starts[0].gate
    f.controller?.stop()
    try require(!gate.isOpen, "Stop must close gate BEFORE blocked setup returns")
    try require(f.statuses.last?.phase == .stopped, "Stop must be logically immediate")
    try require(
      f.statuses.last?.message.contains("pending") == true, "Logical stop should explain cleanup")
    f.probe.release.signal()
    await f.drainWorker()
    try await eventually("Teardown did not publish") {
      f.statuses.last?.message == "Worker disposed"
    }
    try require(!f.statuses.contains { $0.phase == .running }, "Cancelled startup leaked running")
    print("PASS heartbeat and immediate gate mute during blocked setup")
  }

  @MainActor
  static func queuedCancellation() async throws {
    let f = Fixture()
    // Occupy the queue before any factory/start, using a bounded wait on that queue only.
    let release = DispatchSemaphore(value: 0)
    f.queue.async { _ = release.wait(timeout: .now() + 5) }
    try f.start()
    f.controller?.stop()
    release.signal()
    await f.drainWorker()
    try require(f.probe.snapshot.created == 0, "Cancelled queued start constructed worker")
    print("PASS cancelled queued starts skip opening/factory")
  }

  @MainActor
  static func cancellationRestartAndStaleDelivery() async throws {
    let f = Fixture(block: true)
    try f.start()
    try await eventually("First start not entered") { f.probe.snapshot.starts.count == 1 }
    let old = f.probe.snapshot.starts[0]
    // Delivery is already enqueued on main BEFORE stop; the check must be at delivery time.
    old.handler(EngineStatus(phase: .running, message: "OLD running"))
    old.handler(EngineStatus(phase: .error, message: "OLD error"))
    var meters = MeterSnapshot.empty
    meters.outputPeakLDb = -1
    old.handler(EngineStatus(phase: .running, message: "OLD meters", meters: meters))
    f.controller?.stop()
    try f.start(output: 202)
    try f.start(output: 203)  // A rapid route replacement cancels the queued middle start.
    f.configure(-8)
    f.probe.release.signal()
    await f.drainWorker()
    try await eventually("Latest run not delivered after config") {
      f.statuses.last?.phase == .running
    }
    let trace = f.probe.snapshot
    try require(trace.starts.map(\.output) == [201, 203], "Restart opened obsolete queued route")
    try require(!old.gate.isOpen && trace.starts[1].gate.isOpen, "Gates shared between runs")
    try require(
      trace.events.prefix(3) == ["start-201", "stop", "stop"],
      "Cancelled in-flight setup must stop immediately before servicing queue commands")
    try require(trace.updates.last?.preampDb == -8, "Pending config missed latest run")
    try require(!f.statuses.contains { $0.message.hasPrefix("OLD") }, "Stale status escaped filter")
    let count = f.statuses.count
    old.handler(EngineStatus(phase: .error, message: "OLD watchdog error"))
    old.handler(EngineStatus(phase: .running, message: "OLD late meter", meters: meters))
    // The worker/main FIFO barriers allow all of these queued main deliveries to execute.
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    try require(f.statuses.count == count, "Old watchdog/meter delivery changed latest run")
    try require(f.statuses.allSatisfy { $0.meters == .empty }, "Old meters reached UI")
    f.controller?.stop()
    await f.drainWorker()
    print("PASS cancellation/restart, queued stale running/error/meters, latest-run config")
  }

  @MainActor
  static func pendingConfiguration() async throws {
    let f = Fixture(block: true)
    try f.start()
    try await eventually("Start not entered") { f.probe.snapshot.starts.count == 1 }
    f.configure(-3)
    f.configure(-6)
    f.configure(-9)
    f.probe.release.signal()
    await f.drainWorker()
    try await eventually("Config retag stranded starting phase") {
      f.statuses.last?.phase == .running
    }
    try require(f.probe.snapshot.updates.map(\.preampDb) == [-3, -6, -9], "Config order lost")
    try require(f.probe.snapshot.starts.count == 1, "Config cancelled/restarted pending run")
    f.controller?.stop()
    await f.drainWorker()
    print("PASS every configuration advances delivery generation without cancelling warmup")
  }

  @MainActor
  static func failedStartupCleanup() async throws {
    let f = Fixture(block: true, fail: true)
    try f.start()
    try await eventually("Failure start not entered") { f.probe.snapshot.starts.count == 1 }
    f.configure(-4)
    f.probe.release.signal()
    await f.drainWorker()
    try await eventually("Failure lost when pending config retagged run") {
      f.statuses.last?.phase == .error
    }
    try require(f.probe.snapshot.events.contains("stop"), "Failed setup was not cleaned up")
    try require(!f.probe.snapshot.starts[0].gate.isOpen, "Failed run gate left open")
    try require(f.statuses.last?.message == "Injected setup failure", "Cleanup overwrote failure")
    // A config arriving after failure but before UI changes must not invalidate the error.
    let count = f.statuses.count
    f.configure(-7)
    await f.drainWorker()
    try await eventually("Closed failed gate discarded current error") {
      f.statuses.count > count && f.statuses.last?.phase == .error
    }
    try f.start(output: 202)
    await f.drainWorker()
    try await eventually("Retry after failure never ran") { f.statuses.last?.phase == .running }
    f.controller?.stop()
    await f.drainWorker()
    print("PASS failed startup cleanup/error retagging and explicit retry")
  }

  @MainActor
  static func keepAliveOrdering() async throws {
    let f = Fixture(block: true)
    try f.start()
    try await eventually("Renderer warmup not entered") { f.probe.snapshot.starts.count == 1 }
    f.controller?.stop()
    try f.start(output: 202, keepAlive: true)
    f.probe.release.signal()
    await f.drainWorker()
    try await eventually("Keep-alive did not become latest state") {
      f.statuses.last?.phase == .keepAlive
    }
    try require(
      f.probe.snapshot.starts.map(\.keepAlive) == [false, true], "Keep-alive ordering lost")
    f.controller?.stop()
    await f.drainWorker()
    print("PASS renderer stop then output-only keep-alive ordering")
  }

  @MainActor
  static func appStateWarmup() async throws {
    let f = Fixture(block: true)
    let input = AudioDeviceInfo(
      id: 101, name: "BlackHole 16ch", uid: "input", inputChannelCount: 16,
      outputChannelCount: 0, nominalSampleRate: 48_000)
    let output = AudioDeviceInfo(
      id: 201, name: "Speakers", uid: "output", inputChannelCount: 0,
      outputChannelCount: 2, nominalSampleRate: 48_000)
    var preferences = AppPreferences()
    preferences.keepOutputAlive = true
    preferences.inputDeviceUID = input.uid
    preferences.outputDeviceUID = output.uid
    var enumerations = 0
    let state = AppState(
      engine: f.controller!, preferences: preferences,
      deviceCatalog: {
        enumerations += 1
        return [input, output]
      },
      permissionStatusProvider: { .authorized }, routeSafetyProvider: { _, _ in true },
      preferenceWriter: { _ in }, installListeners: false)
    state.startKeepAliveIfNeeded()
    try require(state.status.phase == .starting, "Missing keep-alive warmup phase")
    try require(
      !state.isRunning && state.isKeepingOutputAwake, "Warmup pretends input renderer runs")
    state.refreshDevices()
    state.startKeepAliveIfNeeded()
    try require(state.status.phase == .starting, "Refresh stopped output-only warmup for nil input")
    try await eventually("Keep-alive not entered") { f.probe.snapshot.starts.count == 1 }
    let beforeRetry = enumerations
    let keepAliveGate = f.probe.snapshot.starts[0].gate
    state.retrySavedRoute()
    try require(
      enumerations == beforeRetry && keepAliveGate.isOpen && state.isKeepingOutputAwake,
      "Retry during keep-alive warmup must not refresh, cancel or replace the pending run")
    f.probe.release.signal()
    await f.drainWorker()
    try await eventually("AppState failed keep-alive transition") {
      state.status.phase == .keepAlive
    }
    try require(f.probe.snapshot.starts.count == 1, "Keep-alive warmup was not idempotent")
    // Starting renderer replaces the output-only run; config/refresh during warmup survive.
    f.probe.state.withLock { $0.blockNext = true }
    state.start()
    try require(state.isRunning, "Renderer warmup must reflect renderer intent")
    try await eventually("Renderer replacement not entered") { f.probe.snapshot.starts.count == 2 }
    state.preferences.preampDb = -5
    state.persist()
    state.refreshDevices()
    f.probe.release.signal()
    await f.drainWorker()
    try await eventually("Renderer config during warmup stranded state") {
      state.status.phase == .running
    }
    try require(f.probe.snapshot.updates.last?.preampDb == -5, "AppState pending config was lost")
    state.preferences.keepOutputAlive = false
    state.stop()
    state.flushPreferences()
    await f.drainWorker()
    print(
      "PASS AppState logical keep-alive warmup, refresh, idempotence and pending renderer config")
  }

  @MainActor
  static func permissionAndFailureCleanup() async throws {
    let f = Fixture()
    let input = AudioDeviceInfo(
      id: 101, name: "Fixture input", uid: "input", inputChannelCount: 16,
      outputChannelCount: 0, nominalSampleRate: 48_000)
    let output = AudioDeviceInfo(
      id: 201, name: "Fixture output", uid: "output", inputChannelCount: 0,
      outputChannelCount: 2, nominalSampleRate: 48_000)
    var preferences = AppPreferences()
    preferences.keepOutputAlive = true
    preferences.inputDeviceUID = input.uid
    preferences.outputDeviceUID = output.uid
    var permission = AVAuthorizationStatus.notDetermined
    var completion: (@Sendable (Bool) -> Void)?
    var catalog = [input, output]
    let state = AppState(
      engine: f.controller!, preferences: preferences, deviceCatalog: { catalog },
      permissionStatusProvider: { permission },
      permissionRequestProvider: { completion = $0 },
      routeSafetyProvider: { _, _ in true }, preferenceWriter: { _ in }, installListeners: false)
    state.startKeepAliveIfNeeded()
    await f.drainWorker()
    try await eventually("Keep-alive did not run") { state.status.phase == .keepAlive }
    state.start()
    await f.drainWorker()
    // Flush every stop acknowledgement already enqueued on main before granting.
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    try require(
      state.status.phase == .starting && state.isRunning,
      "Cleanup cancelled newer permission intent")
    permission = .authorized
    completion?(true)
    try await eventually("Permission grant was ignored after cleanup") {
      f.probe.snapshot.starts.count == 2
    }
    await f.drainWorker()
    try await eventually("Authorized renderer did not run") { state.status.phase == .running }
    var counters = EngineDiagnostics.empty
    counters.underrunCount = 3
    counters.queuedFrames = 256
    counters.isPriming = true
    f.probe.snapshot.starts[1].handler(EngineStatus(phase: .running, diagnostics: counters))
    try await eventually("Counters not delivered") { state.diagnostics.underrunCount == 3 }
    counters.underrunCount = 7
    // Queue newer FINAL failure counters, then synchronously disconnect before
    // main delivery. Local cleanup advances operationID, but not the cleanup run tag.
    f.probe.snapshot.starts[1].handler(
      EngineStatus(phase: .error, message: "Queued worker failure", diagnostics: counters))
    var unpublished = counters
    unpublished.renderErrorCount = 9
    f.probe.state.withLock {
      $0.stopFailureDiagnostics = counters
      $0.unpublishedDiagnostics = unpublished
    }
    catalog = [input]
    state.refreshDevices()
    try require(
      state.status.phase == .error && state.diagnostics.underrunCount == 3,
      "Disconnect must synchronously preserve displayed counts before queued final delivery")
    let localError = state.errorMessage
    await f.drainWorker()
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    try require(
      state.status.phase == .error && state.errorMessage == localError
        && state.diagnostics.underrunCount == 7 && state.diagnostics.renderErrorCount == 9
        && state.diagnostics.queuedFrames == 0 && !state.diagnostics.isPriming,
      "Late cleanup erased local failure/history or missed fresh unpublished counters")
    var obsolete = counters
    obsolete.underrunCount = 99
    f.probe.snapshot.starts[1].handler(
      EngineStatus(phase: .error, message: "Obsolete cleanup", diagnostics: obsolete))
    permission = .denied
    state.start()
    let preflightError = state.errorMessage
    await f.drainWorker()
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    try require(
      state.status.phase == .error && state.errorMessage == preflightError
        && state.diagnostics.underrunCount == 7,
      "A new preflight failure must not inherit queued final counters from the previous run")
    state.preferences.keepOutputAlive = false
    state.stop()
    try require(
      state.status.phase == .stopped && state.diagnostics == .empty,
      "Explicit Stop must clear failure history")
    counters.underrunCount = 99
    f.probe.snapshot.starts[1].handler(
      EngineStatus(phase: .error, message: "Old final failure", diagnostics: counters))
    catalog = [input, output]
    state.refreshDevices()
    permission = .notDetermined
    state.start()
    await f.drainWorker()
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    try require(
      state.isRunning && state.status.phase == .starting && state.diagnostics == .empty
        && state.errorMessage == nil,
      "Old final counters must not replace/cancel a newer permission intent")
    permission = .authorized
    completion?(true)
    try await eventually("New renderer after final cleanup failed") {
      state.status.phase == .running
    }
    f.probe.snapshot.starts[1].handler(
      EngineStatus(phase: .error, message: "Previous run", diagnostics: counters))
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    try require(
      state.status.phase == .running && state.diagnostics == .empty,
      "Run-tagged final diagnostics must not leak into a new renderer run")
    state.stop()
    state.flushPreferences()
    await f.drainWorker()
    print(
      "PASS queued final 7/displayed 3 disconnect counters, local error preservation, permission/new-run isolation, explicit Stop reset"
    )
  }

  @MainActor
  static func reentrantCommands() async throws {
    let f = Fixture()
    var didRestart = false
    f.controller?.setStatusHandler { status in
      f.statuses.append(status)
      if status.phase == .starting && !didRestart {
        didRestart = true
        f.controller?.stop()
        try? f.start(output: 202, keepAlive: true)
      }
    }
    try f.start()
    await f.drainWorker()
    try await eventually("Reentrant restart overwritten") { f.statuses.last?.phase == .keepAlive }
    try require(f.probe.snapshot.starts.last?.output == 202, "Reentrant command order reversed")
    try require(
      !f.statuses.contains { $0.phase == .running }, "Older run overwrote reentrant state")
    f.controller?.setStatusHandler { [weak f] in f?.statuses.append($0) }
    f.controller?.stop()
    await f.drainWorker()
    print("PASS reentrant synchronous statuses preserve latest desired command order")
  }

  @MainActor
  static func deinitLifetime() async throws {
    let f = Fixture(block: true)
    try f.start()
    try await eventually("Lifetime start not entered") { f.probe.snapshot.starts.count == 1 }
    let gate = f.probe.snapshot.starts[0].gate
    weak var bridge = f.controller
    f.controller = nil
    try require(bridge == nil, "Queued work retained bridge")
    bridge = nil
    try require(!gate.isOpen, "Deinit failed to immediately mute")
    try require(f.probe.snapshot.destroyed == 0, "Worker released before setup/teardown quiescence")
    f.probe.release.signal()
    await f.drainWorker()
    try await eventually("Worker not released on queue after cleanup") {
      f.probe.snapshot.destroyed == 1
    }
    try require(
      f.probe.snapshot.events.filter { $0 == "stop" }.count >= 2, "Deinit omitted cleanup")
    print(
      "PASS bridge deinit is nonblocking; backend retained through cleanup and released on queue")
  }
}
