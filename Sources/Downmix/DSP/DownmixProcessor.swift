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
    var globalPEQText: String = ""
    var speakerPEQText: String = ""
    var inputChannelCount: Int = 16
  }

  private var configuration = Configuration()
  private var masterGain = 1.0
  private var lfeFilterA = BiquadFilter()
  private var lfeFilterB = BiquadFilter()
  private var dryDelayIndex = 0
  private var stereoDelayL: [Double]
  private var stereoDelayR: [Double]

  private var globalLeft: [BiquadFilter] = []
  private var globalRight: [BiquadFilter] = []
  private var speakerLeft: [BiquadFilter] = []
  private var speakerRight: [BiquadFilter] = []
  private var globalPreamp = 1.0
  private var speakerPreampLeft = 1.0
  private var speakerPreampRight = 1.0

  private var inputPeaks = [Float](repeating: 0, count: 16)
  private var outputPeakL: Float = 0
  private var outputPeakR: Float = 0
  private var clipL = false
  private var clipR = false

  init() {
    stereoDelayL = [Double](repeating: 0, count: Self.butterworthDryDelaySamples)
    stereoDelayR = [Double](repeating: 0, count: Self.butterworthDryDelaySamples)
    apply(configuration: configuration)
  }

  mutating func apply(configuration: Configuration) {
    self.configuration = configuration
    masterGain = pow(10.0, configuration.preampDb / 20.0)
    rebuildLFE()
    rebuildEQ()
    stereoDelayL = [Double](repeating: 0, count: Self.butterworthDryDelaySamples)
    stereoDelayR = [Double](repeating: 0, count: Self.butterworthDryDelaySamples)
    dryDelayIndex = 0
  }

  mutating func takeMeterSnapshot() -> MeterSnapshot {
    let snapshot = MeterSnapshot(
      inputPeaksDb: inputPeaks.map(Self.db(fromLinear:)),
      outputPeakLDb: Self.db(fromLinear: outputPeakL),
      outputPeakRDb: Self.db(fromLinear: outputPeakR),
      clipL: clipL,
      clipR: clipR
    )
    for i in inputPeaks.indices { inputPeaks[i] *= 0.6 }
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

      left *= globalPreamp
      right *= globalPreamp
      for i in globalLeft.indices { left = globalLeft[i].process(left) }
      for i in globalRight.indices { right = globalRight[i].process(right) }

      if swap {
        let tmp = left
        left = right
        right = tmp
      }

      left *= speakerPreampLeft
      right *= speakerPreampRight
      for i in speakerLeft.indices { left = speakerLeft[i].process(left) }
      for i in speakerRight.indices { right = speakerRight[i].process(right) }

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
    map: [Int],
    slot: Int
  ) -> Double {
    guard slot < map.count else { return 0 }
    let deviceChannel = map[slot]
    guard deviceChannel > 0 else { return 0 }
    let index = deviceChannel - 1
    guard index < inputChannelCount else { return 0 }
    let sample = input[frameOffset + index]
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

  private mutating func rebuildEQ() {
    let sr = Self.sampleRate
    let global = PEQParser.parse(configuration.globalPEQText)
    let speaker = PEQParser.parse(configuration.speakerPEQText)

    globalPreamp = pow(10.0, global.preampDb / 20.0)
    speakerPreampLeft = pow(10.0, speaker.preampDb / 20.0)
    speakerPreampRight = pow(10.0, speaker.preampDb / 20.0)

    globalLeft = makeFilters(bands: global.bands, side: .left, sampleRate: sr)
    globalRight = makeFilters(bands: global.bands, side: .right, sampleRate: sr)

    // Match original launcher: with swap on, CH1 feeds physical left and CH0 feeds physical right.
    if configuration.swapOutputs {
      speakerLeft = makeFilters(bands: speaker.bands, side: .right, sampleRate: sr)
      speakerRight = makeFilters(bands: speaker.bands, side: .left, sampleRate: sr)
    } else {
      speakerLeft = makeFilters(bands: speaker.bands, side: .left, sampleRate: sr)
      speakerRight = makeFilters(bands: speaker.bands, side: .right, sampleRate: sr)
    }
  }

  private enum Side { case left, right }

  private func makeFilters(bands: [PEQBand], side: Side, sampleRate: Double) -> [BiquadFilter] {
    var filters: [BiquadFilter] = []
    for band in bands {
      switch band.channel {
      case .all:
        break
      case .left:
        if side != .left { continue }
      case .right:
        if side != .right { continue }
      case .index(let index):
        if side == .left && index != 0 { continue }
        if side == .right && index != 1 { continue }
      }

      var filter = BiquadFilter()
      switch band.kind {
      case .peaking:
        filter.coefficients = BiquadDesign.peaking(
          freq: band.frequency,
          q: band.q,
          gainDb: band.gainDb,
          sampleRate: sampleRate
        )
      case .lowShelf:
        filter.coefficients = BiquadDesign.lowShelf(
          freq: band.frequency,
          q: band.q,
          gainDb: band.gainDb,
          sampleRate: sampleRate
        )
      case .highShelf:
        filter.coefficients = BiquadDesign.highShelf(
          freq: band.frequency,
          q: band.q,
          gainDb: band.gainDb,
          sampleRate: sampleRate
        )
      case .off:
        continue
      }
      filters.append(filter)
    }
    return filters
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
