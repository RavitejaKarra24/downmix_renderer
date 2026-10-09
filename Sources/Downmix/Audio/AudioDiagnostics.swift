import Foundation
import Synchronization

/// Per-run counters. Queue latency is buffered stereo audio, not end-to-end device latency.
struct EngineDiagnostics: Sendable, Equatable {
  var underrunCount: UInt64 = 0
  var overrunCount: UInt64 = 0
  var rejectedSliceCount: UInt64 = 0
  var renderErrorCount: UInt64 = 0
  var underrunFrames: UInt64 = 0
  var overrunFrames: UInt64 = 0
  var queuedFrames: Int = 0
  var requestedBufferFrames: Int = 0
  var inputBufferFrames: Int = 0
  var outputBufferFrames: Int = 0
  var driftCorrectionEnabled: Bool = false
  var isPriming: Bool = false
  var correctionPPM: Double = 0
  var rebufferCount: UInt64 = 0

  var queueLatencyMs: Double { Double(queuedFrames) / 48 }
  static let empty = EngineDiagnostics()
}

/// Input and output callbacks each update only atomic counters. No logging or UI callbacks.
/// A snapshot is approximate across counters, never a transactional audio timeline.
final class AudioDiagnostics: Sendable {
  private let underruns = Atomic<UInt64>(0)
  private let overruns = Atomic<UInt64>(0)
  private let rejectedSlices = Atomic<UInt64>(0)
  private let renderErrors = Atomic<UInt64>(0)
  private let missingFrames = Atomic<UInt64>(0)
  private let droppedFrames = Atomic<UInt64>(0)
  private let queueFrames = Atomic<Int>(0)
  private let pendingFailure = Atomic<Int32>(0)
  private let clipping = Atomic<UInt32>(0)
  private let driftEnabled = Atomic<Bool>(false)
  private let priming = Atomic<Bool>(false)
  private let correctionMilliPPM = Atomic<Int64>(0)
  private let rebufferEvents = Atomic<UInt64>(0)

  func recordUnderrun(frames: Int) {
    guard frames > 0 else { return }
    underruns.wrappingAdd(1, ordering: .relaxed)
    missingFrames.wrappingAdd(UInt64(frames), ordering: .relaxed)
  }

  func recordOverrun(frames: Int) {
    guard frames > 0 else { return }
    overruns.wrappingAdd(1, ordering: .relaxed)
    droppedFrames.wrappingAdd(UInt64(frames), ordering: .relaxed)
  }

  func recordRejectedSlice(error: Int32) {
    rejectedSlices.wrappingAdd(1, ordering: .relaxed)
    pendingFailure.store(error, ordering: .releasing)
  }

  func recordRenderError(_ error: Int32) {
    renderErrors.wrappingAdd(1, ordering: .relaxed)
    pendingFailure.store(error, ordering: .releasing)
  }

  /// Called by the output consumer after reading; producer never observes consumer-owned state.
  func updateQueuedFrames(_ frames: Int) {
    queueFrames.store(max(0, frames), ordering: .relaxed)
  }

  /// Output-consumer publication; the UI reads an approximate multi-field snapshot.
  func updateClockCorrection(
    enabled: Bool, isPriming: Bool, correctionPPM: Double, rebufferCount: UInt64
  ) {
    driftEnabled.store(enabled, ordering: .relaxed)
    priming.store(isPriming, ordering: .relaxed)
    let finitePPM = correctionPPM.isFinite ? correctionPPM : 0
    correctionMilliPPM.store(
      Int64((min(2000, max(-2000, finitePPM)) * 1000).rounded()), ordering: .relaxed)
    rebufferEvents.store(rebufferCount, ordering: .relaxed)
  }

  func recordClipping(left: Bool, right: Bool) {
    let bits: UInt32 = (left ? 1 : 0) | (right ? 2 : 0)
    if bits != 0 { clipping.bitwiseOr(bits, ordering: .relaxed) }
  }

  /// UI/control consumer. Events survive overwritten/coalesced meter snapshots.
  func takeClipping() -> (left: Bool, right: Bool) {
    let bits = clipping.exchange(0, ordering: .relaxed)
    return (bits & 1 != 0, bits & 2 != 0)
  }

  func takePendingFailure() -> Int32 {
    pendingFailure.exchange(0, ordering: .acquiringAndReleasing)
  }

  func snapshot(requested: Int, input: Int, output: Int) -> EngineDiagnostics {
    EngineDiagnostics(
      underrunCount: underruns.load(ordering: .relaxed),
      overrunCount: overruns.load(ordering: .relaxed),
      rejectedSliceCount: rejectedSlices.load(ordering: .relaxed),
      renderErrorCount: renderErrors.load(ordering: .relaxed),
      underrunFrames: missingFrames.load(ordering: .relaxed),
      overrunFrames: droppedFrames.load(ordering: .relaxed),
      queuedFrames: queueFrames.load(ordering: .relaxed),
      requestedBufferFrames: requested,
      inputBufferFrames: input,
      outputBufferFrames: output,
      driftCorrectionEnabled: driftEnabled.load(ordering: .relaxed),
      isPriming: priming.load(ordering: .relaxed),
      correctionPPM: Double(correctionMilliPPM.load(ordering: .relaxed)) / 1000,
      rebufferCount: rebufferEvents.load(ordering: .relaxed)
    )
  }
}
