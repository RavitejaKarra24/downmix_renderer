import Foundation
import Synchronization

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

struct Payload: BitwiseCopyable, Sendable, Equatable {
  let sequence: Int
  let lanes: SIMD64<UInt64>
  let footer: UInt64

  init(_ sequence: Int) {
    self.sequence = sequence
    var lanes = SIMD64<UInt64>(repeating: 0)
    for lane in 0..<64 {
      lanes[lane] = UInt64(sequence) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(lane)
    }
    self.lanes = lanes
    footer = ~UInt64(sequence)
  }

  var isCoherent: Bool { self == Payload(sequence) }
}

func checkDeterministicMailbox() {
  let mailbox = RealtimeMailbox(Payload(0))
  require(mailbox.consumeLatest() == nil, "initial value is not a publication")
  for sequence in 1...10_000 { mailbox.publish(Payload(sequence)) }
  require(mailbox.consumeLatest() == Payload(10_000), "producer overwrite returns newest only")
  for _ in 0..<100 { require(mailbox.consumeLatest() == nil, "repeated consume is nil") }

  // A deterministic latest-value model exercises all three ownership rotations,
  // including bursts that repeatedly overwrite an unconsumed middle slot.
  var seed: UInt64 = 0xDEAD_BEEF
  var pending: Payload?
  var sequence = 10_000
  for _ in 0..<50_000 {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1
    if seed >> 61 < 5 {
      sequence += 1
      pending = Payload(sequence)
      mailbox.publish(pending!)
    } else {
      require(mailbox.consumeLatest() == pending, "latest-value model has no stale updates")
      pending = nil
    }
  }
  require(mailbox.consumeLatest() == pending, "model final pending value")
  require(mailbox.consumeLatest() == nil, "model drained")
  mailbox.publish(Payload(sequence + 1))
  require(mailbox.consumeLatest() == Payload(sequence + 1), "reuse after drain")
  print("PASS: deterministic triple-buffer ownership/latest-value model")
}

func checkConcurrentMailbox() {
  final class Result: Sendable {
    let consumerReady = Atomic<Bool>(false)
    let failed = Atomic<Bool>(false)
    let last = Atomic<Int>(0)
    let observations = Atomic<Int>(0)
  }

  // Exercise balanced scheduling and both asymmetric producer/consumer speeds.
  for schedule in 0..<3 {
    let mailbox = RealtimeMailbox(Payload(0))
    let result = Result()
    let group = DispatchGroup()
    let total = 80_000
    let deadline = Date().addingTimeInterval(30)
    mailbox.publish(Payload(1))
    group.enter()
    DispatchQueue.global().async {
      defer { group.leave() }
      while !result.consumerReady.load(ordering: .acquiring) && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.00001)
      }
      for sequence in 2...total {
        mailbox.publish(Payload(sequence))
        if schedule == 1 && sequence % 256 == 0 {
          Thread.sleep(forTimeInterval: 0.00001)
        }
      }
    }
    group.enter()
    DispatchQueue.global().async {
      defer { group.leave() }
      var last = 0
      var observations = 0
      while last < total && Date() < deadline {
        if let value = mailbox.consumeLatest() {
          if !value.isCoherent || value.sequence <= last || value.sequence > total {
            result.failed.store(true, ordering: .relaxed)
          }
          last = value.sequence
          observations += 1
          result.consumerReady.store(true, ordering: .releasing)
          if schedule == 2 && observations % 32 == 0 {
            Thread.sleep(forTimeInterval: 0.00001)
          }
        }
      }
      if mailbox.consumeLatest() != nil { result.failed.store(true, ordering: .relaxed) }
      result.last.store(last, ordering: .relaxed)
      result.observations.store(observations, ordering: .relaxed)
    }
    require(group.wait(timeout: .now() + 35) == .success, "SPSC workers finish")
    require(!result.failed.load(ordering: .relaxed), "concurrent payloads coherent and increasing")
    require(result.last.load(ordering: .relaxed) == total, "final latest publication always seen")
    require(result.observations.load(ordering: .relaxed) >= 2, "workers actually exchange values")
    // Role transfer is safe now that both original owners are quiescent.
    require(mailbox.consumeLatest() == nil, "concurrent mailbox drained with no stale updates")
    mailbox.publish(Payload(total + 1))
    require(mailbox.consumeLatest() == Payload(total + 1), "quiescent role transfer/reuse")
    print(
      "PASS: concurrent schedule \(schedule), \(total) publications, "
        + "\(result.observations.load(ordering: .relaxed)) coherent observations")
  }
}

func render(_ processor: inout DownmixProcessor, _ input: [Float], channels: Int = 16) -> [Float] {
  var output = [Float](repeating: .nan, count: input.count / channels * 2)
  input.withUnsafeBufferPointer { source in
    output.withUnsafeMutableBufferPointer { destination in
      processor.process(
        input: source.baseAddress!, inputChannelCount: channels,
        output: destination.baseAddress!, frameCount: input.count / channels)
    }
  }
  return output
}

func checkConfigurationAndBadMaps() {
  for db in [-100, -30, -9.5, 0, 6, 100, Double.nan, .infinity, -.infinity] {
    let ui = DownmixProcessor.Configuration(
      channelMap: [1, 2, 0, -1, Int.min, Int.max, Int(Int32.max) + 1, Int(Int32.max)],
      preampDb: db, lfeLowpass: false, swapOutputs: true, inputChannelCount: 2)
    let pod = DownmixProcessor.RealtimeConfiguration(ui)
    require(pod.preampDb == (db.isFinite ? min(6, max(-30, db)) : -9.5), "finite bounded gain")
    require(pod.channelMap[0] == 1 && pod.channelMap[1] == 2, "valid map preserved")
    for slot in 2..<7 { require(pod.channelMap[slot] == 0, "invalid map normalized to silence") }
    require(pod.channelMap[7] == Int32.max, "representable channel preserved; runtime bounds check")
    for slot in 8..<16 { require(pod.channelMap[slot] == 0, "short map padded with silence") }
    require(!pod.lfeLowpass && pod.swapOutputs && pod.inputChannelCount == 2, "topology preserved")
    let mailbox = RealtimeMailbox(pod)
    mailbox.publish(pod)
    require(mailbox.consumeLatest() == pod, "configuration is a mailbox-compatible POD")
  }

  for map in [[], [0, -1, Int.min, Int.max, 3], [Int(Int32.max)], [2, 1], [1, 1]] {
    let config = DownmixProcessor.Configuration(channelMap: map, preampDb: 0, lfeLowpass: false)
    var processor = DownmixProcessor()
    processor.apply(realtimeConfiguration: .init(config))
    let output = render(&processor, [0.125, -0.25], channels: 2)
    let expected: [Float]
    if map == [2, 1] {
      expected = [-0.25, 0.125]
    } else if map == [1, 1] {
      expected = [0.125, 0.125]
    } else {
      expected = [0, 0]
    }
    require(output == expected, "short/invalid/out-of-range maps stay silent")
    let meter = processor.takeRealtimeMeterSnapshot()
    for slot in 2..<16 { require(meter.inputPeaks[slot] == 0, "invalid map input meters silent") }
  }
  print("PASS: POD configuration, gain sanitization and bad maps")
}

func checkRealtimeDSPEquivalence() {
  require(RealtimeMeterSnapshot.empty.snapshot == MeterSnapshot.empty, "empty raw/UI meters agree")
  var input = [Float](repeating: 0, count: 16 * 600)
  for frame in 0..<600 {
    for slot in 0..<16 {
      input[frame * 16 + slot] = Float((frame * 13 + slot * 7) % 23 - 11) * 0.025
    }
  }
  input[0] = .nan
  input[3] = .infinity
  input[16] = 20  // Exercise clip capture/clear on the dry path, too.
  for lowpass in [false, true] {
    for swap in [false, true] {
      var config = DownmixProcessor.Configuration(
        preampDb: -9.5, lfeLowpass: lowpass, swapOutputs: swap)
      var legacy = DownmixProcessor()
      var realtime = DownmixProcessor()
      legacy.apply(configuration: config)
      realtime.apply(realtimeConfiguration: .init(config))
      for pass in 0..<5 {
        // Exercise no-op, gain/swap changes and topology reset via both APIs.
        if pass == 1 { config.preampDb = -6 }
        if pass == 2 { config.swapOutputs.toggle() }
        if pass == 3 { config.channelMap = [2, 1, 3, 4] }
        if pass == 4 { config.inputChannelCount = 32 }
        legacy.apply(configuration: config)
        realtime.apply(realtimeConfiguration: .init(config))
        require(
          render(&legacy, input) == render(&realtime, input), "raw/legacy DSP output equality")
        for _ in 0..<3 {
          let raw = realtime.takeRealtimeMeterSnapshot()
          let mailbox = RealtimeMailbox(RealtimeMeterSnapshot.empty)
          mailbox.publish(raw)
          require(
            mailbox.consumeLatest()?.snapshot == legacy.takeMeterSnapshot(), "raw/UI meter equality"
          )
          require(mailbox.consumeLatest() == nil, "meter publication consumed once")
        }
      }
    }
  }

  var processor = DownmixProcessor()
  processor.apply(realtimeConfiguration: .init(.init(preampDb: 0, lfeLowpass: false)))
  _ = render(&processor, [2, -3], channels: 2)
  let clipped = processor.takeRealtimeMeterSnapshot()
  require(
    clipped.clipL && clipped.clipR && clipped.outputPeakL == 1 && clipped.outputPeakR == 1,
    "raw clipping")
  require(clipped.inputPeaks[0] == 2 && clipped.inputPeaks[1] == 3, "raw peaks are linear")
  let decayed = processor.takeRealtimeMeterSnapshot()
  require(
    !decayed.clipL && !decayed.clipR && decayed.outputPeakL == 0.6, "raw decay and clip reset")
  print("PASS: realtime/legacy DSP and meter equivalence, decay and clip consumption")
}

checkDeterministicMailbox()
checkConcurrentMailbox()
checkConfigurationAndBadMaps()
checkRealtimeDSPEquivalence()
print("Realtime checks passed")
