import Foundation
import Synchronization

let assertions = Atomic<Int>(0)

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  assertions.wrappingAdd(1, ordering: .relaxed)
  guard condition() else {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

func requireNear(_ actual: Float, _ expected: Double, _ message: String, tolerance: Double = 1e-6) {
  require(
    actual.isFinite && abs(Double(actual) - expected) <= tolerance,
    "\(message): \(actual) != \(expected)")
}

func render(_ processor: inout DownmixProcessor, _ input: [Float], channels: Int = 16) -> [Float] {
  require(channels > 0 && !input.isEmpty && input.count % channels == 0, "valid check input")
  let frames = input.count / channels
  var output = [Float](repeating: .nan, count: frames * 2)
  input.withUnsafeBufferPointer { source in
    output.withUnsafeMutableBufferPointer { destination in
      processor.process(
        input: source.baseAddress!, inputChannelCount: channels,
        output: destination.baseAddress!, frameCount: frames)
    }
  }
  return output
}

func configured(_ configuration: DownmixProcessor.Configuration) -> DownmixProcessor {
  var processor = DownmixProcessor()
  processor.apply(configuration: configuration)
  return processor
}

func checkMatrixAndMapping() {
  let configuration = DownmixProcessor.Configuration(preampDb: 0, lfeLowpass: false)
  // Independent expected ADC2 matrix, in bed-slot order.
  let left = [1.0, 0, sqrt(0.5), 2.26464431, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0]
  let right = [0.0, 1, sqrt(0.5), 2.26464431, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1]
  require(DownmixProcessor.lfeCoefficient == 2.26464431, "original LFE coefficient")
  for slot in 0..<16 {
    for amplitude: Float in [-0.125, 0.125] {
      var processor = configured(configuration)
      var input = [Float](repeating: 0, count: 16)
      input[slot] = amplitude
      let output = render(&processor, input)
      requireNear(output[0], Double(amplitude) * left[slot], "matrix L slot \(slot)")
      requireNear(output[1], Double(amplitude) * right[slot], "matrix R slot \(slot)")
      let meters = processor.takeMeterSnapshot()
      requireNear(meters.inputPeaksDb[slot], 20 * log10(Double(abs(amplitude))), "input meter")
      require(!meters.clipL && !meters.clipR, "unclipped matrix impulse")
    }
  }

  var processor = configured(configuration)
  let input = (0..<16).map { Float($0 + 1) * 0.001 }
  let sum = render(&processor, input)
  requireNear(sum[0], zip(input, left).reduce(0) { $0 + Double($1.0) * $1.1 }, "matrix sum L")
  requireNear(sum[1], zip(input, right).reduce(0) { $0 + Double($1.0) * $1.1 }, "matrix sum R")

  // Every preset must route its device channels to the corresponding matrix slots.
  for preset in LayoutPreset.all {
    var config = configuration
    config.channelMap = preset.map
    let channels = preset.map.max()!
    for device in 1...channels {
      var mapped = configured(config)
      var impulse = [Float](repeating: 0, count: channels)
      impulse[device - 1] = 0.125
      let output = render(&mapped, impulse, channels: channels)
      let slots = preset.map.indices.filter { preset.map[$0] == device }
      requireNear(output[0], slots.reduce(0) { $0 + left[$1] * 0.125 }, "\(preset.id) mapping L")
      requireNear(output[1], slots.reduce(0) { $0 + right[$1] * 0.125 }, "\(preset.id) mapping R")
    }
  }

  for map in [[], [0, -1, Int.min, Int.max, 3], [2, 1], [1, 1]] {
    var config = configuration
    config.channelMap = map
    var mapped = configured(config)
    let output = render(&mapped, [0.1, -0.2, 0.2, -0.1], channels: 2)
    let expected: [Double]
    if map == [2, 1] {
      expected = [-0.2, 0.1, -0.1, 0.2]
    } else if map == [1, 1] {
      expected = [0.1, 0.1, 0.2, 0.2]
    } else {
      expected = [0, 0, 0, 0]
    }
    for index in output.indices {
      requireNear(output[index], expected[index], "short/invalid/duplicate map")
    }
  }
  var reversed = configuration
  reversed.channelMap = Array((1...16).reversed()) + [1, Int.max]
  var remapped = configured(reversed)
  let remappedOutput = render(&remapped, input)
  requireNear(
    remappedOutput[0], zip(input.reversed(), left).reduce(0) { $0 + Double($1.0) * $1.1 },
    "reverse map L")
  requireNear(
    remappedOutput[1], zip(input.reversed(), right).reduce(0) { $0 + Double($1.0) * $1.1 },
    "reverse map R")
  print("PASS: matrix and mapping")
}

func checkGainClippingAndSanitization() {
  for db in [
    -30.0, -20, -9.5, 0, 6, Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude,
    -Double.greatestFiniteMagnitude,
  ] {
    let effectiveDb = db.isFinite ? min(6, max(-30, db)) : -9.5
    for swap in [false, true] {
      var processor = configured(.init(preampDb: db, lfeLowpass: false, swapOutputs: swap))
      let output = render(&processor, [0.1, -0.2], channels: 2)
      let gain = pow(10, effectiveDb / 20)
      requireNear(output[0], (swap ? -0.2 : 0.1) * gain, "preamp/swap L")
      requireNear(output[1], (swap ? 0.1 : -0.2) * gain, "preamp/swap R")
    }
  }
  for swap in [false, true] {
    for pair: [Float] in [[2, -3], [-2, 3], [2, 0.25], [0.25, -3], [1, -1]] {
      var processor = configured(.init(preampDb: 0, lfeLowpass: false, swapOutputs: swap))
      let output = render(&processor, pair, channels: 2)
      let routed = swap ? Array(pair.reversed()) : pair
      for side in 0..<2 {
        requireNear(output[side], Double(min(1, max(-1, routed[side]))), "signed clipping")
      }
      let meters = processor.takeMeterSnapshot()
      require(meters.clipL == (abs(routed[0]) > 1), "clip flag L follows swap")
      require(meters.clipR == (abs(routed[1]) > 1), "clip flag R follows swap")
      requireNear(meters.outputPeakLDb, 20 * log10(Double(abs(output[0]))), "output meter L")
      requireNear(meters.outputPeakRDb, 20 * log10(Double(abs(output[1]))), "output meter R")
      let decayed = processor.takeMeterSnapshot()
      require(!decayed.clipL && !decayed.clipR, "clip flags consumed")
      requireNear(
        decayed.outputPeakLDb, 20 * log10(Double(abs(output[0]) * 0.6)), "meter decay",
        tolerance: 1e-5)
    }
  }

  for lowpass in [false, true] {
    for bad: Float in [.nan, .infinity, -.infinity] {
      var corrupted = configured(.init(preampDb: 0, lfeLowpass: lowpass))
      var control = configured(.init(preampDb: 0, lfeLowpass: lowpass))
      var badFrame = [Float](repeating: bad, count: 16)
      badFrame[0] = 0.1
      var cleanFrame = [Float](repeating: 0, count: 16)
      cleanFrame[0] = 0.1
      require(
        render(&corrupted, badFrame) == render(&control, cleanFrame),
        "nonfinite samples treated as silence")
      let tail = [Float](repeating: 0, count: 16 * 600)
      require(
        render(&corrupted, tail) == render(&control, tail),
        "nonfinite LFE cannot poison filter/delay")
      require(
        corrupted.takeMeterSnapshot() == control.takeMeterSnapshot(),
        "nonfinite input cannot poison meters")
    }
  }
  var extreme = configured(.init(preampDb: 6, lfeLowpass: true))
  let extremeOutput = render(
    &extreme, [Float](repeating: .greatestFiniteMagnitude, count: 16 * 500))
  require(
    extremeOutput.allSatisfy { $0.isFinite && abs($0) <= 1 }, "finite extreme inputs stay bounded")

  var processor = DownmixProcessor()
  let silence = render(&processor, [Float](repeating: 0, count: 16 * 256))
  require(silence.allSatisfy { $0 == 0 }, "silence remains silent")
  require(processor.takeMeterSnapshot() == .empty, "silence meters")
  let source: [Float] = [0]
  for count in [Int.min, -1, 0] {
    var destination: [Float] = [7, 8]
    source.withUnsafeBufferPointer { input in
      destination.withUnsafeMutableBufferPointer { output in
        processor.process(
          input: input.baseAddress!, inputChannelCount: 16, output: output.baseAddress!,
          frameCount: count)
      }
    }
    require(destination == [7, 8], "nonpositive DSP frame count is a no-op")
  }
  for channels in [Int.min, -1, 0] {
    var destination: [Float] = [7, 8]
    source.withUnsafeBufferPointer { input in
      destination.withUnsafeMutableBufferPointer { output in
        processor.process(
          input: input.baseAddress!, inputChannelCount: channels, output: output.baseAddress!,
          frameCount: 1)
      }
    }
    require(destination == [0, 0], "nonpositive channel count produces silence")
  }
  print("PASS: gain, swap, clipping, sanitization and meters")
}

func checkLowpassAndHistory() {
  require(DownmixProcessor.butterworthDryDelaySamples == 172, "original dry delay")
  var delayed = configured(.init(preampDb: 0))
  var impulse = [Float](repeating: 0, count: 16 * 400)
  impulse[0] = 0.25
  impulse[1] = -0.125
  let dry = render(&delayed, impulse)
  for frame in 0..<400 {
    requireNear(dry[frame * 2], frame == 172 ? 0.25 : 0, "dry delay L frame \(frame)")
    requireNear(dry[frame * 2 + 1], frame == 172 ? -0.125 : 0, "dry delay R frame \(frame)")
  }

  // Independent direct-form recurrence checks the two-section cascade, not just finiteness.
  let coefficients = [
    BiquadDesign.lowPass(freq: 125, q: 0.541196100146197, sampleRate: 48_000),
    BiquadDesign.lowPass(freq: 125, q: 1.3065629648763766, sampleRate: 48_000),
  ]
  var expected = [Double](repeating: 0, count: 1200)
  expected[0] = 0.125
  for c in coefficients {
    require([c.b0, c.b1, c.b2, c.a1, c.a2].allSatisfy(\.isFinite), "finite coefficients")
    require(abs((c.b0 + c.b1 + c.b2) / (1 + c.a1 + c.a2) - 1) < 1e-10, "unity DC gain")
    var filtered = [Double](repeating: 0, count: expected.count)
    for n in expected.indices {
      filtered[n] = c.b0 * expected[n]
      if n >= 1 { filtered[n] += c.b1 * expected[n - 1] - c.a1 * filtered[n - 1] }
      if n >= 2 { filtered[n] += c.b2 * expected[n - 2] - c.a2 * filtered[n - 2] }
    }
    expected = filtered
  }
  var lfe = configured(.init(preampDb: 0))
  var lfeImpulse = [Float](repeating: 0, count: 16 * expected.count)
  lfeImpulse[3] = 0.125
  let filtered = render(&lfe, lfeImpulse)
  for n in expected.indices {
    requireNear(filtered[n * 2], expected[n] * 2.26464431, "LFE cascade impulse", tolerance: 1e-8)
    require(filtered[n * 2] == filtered[n * 2 + 1], "LFE identical on both outputs")
  }
  require(filtered[400] > 0 && abs(filtered.last!) < 0.0001, "LFE impulse tail and decay")

  for frequency in [30.0, 1000] {
    var processor = configured(.init(preampDb: 0))
    var input = [Float](repeating: 0, count: 16 * 9600)
    for frame in 0..<9600 {
      input[frame * 16 + 3] = Float(0.01 * sin(2 * .pi * frequency * Double(frame) / 48_000))
    }
    let output = render(&processor, input)
    let rms = sqrt((4800..<9600).reduce(0.0) { $0 + pow(Double(output[$1 * 2]), 2) } / 4800)
    let relative = rms / (0.01 * 2.26464431 / sqrt(2))
    require(
      frequency == 30 ? relative > 0.99 && relative < 1.01 : relative < 0.001,
      "lowpass response at \(frequency) Hz")
  }

  let config = DownmixProcessor.Configuration(preampDb: 0)
  var signal = [Float](repeating: 0, count: 16 * 1100)
  for frame in 0..<1100 {
    signal[frame * 16] = Float(frame % 13) * 0.001
    signal[frame * 16 + 1] = -Float(frame % 7) * 0.002
    signal[frame * 16 + 3] = frame % 89 == 0 ? 0.05 : 0
  }
  var whole = configured(config)
  let wholeOutput = render(&whole, signal)
  var chunked = configured(config)
  var chunkedOutput: [Float] = []
  var offset = 0
  for frames in [1, 37, 134, 3, 211, 7, 707] {
    chunkedOutput += render(&chunked, Array(signal[(offset * 16)..<((offset + frames) * 16)]))
    offset += frames
  }
  require(
    chunkedOutput == wholeOutput, "lowpass/delay independent of block boundaries across wraps")

  for split in [1, 37, 171, 172, 300, 513] {
    for change in 0..<4 {
      var processor = configured(config)
      _ = render(&processor, Array(signal[..<(split * 16)]))
      var updated = config
      if change == 1 || change == 3 { updated.preampDb = -6 }
      if change == 2 || change == 3 { updated.swapOutputs = true }
      processor.apply(configuration: updated)
      let tail = render(&processor, Array(signal[(split * 16)...]))
      let gain = pow(10, updated.preampDb / 20)
      for n in tail.indices {
        let referenceIndex = split * 2 + (updated.swapOutputs ? n ^ 1 : n)
        requireNear(
          tail[n], Double(wholeOutput[referenceIndex]) * gain, "gain/swap/no-op preserves history",
          tolerance: 1e-8)
      }
    }
  }

  for change in 0..<3 {
    var used = configured(config)
    _ = render(&used, Array(signal[..<(300 * 16)]))
    var updated = config
    if change == 0 { updated.lfeLowpass = false }
    if change == 1 { updated.channelMap.swapAt(0, 1) }
    if change == 2 { updated.inputChannelCount = 32 }
    used.apply(configuration: updated)
    var fresh = configured(updated)
    let tail = Array(signal[(300 * 16)...])
    require(render(&used, tail) == render(&fresh, tail), "topology changes reset history")
    updated.lfeLowpass = false
    used.apply(configuration: updated)
    updated.lfeLowpass = true
    used.apply(configuration: updated)
    var enabled = configured(updated)
    require(
      render(&used, [Float](repeating: 0, count: 16 * 300))
        == render(&enabled, [Float](repeating: 0, count: 16 * 300)),
      "re-enabled lowpass has no stale history")
  }
  print("PASS: lowpass response, delay, block boundaries and configuration history")
}

/// Players deliver stereo, 5.1, 7.1, 9.1 or the full 9.1.6 bed into the same 16-channel
/// device, and narrower devices exist too. Verify each content layout lands on the
/// expected bed slots and the expected stereo matrix sum.
func checkSurroundContentLayouts() {
  // Headroom keeps every layout below full scale so the sums are not clipped.
  let preampDb = -6.0
  let gain = pow(10.0, preampDb / 20)
  let configuration = DownmixProcessor.Configuration(preampDb: preampDb, lfeLowpass: false)
  func expected(_ values: [Int: Double], _ coefficients: [Double]) -> Double {
    gain * values.reduce(0) { $0 + $1.value * coefficients[$1.key] }
  }
  let left = [1.0, 0, sqrt(0.5), 2.26464431, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0]
  let right = [0.0, 1, sqrt(0.5), 2.26464431, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1]
  // Bed order: L R C LFE Ls Rs Lrs Rrs Lw Rw Ltf Rtf Ltm Rtm Ltr Rtr.
  let layouts: [(String, [Int: Double], Int)] = [
    ("stereo", [0: 0.25, 1: 0.2], 2),
    ("5.1", [0: 0.1, 1: 0.2, 2: 0.3, 3: 0.05, 4: 0.4, 5: 0.5], 6),
    ("7.1", [0: 0.1, 1: 0.2, 2: 0.3, 3: 0.05, 4: 0.4, 5: 0.5, 6: 0.15, 7: 0.25], 8),
    (
      "9.1",
      [
        0: 0.1, 1: 0.2, 2: 0.3, 3: 0.05, 4: 0.4, 5: 0.5, 6: 0.15, 7: 0.25,
        8: 0.12, 9: 0.22,
      ], 10
    ),
    (
      "9.1.6",
      [
        0: 0.1, 1: 0.2, 2: 0.3, 3: 0.05, 4: 0.4, 5: 0.5, 6: 0.15, 7: 0.25, 8: 0.12, 9: 0.22,
        10: 0.07, 11: 0.09, 12: 0.06, 13: 0.08, 14: 0.05, 15: 0.11,
      ],
      16
    ),
  ]
  for (name, content, channels) in layouts {
    var config = configuration
    config.inputChannelCount = channels
    var processor = configured(config)
    var input = [Float](repeating: 0, count: channels)
    for (slot, amplitude) in content { input[slot] = Float(amplitude) }
    let output = render(&processor, input, channels: channels)
    requireNear(output[0], expected(content, left), "\(name) content sums to left", tolerance: 1e-5)
    requireNear(
      output[1], expected(content, right), "\(name) content sums to right", tolerance: 1e-5)
    let meters = processor.takeMeterSnapshot()
    for slot in 0..<16 {
      let amplitude = content[slot] ?? 0
      let expectedDb = amplitude > 0 ? 20 * log10(amplitude) : -120
      requireNear(
        meters.inputPeaksDb[slot], expectedDb, "\(name) meter slot \(slot)", tolerance: 1e-4)
    }
  }

  // A narrower device keeps rendering: only the slots it can deliver contribute.
  var narrow = configuration
  narrow.inputChannelCount = 6
  var narrowProcessor = configured(narrow)
  var narrowInput = [Float](repeating: 0, count: 6)
  for slot in 0..<6 { narrowInput[slot] = Float(0.1) * Float(slot + 1) }
  let narrowOutput = render(&narrowProcessor, narrowInput, channels: 6)
  let narrowContent: [Int: Double] = [0: 0.1, 1: 0.2, 2: 0.3, 3: 0.4, 4: 0.5, 5: 0.6]
  requireNear(
    narrowOutput[0], expected(narrowContent, left), "six-channel device left sum", tolerance: 1e-5)
  requireNear(
    narrowOutput[1], expected(narrowContent, right), "six-channel device right sum", tolerance: 1e-5
  )
  let narrowMeters = narrowProcessor.takeMeterSnapshot()
  require(
    narrowMeters.inputPeaksDb[6...].allSatisfy { $0 == -120 },
    "Slots a narrow device cannot deliver stay silent")
  print("PASS: stereo/5.1/7.1/9.1/9.1.6 content layouts and narrow devices")
}

/// The input device follows the player's rate now, so this converter is the path that
/// keeps the fixed 48 kHz DSP correct at 44.1/96/192 kHz and wider blocks.
func checkInputRateConversion() {
  let blockSizes = [32, 64, 128, 512, 1024, 1, 37, 4096]
  for (rate, channels) in [
    (48_000.0, 16), (44_100.0, 16), (44_100.0, 2), (96_000.0, 16),
    (88_200.0, 8), (192_000.0, 16), (32_000.0, 2),
  ] {
    guard let converter = InputRateConverter(deviceRate: rate, channelCount: channels) else {
      require(rate == 48_000, "Only 48 kHz needs no converter")
      continue
    }
    require(converter.deviceRate == rate && converter.channelCount == channels, "converter config")
    let capacity = converter.outputCapacity(forInputFrames: 4096)
    var output = [Float](repeating: 0, count: capacity * channels)
    var input = [Float](repeating: 0, count: 4096 * channels)
    var produced = 0
    var consumed = 0
    var phase = 0.0
    var collected: [Float] = []
    var blockIndex = 0
    // Half a second of device-rate audio keeps the analysis window long at 192 kHz.
    while consumed < Int(rate / 2) {
      let frames = blockSizes[blockIndex % blockSizes.count]
      blockIndex += 1
      for frame in 0..<frames {
        let left = Float(0.25 * sin(2 * .pi * 997 * phase / rate))
        let right = Float(0.125 * sin(2 * .pi * 997 * phase / rate + 0.5))
        for channel in 0..<channels {
          input[frame * channels + channel] = channel == 0 ? left : (channel == 1 ? right : 0)
        }
        phase += 1
      }
      let count = input.withUnsafeBufferPointer { inBuffer in
        output.withUnsafeMutableBufferPointer { outBuffer in
          converter.process(
            input: inBuffer.baseAddress!, frameCount: frames,
            output: outBuffer.baseAddress!, capacity: capacity)
        }
      }
      require(count >= 0 && count <= capacity, "converter stays inside its capacity")
      if blockIndex > 2 { collected.append(contentsOf: output.prefix(count * channels)) }
      produced += count
      consumed += frames
    }
    let expected = Double(consumed) * 48_000 / rate
    require(
      abs(Double(produced) / expected - 1) < 0.006,
      "\(rate) Hz frame accounting: \(produced) vs \(expected)")
    let frames = collected.count / channels
    let analysisStart = 1_000
    let analysisEnd = frames - 1_000
    require(analysisEnd - analysisStart > 9_600, "\(rate) Hz has a settled analysis window")
    var sum = 0.0
    var rightSum = 0.0
    var crossings = 0
    var previous: Float = 0
    for frame in analysisStart..<analysisEnd {
      let sample = collected[frame * channels]
      sum += Double(sample * sample)
      if channels > 1 {
        rightSum += Double(collected[frame * channels + 1] * collected[frame * channels + 1])
      }
      if previous <= 0 && sample > 0 { crossings += 1 }
      previous = sample
    }
    let windowFrames = Double(analysisEnd - analysisStart)
    let rms = sqrt(sum / windowFrames)
    let hz = Double(crossings) / (windowFrames / 48_000)
    require(abs(rms - 0.25 / sqrt(2)) < 0.004, "\(rate) Hz sine gain preserved: \(rms)")
    require(abs(hz - 997) < 2, "\(rate) Hz sine frequency preserved: \(hz)")
    if channels > 1 {
      require(
        abs(sqrt(rightSum / windowFrames) - 0.125 / sqrt(2)) < 0.004,
        "\(rate) Hz channel 1 keeps its own gain")
    }
  }
  require(
    InputRateConverter(deviceRate: 1_000, channelCount: 16) == nil, "Unsupported rate refused")
  require(InputRateConverter(deviceRate: 48_000, channelCount: 0) == nil, "Zero channels refused")
  print("PASS: 44.1/96/192/88.2/32 kHz input conversion with varied block sizes")
}

func writeRing(_ ring: FloatRingBuffer, _ samples: [Float], count: Int? = nil) -> Int {
  samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: count ?? samples.count) }
}

func readRing(_ ring: FloatRingBuffer, count: Int, storageCount: Int? = nil) -> (Int, [Float]) {
  var samples = [Float](repeating: -999, count: storageCount ?? max(1, count))
  let read = samples.withUnsafeMutableBufferPointer {
    ring.read(into: $0.baseAddress!, count: count)
  }
  return (read, samples)
}

func checkConcurrentRing() {
  final class Result: Sendable {
    let failed = Atomic<Bool>(false)
    let consumed = Atomic<Int>(0)
  }
  for capacity in [6, 9600] {
    let ring = FloatRingBuffer(capacity: capacity)
    let result = Result()
    let group = DispatchGroup()
    let totalFrames = 100_000
    let deadline = Date().addingTimeInterval(10)
    group.enter()
    DispatchQueue.global().async {
      defer { group.leave() }
      var sent = 0
      var buffer = [Float](repeating: 0, count: 128)
      while sent < totalFrames && Date() < deadline {
        let frames = min(64, totalFrames - sent)
        for frame in 0..<frames {
          buffer[frame * 2] = Float(sent + frame + 1)
          buffer[frame * 2 + 1] = -Float(sent + frame + 1)
        }
        let written = buffer.withUnsafeBufferPointer {
          ring.write($0.baseAddress!, count: frames * 2)
        }
        sent += written / 2
        if written == 0 { Thread.sleep(forTimeInterval: 0.000001) }
      }
      if sent != totalFrames { result.failed.store(true, ordering: .relaxed) }
    }
    group.enter()
    DispatchQueue.global().async {
      defer { group.leave() }
      var received = 0
      var buffer = [Float](repeating: 0, count: 94)
      while received < totalFrames && Date() < deadline {
        let count = buffer.withUnsafeMutableBufferPointer {
          ring.read(into: $0.baseAddress!, count: $0.count)
        }
        if count % 2 != 0 { result.failed.store(true, ordering: .relaxed) }
        for frame in 0..<(count / 2) {
          let expected = Float(received + frame + 1)
          if buffer[frame * 2] != expected || buffer[frame * 2 + 1] != -expected {
            result.failed.store(true, ordering: .relaxed)
          }
        }
        received += count / 2
        if count == 0 { Thread.sleep(forTimeInterval: 0.000001) }
      }
      result.consumed.store(received, ordering: .relaxed)
    }
    require(group.wait(timeout: .now() + 12) == .success, "SPSC stress workers complete")
    require(
      !result.failed.load(ordering: .relaxed)
        && result.consumed.load(ordering: .relaxed) == totalFrames,
      "concurrent SPSC stereo ordering")
    require(
      ring.availableToRead == 0 && ring.availableToWrite == capacity,
      "concurrent SPSC drained accounting")
  }
  print("PASS: concurrent SPSC ordering (200000 stereo frames)")
}

func checkRing() {
  let ring = FloatRingBuffer(capacity: 9600)
  require(
    ring.availableToRead == 0 && ring.availableToWrite == 9600,
    "engine capacity exactly 9600 samples")
  let frames = (1...5000).flatMap { [Float($0), -Float($0)] }
  require(
    readRing(ring, count: 4).1 == [-999, -999, -999, -999],
    "empty read leaves destination untouched")
  for count in [Int.min, -1, 0, 1] {
    require(writeRing(ring, frames, count: count) == 0, "nonpositive/subframe write")
    let result = readRing(ring, count: count, storageCount: 2)
    require(result.0 == 0 && result.1 == [-999, -999], "nonpositive/subframe read")
    require(
      ring.availableToWrite == 9600 && ring.availableToRead == 0,
      "invalid counts do not move indices")
  }
  require(writeRing(ring, frames) == 9600, "overflow accepts full stereo frames only")
  require(ring.availableToWrite == 0 && ring.availableToRead == 9600, "full ring accounting")
  require(writeRing(ring, [77, -77]) == 0, "full ring rejects write without overwriting")
  let prefix = readRing(ring, count: 301)
  require(
    prefix.0 == 300 && Array(prefix.1.prefix(300)) == Array(frames.prefix(300))
      && prefix.1[300] == -999, "odd read rounds down")
  require(writeRing(ring, Array(frames[9600...])) == 300, "partial overflow after read")
  let wrapped = readRing(ring, count: 9700)
  let expected = Array(frames[300..<9600]) + Array(frames[9600..<9900])
  require(
    wrapped.0 == 9600 && Array(wrapped.1.prefix(9600)) == expected, "wrap retains stereo order")
  require(
    wrapped.1.suffix(100).allSatisfy { $0 == -999 }, "partial read leaves unwritten tail untouched")
  require(ring.availableToRead == 0 && ring.availableToWrite == 9600, "drained ring accounting")
  require(writeRing(ring, [1, -1, 2, -2, 3]) == 4, "odd write drops trailing half-frame")
  ring.clear()
  require(ring.availableToRead == 0 && ring.availableToWrite == 9600, "clear resets indices")
  require(
    writeRing(ring, [9, -9]) == 2 && readRing(ring, count: 4).1 == [9, -9, -999, -999],
    "reuse after clear has no stale data")

  for capacity in [Int.min, -1, 0, 1, 2, 3, 7, 63, 64, 65] {
    let small = FloatRingBuffer(capacity: capacity)
    let usable = max(capacity, 2) / 2 * 2
    require(small.availableToWrite == usable, "small/odd capacity rounded to complete frames")
    require(writeRing(small, frames) == usable, "small ring fills")
    require(readRing(small, count: usable + 2).0 == usable, "small ring drains")
  }

  // Deterministic FIFO model exercises many physical wraps and full/partial transfers.
  for capacity in [6, 64, 9600] {
    let modeled = FloatRingBuffer(capacity: capacity)
    var queue: [Float] = []
    var seed: UInt64 = 0x1234
    var nextFrame = 1
    for step in 0..<2000 {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1
      let count = Int((seed >> 32) % 701)
      if step % 3 != 0 {
        let samples = (nextFrame..<(nextFrame + count / 2 + 1)).flatMap { [Float($0), -Float($0)] }
        let expectedCount = min(count / 2 * 2, capacity - queue.count)
        require(writeRing(modeled, samples, count: count) == expectedCount, "modeled write count")
        queue += samples.prefix(expectedCount)
        nextFrame += count / 2 + 1
      } else {
        let result = readRing(modeled, count: count)
        let expectedCount = min(count / 2 * 2, queue.count)
        require(
          result.0 == expectedCount
            && Array(result.1.prefix(expectedCount)) == Array(queue.prefix(expectedCount)),
          "modeled FIFO/read count")
        require(
          result.1.dropFirst(expectedCount).allSatisfy { $0 == -999 }, "modeled partial destination"
        )
        queue.removeFirst(expectedCount)
      }
      require(
        modeled.availableToRead == queue.count
          && modeled.availableToWrite == capacity - queue.count, "modeled accounting")
    }
  }
  print("PASS: ring capacity, stereo overflow, wrap, full/partial transfers and invalid counts")
}

checkMatrixAndMapping()
checkSurroundContentLayouts()
checkInputRateConversion()
checkGainClippingAndSanitization()
checkLowpassAndHistory()
checkRing()
checkConcurrentRing()
print("DSP/ring checks passed (\(assertions.load(ordering: .relaxed)) assertions)")
