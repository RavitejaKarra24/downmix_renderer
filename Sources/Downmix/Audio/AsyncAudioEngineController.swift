import CoreAudio
import Foundation

/// Optional bridge capability: final cleanup counters are not transport status.
/// A preserved run is invalidated by explicit Stop or ANY new run intent.
@MainActor
protocol AudioFailureDiagnosticsControlling: AnyObject {
  func setFinalDiagnosticsHandler(_ handler: @escaping (EngineDiagnostics) -> Void)
  func invalidateFailureDiagnostics()
  func stopPreservingFailureDiagnostics()
}

/// Main-actor intent bridge. Never waits for HAL, including during stop or destruction.
/// Each command advances delivery generation; each start owns a distinct one-way gate.
@MainActor
final class AsyncAudioEngineController: AudioFailureDiagnosticsControlling {
  private let queue: DispatchQueue
  private let owner: WorkerOwner
  private var operationID: UInt64 = 0
  private var renderGate: AudioRenderGate?
  private var onStatus: ((EngineStatus) -> Void)?
  private var onFinalDiagnostics: ((EngineDiagnostics) -> Void)?
  private var failureCleanupGate: AudioRenderGate?

  /// Factory executes on the private off-main serial queue. Do not supply a main/concurrent
  /// queue or a worker shared with another controller. No real units are opened by init.
  init(
    queue: DispatchQueue = DispatchQueue(label: "com.local.downmix.audio-control"),
    workerFactory: @escaping @Sendable (DispatchQueue) -> any AudioEngineWorker = {
      AudioEngine(queue: $0)
    }
  ) {
    self.queue = queue
    owner = WorkerOwner(queue: queue, factory: workerFactory)
  }

  /// Production discovery/safety reads share HAL control's serial queue. UI reads
  /// only immutable results; no second queue can race route checks with setup.
  func makeDeviceCatalogProvider(
    catalog: @escaping @Sendable () -> [AudioDeviceInfo] = DeviceManager.allDevices,
    routeSafety: @escaping @Sendable (AudioDeviceInfo, String) -> Bool = DeviceManager
      .isSafeOutputRoute
  ) -> DeviceCatalogProvider {
    DeviceCatalogProvider(queue: queue, catalog: catalog, routeSafety: routeSafety)
  }

  func setStatusHandler(_ handler: @escaping (EngineStatus) -> Void) {
    onStatus = handler
  }

  func setFinalDiagnosticsHandler(_ handler: @escaping (EngineDiagnostics) -> Void) {
    onFinalDiagnostics = handler
  }

  func invalidateFailureDiagnostics() {
    failureCleanupGate = nil
    if renderGate?.isOpen == false { renderGate = nil }
  }

  func start(
    inputDeviceID: AudioDeviceID,
    outputDeviceID: AudioDeviceID,
    configuration: DownmixProcessor.Configuration,
    framesPerBuffer: Int,
    keepAliveOnly: Bool = false
  ) throws {
    operationID &+= 1
    let id = operationID
    failureCleanupGate = nil
    renderGate?.close()
    let gate = AudioRenderGate()
    renderGate = gate
    let deliver = delivery(for: id, run: gate)
    // Enqueue BEFORE synchronous publication: reentrant handlers may stop/restart.
    queue.async { [owner] in
      guard gate.isOpen else { return }  // Cancelled queued starts never open hardware.
      let worker = owner.getWorker()
      owner.runGate = gate
      owner.failureStatus = nil
      worker.setStatusHandler(deliver)
      do {
        try worker.start(
          inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID,
          configuration: configuration, framesPerBuffer: framesPerBuffer,
          keepAliveOnly: keepAliveOnly, renderGate: gate)
        // UnitStart may return after cancellation. The gate stayed closed throughout;
        // dispose immediately, before servicing ANY subsequent queue command.
        if !gate.isOpen {
          worker.setStatusHandler { _ in }
          worker.stop()
        }
      } catch {
        gate.close()
        let snapshot = worker.currentStatus
        let failure =
          snapshot.phase == .error
          ? snapshot : EngineStatus(phase: .error, message: error.localizedDescription)
        // Also clean up partially initialized injectable workers. Cleanup publications
        // must not overwrite the final error (or a newer logical command).
        worker.setStatusHandler { _ in }
        worker.stop()
        owner.failureStatus = failure
        deliver(failure)
      }
    }
    onStatus?(
      EngineStatus(
        phase: .starting,
        message: keepAliveOnly ? "Opening output keep-alive…" : "Opening audio devices…"))
  }

  func updateConfiguration(_ configuration: DownmixProcessor.Configuration) {
    operationID &+= 1
    guard let gate = renderGate else { return }
    let deliver = delivery(for: operationID, run: gate)
    queue.async { [owner] in
      guard owner.runGate === gate, let worker = owner.existingWorker else { return }
      // Retag this run, not a previous start. FIFO preserves pending-start config order.
      worker.setStatusHandler(deliver)
      if gate.isOpen { worker.updateConfiguration(configuration) }
      // A startup completion already enqueued under the previous operation is stale.
      // Republish the current phase so config during warmup cannot strand UI in starting.
      deliver(owner.failureStatus ?? worker.currentStatus)
    }
  }

  func stop() {
    stop(preservingFailureDiagnostics: false)
  }

  func stopPreservingFailureDiagnostics() {
    stop(preservingFailureDiagnostics: true)
  }

  private func stop(preservingFailureDiagnostics: Bool) {
    operationID &+= 1
    let stoppedGate = renderGate
    // Repeated local failures can retain the same cleanup run, but explicit Stop
    // always revokes it. Neither a later permission intent nor a new run can inherit it.
    failureCleanupGate = preservingFailureDiagnostics ? (stoppedGate ?? failureCleanupGate) : nil
    renderGate?.close()  // Only shared mutation; never touch worker/DSP storage from main.
    renderGate = nil
    let deliver = delivery(for: operationID)
    let final = finalDelivery(for: failureCleanupGate)
    queue.async { [owner] in
      guard let worker = owner.existingWorker else { return }
      let preserveRun = preservingFailureDiagnostics && owner.runGate === stoppedGate
      if preserveRun {
        final((owner.failureStatus ?? worker.currentStatus).diagnostics)
      }
      if preservingFailureDiagnostics {
        worker.setStatusHandler { status in
          // Teardown failure is cleanup of an already-failed run, not a new UI
          // error/intent. Retain its counters without replacing the local reason.
          if status.phase == .error { final(status.diagnostics) }
        }
      } else {
        worker.setStatusHandler(deliver)
      }
      worker.stop()
      // Read fresh atomics after callback quiescence, not only the last UI-cadence
      // status. A local disconnect can precede the worker watchdog publication.
      if preserveRun { final(worker.finalDiagnostics) }
    }
    onStatus?(EngineStatus(phase: .stopped, message: "Audio muted; cleanup pending…"))
  }

  private func finalDelivery(for run: AudioRenderGate?) -> @Sendable (EngineDiagnostics) -> Void {
    { [weak self] diagnostics in
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          guard let self, let run, self.failureCleanupGate === run else { return }
          self.onFinalDiagnostics?(diagnostics)
        }
      }
    }
  }

  private func delivery(for id: UInt64, run: AudioRenderGate? = nil)
    -> @Sendable (EngineStatus) -> Void
  {
    { [weak self] status in
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          if self.operationID == id {
            self.onStatus?(status)
          } else if status.phase == .error, let run, self.failureCleanupGate === run {
            // An error may already be queued on main when a device refresh mutes
            // locally. Keep its newer counters, but not its old message or intent.
            self.onFinalDiagnostics?(status.diagnostics)
          }
        }
      }
    }
  }

  deinit {
    renderGate?.close()
    // Capture owner, never the dying bridge. It retains the backend through teardown and
    // releases it ON its queue. Application termination does not wait: if the process
    // exits first, the OS ends the units; no main-thread sync/termination deadlock.
    queue.async { [owner] in owner.shutdown() }
  }
}

/// Queue-confined backend lifetime. Unchecked only because Swift cannot express GCD
/// confinement; ALL mutable accesses and the backend's final release occur on queue.
private final class WorkerOwner: @unchecked Sendable {
  let queue: DispatchQueue
  let factory: @Sendable (DispatchQueue) -> any AudioEngineWorker
  private var worker: (any AudioEngineWorker)?
  // These too are accessed only by queue command closures.
  var runGate: AudioRenderGate?
  var failureStatus: EngineStatus?

  init(
    queue: DispatchQueue,
    factory: @escaping @Sendable (DispatchQueue) -> any AudioEngineWorker
  ) {
    self.queue = queue
    self.factory = factory
  }

  var existingWorker: (any AudioEngineWorker)? {
    dispatchPrecondition(condition: .onQueue(queue))
    return worker
  }

  func getWorker() -> any AudioEngineWorker {
    dispatchPrecondition(condition: .onQueue(queue))
    dispatchPrecondition(condition: .notOnQueue(.main))
    if let worker { return worker }
    let created = factory(queue)
    worker = created
    return created
  }

  func shutdown() {
    dispatchPrecondition(condition: .onQueue(queue))
    worker?.setStatusHandler { _ in }
    worker?.stop()
    worker = nil
    runGate = nil
  }
}
