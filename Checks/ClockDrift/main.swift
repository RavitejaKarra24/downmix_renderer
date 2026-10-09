import Dispatch
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

final class Fixture {
  let ring: FloatRingBuffer
  let resampler: AdaptiveStereoResampler
  let output: UnsafeMutablePointer<Float>
  let input: UnsafeMutablePointer<Float>
  let maximum: Int
  let capacity: Int
  var written = 0

  init(target: Int = 2048, maximum: Int = 1024, capacity: Int = 16_384) {
    self.maximum = maximum
    self.capacity = capacity
    ring = FloatRingBuffer(capacity: capacity * 2)
    resampler = AdaptiveStereoResampler(
      ring: ring, targetFrames: target, maximumOutputFrames: maximum)
    output = .allocate(capacity: maximum * 2 + 2)
    output.initialize(repeating: 0, count: maximum * 2 + 2)
    input = .allocate(capacity: capacity * 2)
    input.initialize(repeating: 0, count: capacity * 2)
  }

  deinit {
    output.deinitialize(count: maximum * 2 + 2)
    output.deallocate()
    input.deinitialize(count: capacity * 2)
    input.deallocate()
  }

  func feed(_ frames: Int, signal: (Int) -> (Float, Float)) {
    require(frames >= 0 && frames <= capacity, "bounded test producer")
    for frame in 0..<frames {
      let pair = signal(written + frame)
      input[2 * frame] = pair.0
      input[2 * frame + 1] = pair.1
    }
    require(ring.write(input, count: frames * 2) == frames * 2, "no producer overflow")
    written += frames
  }

  // Mimic the integration contract: the core owns ONLY its returned prefix.
  func render(_ frames: Int) -> Int {
    for sample in 0..<(maximum * 2 + 2) { output[sample] = 77 }
    let produced = resampler.render(into: output.advanced(by: 1), frameCount: frames)
    require(produced >= 0 && produced <= frames, "bounded produced count")
    require(output[0] == 77 && output[maximum * 2 + 1] == 77, "output canaries")
    for sample in (produced * 2)..<(frames * 2) {
      require(output[sample + 1] == 77, "core leaves silence suffix to caller")
      output[sample + 1] = 0
    }
    for sample in 0..<(frames * 2) {
      require(output[sample + 1].isFinite, "finite output")
    }
    return produced
  }
}

func silenceAndRecovery() {
  let f = Fixture(target: 128, maximum: 128)
  let initialFill = f.resampler.bufferedFrames
  require(f.render(0) == 0, "empty request")
  require(f.resampler.render(into: f.output, frameCount: -1) == 0, "negative request")
  require(f.resampler.render(into: f.output, frameCount: Int.max) == 0, "oversized request")
  require(f.resampler.bufferedFrames == initialFill, "invalid requests do not consume")
  require(f.render(128) == 0 && f.resampler.isPriming, "initial silence")
  require(f.resampler.rebufferCount == 0, "startup is not an underrun")
  f.feed(255) { _ in (0.5, -0.5) }
  require(f.render(128) == 0 && f.resampler.bufferedFrames == 255, "priming threshold")
  f.feed(1) { _ in (0.5, -0.5) }
  require(f.render(128) == 128 && !f.resampler.isPriming, "start at target plus callback")
  require(f.resampler.bufferedFrames == 128, "FIR lookahead is counted, history is not")
  for frame in 32..<128 {
    require(abs(f.output[1 + frame * 2] - 0.5) < 0.000002, "unity constant gain")
    require(f.output[2 + frame * 2] == -f.output[1 + frame * 2], "shared stereo phase")
  }
  let prefix = f.render(128)
  require(prefix > 0 && prefix < 128, "starvation returns only initialized prefix")
  require(f.resampler.isPriming && f.resampler.rebufferCount == 1, "starvation reprimes once")
  require(f.resampler.bufferedFrames == 0, "starved local lookahead is retired")
  require(f.resampler.correctionPPM == 0, "recovery resets controller")
  require(f.render(128) == 0 && f.resampler.rebufferCount == 1, "waiting is not another gap")
  f.feed(256) { _ in (0, 0) }
  require(f.render(128) == 128, "recovery begins on fresh source")
  require((1...256).allSatisfy { f.output[$0] == 0 }, "no stale FIR tail on recovery")
  let fill = f.resampler.bufferedFrames
  let ppm = f.resampler.correctionPPM
  require(f.resampler.render(into: f.output, frameCount: 129) == 0, "configured bound enforced")
  require(f.resampler.bufferedFrames == fill && f.resampler.correctionPPM == ppm, "reject is inert")
  let tiny = Fixture(target: 1, maximum: 1, capacity: 64)
  tiny.feed(25) { _ in (0.25, -0.25) }
  require(tiny.render(1) == 0, "minimum reservoir includes FIR lookahead")
  tiny.feed(1) { _ in (0.25, -0.25) }
  for frame in 0..<100 {
    require(tiny.render(1) == 1, "one-frame maximum is safe")
    if frame > 24 {
      require(abs(tiny.output[1] - 0.25) < 0.000002, "tiny callback constant gain")
    }
    tiny.feed(1) { _ in (0.25, -0.25) }
  }
  print("Priming/starvation/recovery, bounds, gain, polarity and suffix/canary checks passed")
}

// Reference position integrates the ACTUAL previous callback rate, not output-clock
// time. Thus tone phase and source consumption detect an inverted correction sign.
func renderedClock(_ ppm: Double) {
  let f = Fixture()
  let target = 2048
  let blocks = [32, 128, 512, 1024, 128, 32, 512]
  let omega = 2 * Double.pi * 1000 / 48_000
  func signal(_ frame: Int) -> (Float, Float) {
    let value = Float(sin(Double(frame) * omega))
    return (value, -value)
  }
  f.feed(target + 64, signal: signal)
  var elapsed = 0
  var sourceClock = 0.0
  var arrived = 0
  var position = 0.0
  var minimumFill = Int.max
  var maximumFill = 0
  var count = 0
  while elapsed < 20 * 48_000 {
    let frames = blocks[count % blocks.count]
    sourceClock += Double(frames) * (1 + ppm / 1_000_000)
    // Independent 64-frame producer packets with deterministic scheduling jitter.
    let delay = Double((count * 17) % 33)
    let arrival = max(arrived, Int(max(0, sourceClock - delay)) / 64 * 64)
    f.feed(arrival - arrived, signal: signal)
    arrived = arrival
    let rate = 1 + f.resampler.correctionPPM / 1_000_000
    require(f.render(frames) == frames, "rendered \(ppm) ppm has no underrun")
    for frame in 0..<frames {
      if position > 32 {
        require(
          abs(Double(f.output[1 + frame * 2]) - sin(position * omega)) < 0.001,
          "continuous 1 kHz source phase across callback boundaries")
      }
      require(f.output[1 + frame * 2] == -f.output[2 + frame * 2], "stereo polarity")
      position += rate
    }
    // Includes all ring + local data, excludes FIR history; floor accounts for
    // sub-frame phase. Not merely checking the controller's reported command.
    require(
      abs(Double(f.written - f.resampler.bufferedFrames) - floor(position)) <= 1,
      "source consumption agrees with produced frames and rate")
    minimumFill = min(minimumFill, f.resampler.bufferedFrames)
    maximumFill = max(maximumFill, f.resampler.bufferedFrames)
    elapsed += frames
    count += 1
  }
  require(f.resampler.rebufferCount == 0, "no steady rendered starvation")
  require(minimumFill > 1000 && maximumFill < 4000, "bounded rendered reservoir")
  // The intentional initial excess drains; after 20 s the clock estimate must
  // distinguish +/-100 ppm even with packet jitter and variable callbacks.
  require(ppm * f.resampler.correctionPPM > 0, "correction direction for \(ppm) ppm")
  require(
    ppm * (position - Double(elapsed)) > 0,
    "integrated source/output timing correction direction for \(ppm) ppm")
  print(
    "Rendered \(Int(ppm)) ppm, 20 virtual s: queue \(minimumFill)...\(maximumFill), rate \(String(format: "%.1f", f.resampler.correctionPPM)) ppm"
  )
}

func toneQuality(_ frequency: Double) {
  let f = Fixture()
  let omega = 2 * Double.pi * frequency / 48_000
  func signal(_ frame: Int) -> (Float, Float) {
    (Float(sin(Double(frame) * omega)), Float(cos(Double(frame) * omega)))
  }
  f.feed(2048 + 1024, signal: signal)
  var position = 0.0
  var sineGain = 0.0
  var cosineGain = 0.0
  var energy = 0.0
  var maxError = 0.0
  for block in 0..<250 {
    let frames = [32, 128, 512, 1024][block % 4]
    f.feed(frames, signal: signal)
    let rate = 1 + f.resampler.correctionPPM / 1_000_000
    require(f.render(frames) == frames, "tone render")
    for frame in 0..<frames {
      let angle = position * omega
      if position > 48 {
        let s = sin(angle)
        let c = cos(angle)
        let left = Double(f.output[frame * 2 + 1])
        let right = Double(f.output[frame * 2 + 2])
        // Complex stereo tone avoids finite-window sine/cosine fit bias.
        sineGain += left * s + right * c
        cosineGain += left * c - right * s
        energy += 1
        maxError = max(maxError, abs(left - s), abs(right - c))
      }
      position += rate
    }
  }
  let gain = hypot(sineGain, cosineGain) / energy
  let decibels = 20 * log10(gain)
  let phase = atan2(cosineGain, sineGain)
  require(abs(decibels) < 0.05, "\(frequency) Hz passband gain within 0.05 dB")
  require(abs(phase) < 0.002, "\(frequency) Hz phase within 0.002 radians")
  require(maxError < 0.006, "\(frequency) Hz pointwise continuity within 0.006 FS")
  print(
    "Tone \(Int(frequency)) Hz: \(String(format: "%.5f", decibels)) dB, phase \(String(format: "%.6f", phase)) rad, peak error \(String(format: "%.6f", maxError))"
  )
}

func impulseQuality() {
  let f = Fixture()
  let leftImpulses = [31, 127, 511, 1023, 4095]
  let rightImpulses = [38, 134, 518, 1030, 4102]
  func signal(_ frame: Int) -> (Float, Float) {
    (leftImpulses.contains(frame) ? 1 : 0, rightImpulses.contains(frame) ? -0.7 : 0)
  }
  f.feed(2048 + 1024, signal: signal)
  var position = 0.0
  var maxError = 0.0
  for block in 0..<40 {
    let frames = [32, 128, 512, 1024][block % 4]
    f.feed(frames, signal: signal)
    let rate = 1 + f.resampler.correctionPPM / 1_000_000
    require(f.render(frames) == frames, "impulse render")
    for frame in 0..<frames {
      // Independent double-precision analytic FIR, not the phase table.
      let center = Int(position)
      var sum = 0.0
      var left = 0.0
      var right = 0.0
      for tap in -23...24 {
        let x = Double(center + tap) - position
        let angle = Double.pi * x / 24
        let window = 0.42 + 0.5 * cos(angle) + 0.08 * cos(2 * angle)
        let sincAngle = Double.pi * 0.96 * x
        let weight = 0.96 * window * (abs(sincAngle) < 1e-12 ? 1 : sin(sincAngle) / sincAngle)
        sum += weight
        if leftImpulses.contains(center + tap) { left += weight }
        if rightImpulses.contains(center + tap) { right -= 0.7 * weight }
      }
      maxError = max(
        maxError, abs(Double(f.output[frame * 2 + 1]) - left / sum),
        abs(Double(f.output[frame * 2 + 2]) - right / sum))
      if position > 4200 {
        require(
          f.output[frame * 2 + 1] == 0 && f.output[frame * 2 + 2] == 0, "no stale impulse tails")
      }
      position += rate
    }
  }
  require(maxError < 0.000003, "polyphase impulse matches analytic FIR within 3e-6 FS")
  print("Impulse / independent stereo / callback-boundary FIR error: \(maxError)")
}

// Long tests execute the production controller directly. Queue/source clocks are
// continuous-double conservation equations with integer packet arrivals. This is
// a controller surrogate, NOT hours of FIR/hardware playback. Short tests above
// separately verify the renderer follows that same controller and source clock.
func longClock(_ initialPPM: Double, changing: Bool = false, fixedBlock: Int? = nil) {
  var controller = AdaptiveClockDriftController()
  let blocks = [32, 128, 512, 1024]
  let target = 2048.0
  var fill = target
  var sourceClock = 0.0
  var arrived = 0.0
  var consumed = 0.0
  var elapsed = 0
  var step = 0
  var minimumFill = fill
  var maximumFill = fill
  var steadyError = 0.0
  var settledRateErrors = [Double](repeating: 0, count: 4)
  var settledFrameCounts = [Int](repeating: 0, count: 4)
  let duration = 7200 * 48_000
  while elapsed < duration {
    let frames = fixedBlock ?? blocks[step % blocks.count]
    let seconds = Double(elapsed) / 48_000
    let ppm: Double
    if changing {
      // Plateaus long enough to settle, repeated sign and magnitude reversals.
      ppm = [1000.0, -1000.0, 500.0, -100.0][Int(seconds / 600) % 4]
    } else {
      ppm = initialPPM
    }
    sourceClock += Double(frames) * (1 + ppm / 1_000_000)
    let delay = Double((step * 17) % 33)
    let nextArrival = max(arrived, floor(max(0, sourceClock - delay) / 64) * 64)
    let previous = controller.correctionPPM
    let retired = Double(frames) * (1 + previous / 1_000_000)
    consumed += retired
    fill += nextArrival - arrived - retired
    arrived = nextArrival
    controller.step(errorFrames: fill - target, frameCount: frames)
    require(fill > 512 && fill < 4096, "long virtual queue has no underrun/overflow")
    require(abs(controller.correctionPPM) <= 2000, "rate clamp")
    require(
      abs(controller.correctionPPM - previous) <= 100 * Double(frames) / 48_000 + 1e-9,
      "time-scaled rate slew")
    require(abs(fill - (target + arrived - consumed)) < 0.1, "long-clock conservation")
    let settled = changing ? seconds.truncatingRemainder(dividingBy: 600) > 180 : seconds > 180
    if settled {
      let plateau = changing ? Int(seconds / 600) % 4 : 0
      settledRateErrors[plateau] += (controller.correctionPPM - ppm) * Double(frames)
      settledFrameCounts[plateau] += frames
      steadyError = max(steadyError, abs(controller.correctionPPM - ppm))
      require(abs(fill - target) < 128, "settled packet-jitter reservoir within 128 frames")
      require(
        abs(controller.correctionPPM - ppm) < 60, "settled instantaneous correction within 60 ppm")
    }
    minimumFill = min(minimumFill, fill)
    maximumFill = max(maximumFill, fill)
    elapsed += frames
    step += 1
  }
  var meanError = 0.0
  for plateau in 0..<4 where settledFrameCounts[plateau] > 0 {
    meanError = max(
      meanError, abs(settledRateErrors[plateau] / Double(settledFrameCounts[plateau])))
  }
  require(meanError < 1, "settled time-weighted mean rate within 1 ppm")
  print(
    "Controller-only 2 virtual h, \(changing ? "changing clocks" : "\(Int(initialPPM)) ppm") blocks \(fixedBlock.map(String.init) ?? "32/128/512/1024+jitter"): queue \(Int(minimumFill))...\(Int(maximumFill)), settled peak/mean error <= \(String(format: "%.2f", steadyError))/\(String(format: "%.3f", meanError)) ppm (after 180 s)"
  )
}

// Use the production minimum, not an enlarged reservoir that hides startup or
// reversal starvation. These are actual FIR renders, not the controller surrogate.
func renderedMinimumReservoirClocks() {
  for initialPPM in [-2000.0, 2000.0, 1000.0] {
    let target = AdaptiveStereoResampler.minimumRecommendedTargetFrames
    let f = Fixture(target: target, maximum: 128)
    func signal(_ frame: Int) -> (Float, Float) { (0.125, -0.125) }
    f.feed(target + 128, signal: signal)
    require(f.render(128) == 128, "minimum reservoir startup")
    var sourceClock = 0.0
    var arrived = 0
    var minimumFill = Int.max
    var maximumFill = 0
    for step in 0..<(240 * 48_000 / 128) {
      let seconds = Double(step * 128) / 48_000
      let ppm = initialPPM == 1000 && seconds >= 180 ? -1000.0 : initialPPM
      sourceClock += 128 * (1 + ppm / 1_000_000)
      let delay = Double((step * 17) % 33)
      let nextArrival = max(arrived, Int(floor(max(0, sourceClock - delay) / 64)) * 64)
      f.feed(nextArrival - arrived, signal: signal)
      arrived = nextArrival
      require(
        f.render(128) == 128,
        "production minimum reservoir starved at \(initialPPM) ppm, \(seconds) s")
      require(f.resampler.rebufferCount == 0, "minimum-target clocks have no gaps")
      require(f.output[127] == -f.output[128], "minimum-target stereo alignment")
      minimumFill = min(minimumFill, f.resampler.bufferedFrames)
      maximumFill = max(maximumFill, f.resampler.bufferedFrames)
      require(f.resampler.bufferedFrames < f.capacity, "minimum-target queue stays bounded")
    }
    print(
      "Actual FIR 240 virtual s at production target \(target), \(initialPPM == 1000 ? "+1000→−1000" : String(Int(initialPPM))) ppm: no gaps, queue \(minimumFill)...\(maximumFill)"
    )
  }
}

func renderedRateLimits() {
  for direction in [1.0, -1.0] {
    let target = direction > 0 ? 1024 : 8192
    let f = Fixture(target: target)
    func signal(_ frame: Int) -> (Float, Float) { (0.25, -0.25) }
    // Hold fill well away from the target to force the production renderer to
    // each rate limit. Negative case primes normally, then drains a safe margin.
    f.feed(direction > 0 ? 10_240 : target + 1024, signal: signal)
    require(f.render(1024) == 1024, "rate-limit startup")
    if direction < 0 {
      for _ in 0..<5 { require(f.render(1024) == 1024, "safe reservoir drain") }
    }
    var clock = 0.0
    var arrived = 0
    for _ in 0..<1200 {
      clock += 1024 * (1 + direction * 0.002)
      let nextArrival = Int(clock)
      f.feed(nextArrival - arrived, signal: signal)
      arrived = nextArrival
      let previous = f.resampler.correctionPPM
      require(f.render(1024) == 1024, "max-sized callback at limiting ratio")
      require(abs(f.resampler.correctionPPM) <= 2000, "renderer rate clamp")
      require(
        abs(f.resampler.correctionPPM - previous) <= 100 * 1024 / 48_000 + 1e-9,
        "renderer time-scaled slew")
      require(abs(f.output[1023] - 0.25) < 0.000002, "rate-limit unity gain")
      require(f.output[1023] == -f.output[1024], "rate-limit stereo phase")
    }
    require(f.resampler.correctionPPM == direction * 2000, "renderer attains both limits")
    require(f.resampler.rebufferCount == 0, "no starvation at ratio limits")
    var sawGap = false
    for _ in 0..<32 {
      let learned = f.resampler.correctionPPM
      if f.render(1024) < 1024 {
        require(f.resampler.correctionPPM == learned, "signal gap preserves learned clock bias")
        sawGap = true
        break
      }
    }
    require(sawGap && f.resampler.isPriming, "deliberate post-test starvation")
    f.feed(target + 1024) { _ in (0, 0) }
    require(f.render(1024) == 1024, "learned-rate recovery primes normally")
    require(
      (1...2048).allSatisfy { f.output[$0] == 0 },
      "learned-rate recovery has no stale signal history")
  }
  print("Maximum 1024-frame callbacks at both 0.998/1.002 ratio limits passed")
}

func limitsAndAntiWindup() {
  var controller = AdaptiveClockDriftController()
  controller.step(errorFrames: 1e9, frameCount: 0)
  require(controller.correctionPPM == 0, "zero controller step is inert")
  for _ in 0..<4000 { controller.step(errorFrames: 10_000, frameCount: 1024) }
  require(controller.correctionPPM == 2000, "positive limit attained")
  for _ in 0..<4000 { controller.step(errorFrames: -10_000, frameCount: 1024) }
  require(controller.correctionPPM == -2000, "negative limit attained")
  // Zero queue error deliberately preserves the learned integral (clock bias).
  // It must nevertheless leave saturation promptly, not retain a wound-up limit.
  for _ in 0..<4000 { controller.step(errorFrames: 0, frameCount: 1024) }
  require(
    abs(controller.correctionPPM) < 200,
    "no integral windup at rate/slew limits (residual \(controller.correctionPPM) ppm)")
  controller.reset()
  require(controller.correctionPPM == 0, "controller reset")
}

// Only the ring crosses the concurrency boundary. Resampler itself deliberately
// is not Sendable. Opposite-polarity producer channels detect stereo tearing while
// exercising the real acquire/release transport under optional TSAN.
func concurrentRing() {
  let f = Fixture(target: 512)
  f.feed(2048) { _ in (0, 0) }
  let ring = f.ring
  let group = DispatchGroup()
  group.enter()
  DispatchQueue.global().async {
    let block = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    block.initialize(repeating: 0, count: 256)
    for frame in 0..<128 {
      block[2 * frame] = Float(frame) / 256
      block[2 * frame + 1] = -block[2 * frame]
    }
    defer {
      block.deinitialize(count: 256)
      block.deallocate()
      group.leave()
    }
    for _ in 0..<20_000 { _ = ring.write(block, count: 256) }
  }
  for _ in 0..<4000 {
    _ = f.render(128)
    for frame in 0..<128 {
      require(f.output[2 * frame + 1] == -f.output[2 * frame + 2], "concurrent stereo alignment")
      require(abs(f.output[2 * frame + 1]) < 1, "concurrent signal bounded")
    }
  }
  group.wait()
}

silenceAndRecovery()
limitsAndAntiWindup()
renderedRateLimits()
renderedMinimumReservoirClocks()
for ppm in [100.0, -100.0, 500.0, -500.0, 1000.0, -1000.0] {
  renderedClock(ppm)
  longClock(ppm)
}
longClock(0, changing: true)
for block in [32, 128, 512, 1024] { longClock(500, fixedBlock: block) }
for frequency in [1000.0, 10_000.0, 20_000.0] { toneQuality(frequency) }
impulseQuality()
concurrentRing()
print(
  "Clock drift checks passed. FIR lookahead 24 frames / 0.5 ms at 48 kHz; reservoir includes lookahead."
)
print(
  "Acceptance: +/-2000 ppm, <=100 ppm/s; settled peak/mean <=60/1 ppm after 180 s, queue +/-128 frames with specified jitter;"
)
print(
  "tones <=0.05 dB / 0.002 rad / 0.006 FS error; analytic impulse <=3e-6 FS. No hardware-hours claim."
)
