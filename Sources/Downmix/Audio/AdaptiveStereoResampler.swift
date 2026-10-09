import Foundation

/// Time-scaled queue PI, shared with the offline clock checks (not a second model).
/// Positive correction consumes source faster. Units: frames, seconds, ppm at 48 kHz.
/// A one-second fill filter rejects packet jitter; conditional integration prevents
/// windup at BOTH the rate and slew limits. Only the output consumer may mutate it.
struct AdaptiveClockDriftController {
  static let maximumPPM = 2000.0
  static let slewPPMPerSecond = 100.0
  private(set) var correctionPPM = 0.0
  private var filteredError = 0.0
  private var integral = 0.0

  mutating func reset() {
    correctionPPM = 0
    filteredError = 0
    integral = 0
  }

  /// A signal gap invalidates queue-error history, not the selected devices' learned
  /// clock bias. Preserve the current estimate instead of relearning through gaps.
  mutating func rebuffer() {
    filteredError = 0
    integral = correctionPPM
  }

  mutating func step(errorFrames: Double, frameCount: Int) {
    guard frameCount > 0 else { return }
    let seconds = Double(frameCount) / 48_000
    filteredError += seconds / (1 + seconds) * (errorFrames - filteredError)
    let proposedIntegral = integral + 0.2 * filteredError * seconds
    let proposedCommand = 4 * filteredError + proposedIntegral
    let slew = Self.slewPPMPerSecond * seconds
    // Freeze integration only when it would push further into a limiting boundary.
    let upper = min(Self.maximumPPM, correctionPPM + slew)
    let lower = max(-Self.maximumPPM, correctionPPM - slew)
    if !((proposedCommand > upper && filteredError > 0)
      || (proposedCommand < lower && filteredError < 0))
    {
      integral = max(-Self.maximumPPM, min(Self.maximumPPM, proposedIntegral))
    }
    correctionPPM = max(lower, min(upper, 4 * filteredError + integral))
  }
}

/// Small asynchronous-clock correction, NOT a general sample-rate converter.
///
/// Ownership: one output consumer exclusively owns this object and all properties;
/// the independent producer may only write `ring`. Construct/destroy off the callback.
/// No callback allocation, locks, logging, or reference-payload replacement. Work is
/// bounded by maximumOutputFrames * 48 taps plus a bounded source-buffer compaction.
///
/// `targetFrames` is the desired source reservoir AFTER a callback (including FIR
/// lookahead, excluding consumed history), floored at 25 frames. Ring capacity must
/// accommodate target + maximumOutputFrames + producer packet/jitter headroom.
/// Startup waits for target + requested output frames. The 48-tap, 1024-phase
/// Blackman-windowed sinc has 24 source frames (0.5 ms) lookahead, a 0.96-Nyquist
/// cutoff, per-phase unity DC gain, and coefficient interpolation between phases.
/// Stereo shares a continuous source position across calls. The queue adds its own
/// target / 48000 seconds latency; lookahead is INCLUDED in that reservoir.
///
/// Ratio is 1 + correctionPPM / 1e6, limited to [0.998, 1.002], slew 100 ppm/s.
/// Underflow returns a valid prefix, then forgets all local history/lookahead and
/// reprimes; no stale samples can cross a starvation gap. Caller MUST zero the
/// unproduced suffix. Nonpositive/oversized requests return zero without touching
/// output or state; caller must handle bounds. No producer index is ever changed.
final class AdaptiveStereoResampler {
  // Covers startup at either limiting skew and ±1000 ppm reversals with the
  // deliberately gentle clock slew. Smaller laboratory reservoirs may rebuffer.
  static let minimumRecommendedTargetFrames = 2048
  private static let taps = 48
  private static let phases = 1024
  private static let history = 23
  private static let lookahead = 24
  private let ring: FloatRingBuffer
  private let targetFrames: Int
  private let maximumOutputFrames: Int
  private let sourceCapacity: Int
  private let source: UnsafeMutablePointer<Float>
  private let coefficients: UnsafeMutablePointer<Float>
  private var storedFrames = AdaptiveStereoResampler.history
  private var position = Double(AdaptiveStereoResampler.history)
  private var controller = AdaptiveClockDriftController()
  private(set) var isPriming = true
  private(set) var rebufferCount: UInt64 = 0

  var bufferedFrames: Int {
    ring.availableToRead / 2 + max(0, storedFrames - Int(position))
  }

  var correctionPPM: Double { controller.correctionPPM }

  init(ring: FloatRingBuffer, targetFrames: Int, maximumOutputFrames: Int) {
    precondition(targetFrames > 0 && maximumOutputFrames > 0)
    // Also bound constructor arithmetic before converting floating-point to Int.
    precondition(maximumOutputFrames <= (Int.max - 128) / 4)
    precondition(targetFrames <= Int.max - maximumOutputFrames)
    self.ring = ring
    self.targetFrames = max(targetFrames, Self.lookahead + 1)
    self.maximumOutputFrames = maximumOutputFrames
    sourceCapacity = Int(ceil(Double(maximumOutputFrames) * 1.002)) + Self.taps + 2
    source = .allocate(capacity: sourceCapacity * 2)
    source.initialize(repeating: 0, count: sourceCapacity * 2)
    coefficients = .allocate(capacity: (Self.phases + 1) * Self.taps)
    coefficients.initialize(repeating: 0, count: (Self.phases + 1) * Self.taps)

    for phase in 0...Self.phases {
      let fraction = Double(phase) / Double(Self.phases)
      var sum = 0.0
      for tap in 0..<Self.taps {
        let distance = Double(tap - Self.history) - fraction
        let angle = Double.pi * distance / 24
        let window = 0.42 + 0.5 * cos(angle) + 0.08 * cos(2 * angle)
        let x = Double.pi * 0.96 * distance
        let sinc = abs(x) < 1e-12 ? 1 : sin(x) / x
        let weight = 0.96 * sinc * window
        coefficients[phase * Self.taps + tap] = Float(weight)
        sum += weight
      }
      for tap in 0..<Self.taps {
        coefficients[phase * Self.taps + tap] /= Float(sum)
      }
    }
  }

  deinit {
    source.deinitialize(count: sourceCapacity * 2)
    source.deallocate()
    coefficients.deinitialize(count: (Self.phases + 1) * Self.taps)
    coefficients.deallocate()
  }

  func render(into output: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
    guard frameCount > 0 && frameCount <= maximumOutputFrames else { return 0 }
    if isPriming {
      guard bufferedFrames >= targetFrames + frameCount else { return 0 }
      isPriming = false
    }

    let ratio = 1 + controller.correctionPPM / 1_000_000
    let needed = Int(ceil(position + Double(frameCount - 1) * ratio)) + Self.lookahead + 1
    let toRead = max(0, min(sourceCapacity - storedFrames, needed - storedFrames))
    storedFrames += ring.read(into: source.advanced(by: storedFrames * 2), count: toRead * 2) / 2

    var produced = 0
    for frame in 0..<frameCount {
      let center = Int(position)
      guard center + Self.lookahead < storedFrames else { break }
      let phase = (position - Double(center)) * Double(Self.phases)
      let phaseIndex = Int(phase)
      let blend = Float(phase - Double(phaseIndex))
      let weights = coefficients.advanced(by: phaseIndex * Self.taps)
      let samples = source.advanced(by: (center - Self.history) * 2)
      var left: Float = 0
      var right: Float = 0
      for tap in 0..<Self.taps {
        let weight = weights[tap] + blend * (weights[tap + Self.taps] - weights[tap])
        left += samples[tap * 2] * weight
        right += samples[tap * 2 + 1] * weight
      }
      output[frame * 2] = left
      output[frame * 2 + 1] = right
      position += ratio
      produced += 1
    }

    if produced < frameCount {
      // A gap breaks signal continuity. Drop only consumer-owned local data, in
      // complete stereo frames; leave unread ring data and producer ownership alone.
      rebufferCount &+= 1
      isPriming = true
      storedFrames = Self.history
      position = Double(Self.history)
      for sample in 0..<(Self.history * 2) { source[sample] = 0 }
      controller.rebuffer()
    } else {
      let retired = Int(position) - Self.history
      storedFrames -= retired
      position -= Double(retired)
      // Forward scalar copy is overlap-safe when compacting toward lower addresses.
      for sample in 0..<(storedFrames * 2) { source[sample] = source[sample + retired * 2] }
      controller.step(errorFrames: Double(bufferedFrames - targetFrames), frameCount: produced)
    }
    return produced
  }
}
