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
  /// worker rebuilds the pipeline when the HAL applies it; the selected output follows.
  func setInputSampleRate(_ rate: Double)
  /// Independently revocable policy authorization, in addition to the audio run gate.
  func setInputSampleRate(_ rate: Double, requestGate: AudioRateRequest)
  /// Source bit depth to reproduce at the DAC for this run; `nil` selects the deepest.
  func setOutputBitDepth(_ bits: Int?)
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
  /// worker rebuilds the pipeline when the HAL applies it; the selected output follows.
  func requestInputSampleRate(_ rate: Double)
  func requestInputSampleRate(_ rate: Double, requestGate: AudioRateRequest?)
  func requestOutputBitDepth(_ bits: Int?)
  func stop()
}

extension AudioEngineControlling {
  func setInputSampleRate(_ rate: Double, requestGate: AudioRateRequest) {
    guard requestGate.isOpen else { return }
    setInputSampleRate(rate)
  }

  func setOutputBitDepth(_ bits: Int?) {}
}

extension AudioEngineWorker {
  func requestInputSampleRate(_ rate: Double, requestGate: AudioRateRequest?) {
    guard requestGate?.isOpen != false else { return }
    requestInputSampleRate(rate)
  }

  var finalDiagnostics: EngineDiagnostics { currentStatus.diagnostics }

  func requestOutputBitDepth(_ bits: Int?) {}
}

extension AudioEngine: AudioEngineWorker {}
extension AsyncAudioEngineController: AudioEngineControlling {}
