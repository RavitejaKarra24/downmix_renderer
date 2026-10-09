import Foundation

/// Real-time 9.1.6 bed → stereo processor matching peqdb ADC2-direct matrix.
struct DownmixProcessor: Sendable {
  static let sampleRate: Double = 48_000
  /// Fixed ADC2 LFE coefficient recovered from the original renderer binary.
  static let lfeCoefficient = 2.26464431
  /// Dry-path delay used when Butterworth LFE low-pass is enabled (original default).
  static let butterworthDryDelaySamples = 172

  struct Configuration: Sendable, Equatable {
    var channelMap: [Int] = Array(1...16)  // 1-based device channels for each bed slot
    var preampDb: Double = -9.5
    var lfeLowpass: Bool = true
    var swapOutputs: Bool = false
    var inputChannelCount: Int = 16
  }

  /// Fixed-size callback payload. Construct on the control side, not in a callback.
  struct RealtimeConfiguration: BitwiseCopyable, Sendable, Equatable {
    let channelMap: SIMD16<Int32>
    let preampDb: Double
    let lfeLowpass: Bool
    let swapOutputs: Bool
    let inputChannelCount: Int

    init(_ configuration: Configuration) {
      var map = SIMD16<Int32>(repeating: 0)
      for slot in 0..<min(16, configuration.channelMap.count) {
        let channel = configuration.channelMap[slot]
        if channel > 0, let fixedChannel = Int32(exactly: channel) {
          map[slot] = fixedChannel
        }
      }
      channelMap = map
      // Preserve the supported gain range and corrupt-settings fallback.
      let db = configuration.preampDb.isFinite ? configuration.preampDb : -9.5
      preampDb = min(6, max(-30, db))
      lfeLowpass = configuration.lfeLowpass
      swapOutputs = configuration.swapOutputs
      inputChannelCount = configuration.inputChannelCount
    }
  }

  private var configuration = RealtimeConfiguration(Configuration())
  private var masterGain = 1.0
  private var lfeFilterA = BiquadFilter()
  private var lfeFilterB = BiquadFilter()
  private var dryDelayIndex = 0
  // Allocated before callbacks. Keep the processor single-owned: do not copy or
  // share it during callbacks, which would trigger Array copy-on-write here.
  private var stereoDelayL: [Double]
  private var stereoDelayR: [Double]

  private var inputPeaks = SIMD16<Float>(repeating: 0)
  private var outputPeakL: Float = 0
  private var outputPeakR: Float = 0
  private var clipL = false
  private var clipR = false

  init() {
    stereoDelayL = [Double](repeating: 0, count: Self.butterworthDryDelaySamples)
    stereoDelayR = [Double](repeating: 0, count: Self.butterworthDryDelaySamples)
    rebuildLFE()
    apply(realtimeConfiguration: configuration)
  }

  /// Legacy control-side API; Array-to-POD conversion stays off the audio thread.
  mutating func apply(configuration: Configuration) {
    apply(realtimeConfiguration: RealtimeConfiguration(configuration))
  }

  mutating func apply(realtimeConfiguration configuration: RealtimeConfiguration) {
    let resetHistory =
      self.configuration.lfeLowpass != configuration.lfeLowpass
      || self.configuration.channelMap != configuration.channelMap
      || self.configuration.inputChannelCount != configuration.inputChannelCount
    self.configuration = configuration
    masterGain = pow(10.0, configuration.preampDb / 20.0)
    if resetHistory {
      lfeFilterA.reset()
      lfeFilterB.reset()
      for index in stereoDelayL.indices {
        stereoDelayL[index] = 0
        stereoDelayR[index] = 0
      }
      dryDelayIndex = 0
    }
  }

  /// Legacy control/test API. The allocating conversion must not run in a callback.
  mutating func takeMeterSnapshot() -> MeterSnapshot {
    takeRealtimeMeterSnapshot().snapshot
  }

  /// Callback-safe capture and decay: fixed-size linear peaks, no Array allocation.
  mutating func takeRealtimeMeterSnapshot() -> RealtimeMeterSnapshot {
    let snapshot = RealtimeMeterSnapshot(
      inputPeaks: inputPeaks,
      outputPeakL: outputPeakL,
      outputPeakR: outputPeakR,
      clipL: clipL,
      clipR: clipR
    )
    for i in 0..<16 { inputPeaks[i] *= 0.6 }
    outputPeakL *= 0.6
    outputPeakR *= 0.6
    clipL = false
    clipR = false
    return snapshot
  }

  /// Process interleaved multi-channel input into interleaved stereo output.
  mutating func process(
    input: UnsafePointer<Float>,
    inputChannelCount: Int,
    output: UnsafeMutablePointer<Float>,
    frameCount: Int
  ) {
    guard frameCount > 0, frameCount <= Int.max / 2 else { return }
    guard inputChannelCount > 0 else {
      output.update(repeating: 0, count: frameCount * 2)
      return
    }
    guard inputChannelCount <= Int.max / frameCount else { return }

    let map = configuration.channelMap
    let useLFEFilter = configuration.lfeLowpass
    let swap = configuration.swapOutputs
    let invSqrt2 = 0.7071067811865476
    let lfeCoef = Self.lfeCoefficient
    let delayCount = stereoDelayL.count

    for frame in 0..<frameCount {
      let frameOffset = frame * inputChannelCount
      let l = readBedSample(
        input: input, frameOffset: frameOffset, inputChannelCount: inputChannelCount, map: map,
        slot: 0)
      let r = readBedSample(
        input: input, frameOffset: frameOffset, inputChannelCount: inputChannelCount, map: map,
        slot: 1)
      let c = readBedSample(
        input: input, frameOffset: frameOffset, inputChannelCount: inputChannelCount, map: map,
        slot: 2)
      let lfeInput = readBedSample(
        input: input, frameOffset: frameOffset, inputChannelCount: inputChannelCount, map: map,
        slot: 3)
      let ls = readBedSample(
        input: input, frameOffset: frameOffset, inputChannelCount: inputChannelCount, map: map,
        slot: 4)
      let rs = readBedSample(
        input: input, frameOffset: frameOffset, inputChannelCount: inputChannelCount, map: map,
        slot: 5)
      let lrs = readBedSample(
        input: input, frameOffset: frameOffset, inputChannelCount: inputChannelCount, map: map,
        slot: 6)
      let rrs = readBedSample(
        input: input, frameOffset: frameOffset, inputChannelCount: inputChannelCount, map: map,
        slot: 7)
      let lw = readBedSample(
        input: input, frameOffset: frameOffset, inputChannelCount: inputChannelCount, map: map,
        slot: 8)
      let rw = readBedSample(
        input: input, frameOffset: frameOffset, inputChannelCount: inputChannelCount, map: map,
        slot: 9)
      let ltf = readBedSample(
        input: input, frameOffset: frameOffset, inputChannelCount: inputChannelCount, map: map,
        slot: 10)
      let rtf = readBedSample(
        input: input, frameOffset: frameOffset, inputChannelCount: inputChannelCount, map: map,
        slot: 11)
      let ltm = readBedSample(
        input: input, frameOffset: frameOffset, inputChannelCount: inputChannelCount, map: map,
        slot: 12)
      let rtm = readBedSample(
        input: input, frameOffset: frameOffset, inputChannelCount: inputChannelCount, map: map,
        slot: 13)
      let ltr = readBedSample(
        input: input, frameOffset: frameOffset, inputChannelCount: inputChannelCount, map: map,
        slot: 14)
      let rtr = readBedSample(
        input: input, frameOffset: frameOffset, inputChannelCount: inputChannelCount, map: map,
        slot: 15)

      var left = l + c * invSqrt2 + ls + lrs + lw + ltf + ltm + ltr
      var right = r + c * invSqrt2 + rs + rrs + rw + rtf + rtm + rtr

      var lfe = lfeInput
      if useLFEFilter {
        lfe = lfeFilterA.process(lfe)
        lfe = lfeFilterB.process(lfe)

        let delayedL = stereoDelayL[dryDelayIndex]
        let delayedR = stereoDelayR[dryDelayIndex]
        stereoDelayL[dryDelayIndex] = left
        stereoDelayR[dryDelayIndex] = right
        dryDelayIndex += 1
        if dryDelayIndex >= delayCount { dryDelayIndex = 0 }
        left = delayedL
        right = delayedR
      }

      left += lfe * lfeCoef
      right += lfe * lfeCoef

      left *= masterGain
      right *= masterGain

      if swap {
        let tmp = left
        left = right
        right = tmp
      }

      if left > 1 {
        left = 1
        clipL = true
      }
      if left < -1 {
        left = -1
        clipL = true
      }
      if right > 1 {
        right = 1
        clipR = true
      }
      if right < -1 {
        right = -1
        clipR = true
      }

      let outL = Float(left)
      let outR = Float(right)
      output[frame * 2] = outL
      output[frame * 2 + 1] = outR

      let absL = abs(outL)
      let absR = abs(outR)
      if absL > outputPeakL { outputPeakL = absL }
      if absR > outputPeakR { outputPeakR = absR }
    }
  }

  @inline(__always)
  private mutating func readBedSample(
    input: UnsafePointer<Float>,
    frameOffset: Int,
    inputChannelCount: Int,
    map: SIMD16<Int32>,
    slot: Int
  ) -> Double {
    let deviceChannel = Int(map[slot])
    guard deviceChannel > 0 else { return 0 }
    let index = deviceChannel - 1
    guard index < inputChannelCount else { return 0 }
    let sample = input[frameOffset + index]
    // Sanitize before metering and filtering so a bad sample cannot poison history.
    guard sample.isFinite else { return 0 }
    let magnitude = abs(sample)
    if magnitude > inputPeaks[slot] {
      inputPeaks[slot] = magnitude
    }
    return Double(sample)
  }

  private mutating func rebuildLFE() {
    let f = 125.0
    let sr = Self.sampleRate
    lfeFilterA.coefficients = BiquadDesign.lowPass(freq: f, q: 0.541196100146197, sampleRate: sr)
    lfeFilterB.coefficients = BiquadDesign.lowPass(freq: f, q: 1.3065629648763766, sampleRate: sr)
    lfeFilterA.reset()
    lfeFilterB.reset()
  }
}

/// POD mailbox payload. Peaks are linear so dB conversion also stays off callbacks.
struct RealtimeMeterSnapshot: BitwiseCopyable, Sendable, Equatable {
  var inputPeaks: SIMD16<Float>
  var outputPeakL: Float
  var outputPeakR: Float
  var clipL: Bool
  var clipR: Bool

  static let empty = RealtimeMeterSnapshot(
    inputPeaks: SIMD16<Float>(repeating: 0),
    outputPeakL: 0,
    outputPeakR: 0,
    clipL: false,
    clipR: false
  )

  /// Main/control thread only: allocates the existing UI meter Array.
  var snapshot: MeterSnapshot {
    MeterSnapshot(
      inputPeaksDb: (0..<16).map { Self.db(fromLinear: inputPeaks[$0]) },
      outputPeakLDb: Self.db(fromLinear: outputPeakL),
      outputPeakRDb: Self.db(fromLinear: outputPeakR),
      clipL: clipL,
      clipR: clipR
    )
  }

  private static func db(fromLinear value: Float) -> Float {
    if value <= 0.0000000001 { return -120 }
    return 20 * log10(value)
  }
}

struct MeterSnapshot: Sendable, Equatable {
  var inputPeaksDb: [Float]
  var outputPeakLDb: Float
  var outputPeakRDb: Float
  var clipL: Bool
  var clipR: Bool

  static let empty = MeterSnapshot(
    inputPeaksDb: [Float](repeating: -120, count: 16),
    outputPeakLDb: -120,
    outputPeakRDb: -120,
    clipL: false,
    clipR: false
  )
}
