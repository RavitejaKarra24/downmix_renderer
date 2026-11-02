import CoreAudio

/// Synchronous UI intent and logical status delivery; hardware work is asynchronous.
/// Render callbacks must never invoke the status handler. Existing fakes remain synchronous.
@MainActor
protocol AudioEngineControlling: AnyObject {
  func setStatusHandler(_ handler: @escaping (EngineStatus) -> Void)
  func start(
    inputDeviceID: AudioDeviceID,
    outputDeviceID: AudioDeviceID,
    configuration: DownmixProcessor.Configuration,
    framesPerBuffer: Int,
    keepAliveOnly: Bool
  ) throws
  func updateConfiguration(_ configuration: DownmixProcessor.Configuration)
  /// Best-effort: asks the running input device to change its nominal rate. The
  /// worker reopens the input when the HAL applies it. Never changes the output.
  func setInputSampleRate(_ rate: Double)
  func stop()
}

/// Every method (including handler installation/status reads) runs on the supplied serial
/// worker queue. Implementations must keep callback resources alive through stop/disposal.
/// Sendable permits queue transfer, NOT concurrent control calls. No UI actor work here.
protocol AudioEngineWorker: AnyObject, Sendable {
  var currentStatus: EngineStatus { get }
  /// Fresh atomic counters, including after cleanup; unlike status, Stop does not erase them.
  var finalDiagnostics: EngineDiagnostics { get }
  func setStatusHandler(_ handler: @escaping @Sendable (EngineStatus) -> Void)
  func start(
    inputDeviceID: AudioDeviceID,
    outputDeviceID: AudioDeviceID,
    configuration: DownmixProcessor.Configuration,
    framesPerBuffer: Int,
    keepAliveOnly: Bool,
    renderGate: AudioRenderGate?
  ) throws
  func updateConfiguration(_ configuration: DownmixProcessor.Configuration)
  /// Best-effort: asks the running input device to change its nominal rate. The
  /// worker reopens the input when the HAL applies it. Never changes the output.
  func requestInputSampleRate(_ rate: Double)
  func stop()
}

extension AudioEngineWorker {
  var finalDiagnostics: EngineDiagnostics { currentStatus.diagnostics }
}

extension AudioEngine: AudioEngineWorker {}
extension AsyncAudioEngineController: AudioEngineControlling {}
