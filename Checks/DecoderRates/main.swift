import Darwin
import Foundation
import Synchronization

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let pid: Int32 = 1_500_001
private let ownPID: Int32 = 1_500_002
private let source = AudioPlaybackSource(id: pid, name: "Fixture Player", bundleIdentifier: nil)

private func input(_ rate: String = "96000") -> String {
  "ACAppleLosslessDecoder.cpp:123 Input format: 2 ch, \(rate) Hz, 'alac' (0x00000003) from 24-bit source"
}

private func expect(_ condition: Bool, _ name: String) {
  precondition(condition, "FAIL: \(name)")
}

private func record(
  _ rate: String = "96000", age: TimeInterval = 0, owner: Int32? = pid,
  process: String = "Fixture Player", subsystem: String = "com.apple.coreaudio",
  message: String? = nil
) -> DecoderInputRateParser.Record {
  DecoderInputRateParser.Record(
    sourcePID: owner, process: process, subsystem: subsystem,
    message: message ?? input(rate), date: now.addingTimeInterval(-age))
}

private func select(
  _ records: [DecoderInputRateParser.Record], lowerBound: Date? = nil, selectedPID: Int32 = pid
) -> DecoderRateObservation {
  DecoderInputRateParser.select(
    records, sourcePID: selectedPID, ownPID: ownPID,
    lowerBound: lowerBound ?? now.addingTimeInterval(-4), now: now)
}

private func parserChecks() {
  expect(DecoderInputRateParser.maximumAge == 4, "four-second maximum")
  for age: TimeInterval in [-0.5, 0, 1.5, 4] {
    expect(
      DecoderInputRateParser.isFresh(now.addingTimeInterval(-age), now: now),
      "freshness boundary \(age)")
  }
  for age: TimeInterval in [-0.501, 4.001, .infinity, -.infinity, .nan] {
    expect(
      !DecoderInputRateParser.isFresh(now.addingTimeInterval(-age), now: now),
      "invalid/stale/future date")
  }
  expect(DecoderInputRateParser.sampleRate(in: input()) == 96000, "explicit ALAC input")
  expect(DecoderInputRateParser.declaredInput(in: input())?.bits == 24, "source bit depth parsed")
  expect(select([record()]).bitDepth == 24, "selected observation carries the source depth")
  expect(
    select([
      record(age: 2), record(message: input().replacingOccurrences(of: "24-bit", with: "16-bit")),
    ])
    .bitDepth == 16, "latest record's depth wins")
  expect(
    DecoderInputRateParser.sampleRate(
      in: "ACAppleLosslessDecoder Input format: 2 ch, 44100 Hz from 16-bit source") == 44100,
    "minimal explicit ALAC input")
  expect(
    DecoderInputRateParser.sampleRate(
      in: "ACAppleLosslessDecoder.cpp:37 [0x1234] Input format: 2 ch, 48000.0 Hz from 24-bit source"
    ) == 48000, "pointer diagnostic and exact integral rate")
  for rate in DecoderInputRateParser.supportedRates {
    expect(
      DecoderInputRateParser.sampleRate(in: input(String(Int(rate)))) == rate, "supported rate")
  }
  let rejected = [
    "Input format: 2 ch, 96000 Hz from 24-bit source",
    "ACAppleLosslessDecoder Output format: 2 ch, 96000 Hz from 24-bit source",
    "ACAppleLosslessEncoder Input format: 2 ch, 96000 Hz from 24-bit source",
    "FLACDecoder Input format: 2 ch, 96000 Hz from 24-bit source",
    "AACDecoder Input format: 2 ch, 96000 Hz from 24-bit source",
    "MP3Decoder Input format: 2 ch, 96000 Hz from 24-bit source",
    "ACAppleLosslessDecoder mSampleRate = 96000",
    "Creating AudioQueue sampleRate:96000",
    "output ASBD: 2 ch, 96000 Hz",
    "Music audioCapabilities asbdSampleRate = 96 kHz",
    "config device sample rate: 96000",
    "Downmix " + input(), "coreaudiod " + input(),
    "device " + input(), "output ASBD " + input(),
    input() + " output ASBD: 48000 Hz", input() + " device config",
    input() + "\n" + input("48000"), input() + " " + input("48000"),
    input() + "\n", input() + "\0", "\n" + input(),
    input().replacingOccurrences(of: "24-bit", with: "999-bit"),
    input().replacingOccurrences(of: "2 ch", with: "0 ch"),
    input().replacingOccurrences(of: "'alac'", with: "'lpcm'"),
    input().replacingOccurrences(of: "from 24-bit source", with: ""),
    input().replacingOccurrences(of: "Input", with: "Output"),
    String(repeating: " ", count: 5000) + input(),
  ]
  for message in rejected {
    // Do not print even fixture messages: checks model the no-raw-log contract.
    expect(DecoderInputRateParser.sampleRate(in: message) == nil, "reject untrusted format")
  }
  for rate in [
    "nan", "NaN", "inf", "-96000", "+96000", "96e3", "96,000", "96000.5", "96000..0", "0", "12345",
    "99999999999999999999", "<private>",
  ] {
    expect(DecoderInputRateParser.sampleRate(in: input(rate)) == nil, "malformed/unsupported rate")
  }
  expect(select([record()]).sampleRate == 96000, "owned recent input")
  for rejectedRecord in [
    record(owner: nil), record(owner: 44), record(owner: ownPID), record(process: ""),
    record(process: "coreaudiod"), record(process: "audiomxd"),
    record(process: "Downmix Renderer"), record(process: "DOWNMIX"),
    record(subsystem: "com.example.player"), record(subsystem: ""),
    record(age: 4.001), record(age: -0.501), record(message: "mSampleRate = 96000"),
  ] {
    let result = select([rejectedRecord])
    expect(result.sampleRate == nil && result.date == nil && result.isAvailable, "reject record")
  }
  expect(select([record()], selectedPID: ownPID).sampleRate == nil, "own source excluded")
  expect(select([record()], selectedPID: 0).sampleRate == nil, "invalid source excluded")
  expect(select([]) == DecoderRateObservation(sourcePID: pid), "missing remains unknown")
  expect(
    select([record(age: 1.501)], lowerBound: now.addingTimeInterval(-1.5)).sampleRate == nil,
    "initial lower bound rejects activity before start overlap")
  expect(
    select([record(age: 1.5)], lowerBound: now.addingTimeInterval(-1.5)).sampleRate == 96000,
    "initial overlap boundary included")
  let old = record("44100", age: 1)
  let latest = record()
  for records in [[old, latest], [latest, old]] {
    expect(select(records).sampleRate == 96000, "latest wins independently of enumeration order")
  }
  for records in [[latest, record("48000")], [record("48000"), latest, old]] {
    let result = select(records)
    expect(
      result.sampleRate == nil && result.date == now,
      "equal latest conflict supersedes prior evidence")
  }
  expect(select([latest, latest]).sampleRate == 96000, "duplicate corroboration")
  let unsupported = record("12345")
  let invalidated = select([record("96000", age: 1), unsupported])
  expect(
    invalidated.sampleRate == nil && invalidated.date == now,
    "new explicit unsupported input supersedes older supported rate")
  expect(
    select([record("44100", age: 1), record("48000", age: 1), latest]).sampleRate == 96000,
    "newer evidence supersedes older conflict")
  expect(
    select(Array(repeating: latest, count: DecoderInputRateParser.maximumRecords + 1)).sampleRate
      == nil, "bounded selection fails closed")
  expect(
    !DecoderInputRateParser.permitsSource(
      AudioPlaybackSource(id: pid, name: "Player", bundleIdentifier: "com.local.Downmix"),
      ownPID: ownPID), "bundle feedback excluded")
  expect(
    !DecoderInputRateParser.permitsSource(source, ownPID: pid), "own process excluded")
  print("PASS: strict input parser, ownership, freshness, bounds and conflict fixtures")
}

private func pump(until condition: () -> Bool, timeout: TimeInterval = 3) {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition(), Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  }
  expect(condition(), "asynchronous fixture completed")
}

private enum FixtureError: Error { case denied }

private func lifecycleChecks() {
  let observations = Mutex<[DecoderRateObservation]>([])
  let reads = Mutex(0)
  let monitor = DecoderRateMonitor { selected, lowerBound, pollDate in
    expect(!Thread.isMainThread, "reader runs off main")
    expect(selected == source, "reader receives selected source")
    expect(lowerBound <= pollDate && pollDate.timeIntervalSince(lowerBound) < 5, "start bound")
    return reads.withLock { count in
      count += 1
      if count == 1 {
        return DecoderRateObservation(sourcePID: selected.id, sampleRate: 96000, date: pollDate)
      }
      return DecoderRateObservation(sourcePID: selected.id)
    }
  }
  monitor.start(source: source) { observation in
    expect(Thread.isMainThread, "reports on main")
    observations.withLock { $0.append(observation) }
  }
  pump { observations.withLock { $0.count >= 2 } }
  monitor.stop()
  expect(
    observations.withLock { $0[0].sampleRate == 96000 && $0[1].sampleRate == nil },
    "missing clears rate")

  let errors = Mutex<[DecoderRateObservation]>([])
  let denied = DecoderRateMonitor { _, _, _ in throw FixtureError.denied }
  denied.start(source: source) { result in errors.withLock { $0.append(result) } }
  pump { errors.withLock { !$0.isEmpty } }
  denied.stop()
  expect(
    errors.withLock { $0 == [DecoderRateObservation(sourcePID: pid, isAvailable: false)] },
    "generic access failure")

  let began = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  let oldReports = Mutex(0)
  let newReports = Mutex(0)
  let calls = Mutex(0)
  let restarting = DecoderRateMonitor { selected, _, pollDate in
    let first = calls.withLock { count in
      count += 1
      return count == 1
    }
    if first {
      began.signal()
      expect(release.wait(timeout: .now() + 3) == .success, "release old read")
    }
    return DecoderRateObservation(sourcePID: selected.id, sampleRate: 48000, date: pollDate)
  }
  restarting.start(source: source) { _ in oldReports.withLock { $0 += 1 } }
  expect(began.wait(timeout: .now() + 3) == .success, "old read starts")
  restarting.stop()
  restarting.start(source: source) { _ in newReports.withLock { $0 += 1 } }
  release.signal()
  pump { newReports.withLock { $0 == 1 } }
  restarting.stop()
  expect(oldReports.withLock { $0 == 0 }, "stop/restart suppresses in-flight old generation")

  let queuedRead = DispatchSemaphore(value: 0)
  let queuedReports = Mutex(0)
  let queued = DecoderRateMonitor { selected, _, date in
    queuedRead.signal()
    return DecoderRateObservation(sourcePID: selected.id, sampleRate: 44100, date: date)
  }
  queued.start(source: source) { _ in queuedReports.withLock { $0 += 1 } }
  expect(queuedRead.wait(timeout: .now() + 3) == .success, "queued reader returns")
  // Hold main so the old report is queued, then invalidate it before delivery.
  usleep(100_000)
  queued.stop()
  RunLoop.main.run(until: Date().addingTimeInterval(0.1))
  expect(queuedReports.withLock { $0 == 0 }, "stop suppresses already queued report")

  let expiryReports = Mutex<[DecoderRateObservation]>([])
  let expired = DecoderRateMonitor { selected, _, date in
    DecoderRateObservation(
      sourcePID: selected.id, sampleRate: 96000, date: date.addingTimeInterval(-5))
  }
  expired.start(source: source) { result in expiryReports.withLock { $0.append(result) } }
  pump { expiryReports.withLock { !$0.isEmpty } }
  expired.stop()
  expect(
    expiryReports.withLock { $0[0].sampleRate == nil && $0[0].date == nil },
    "delivery rechecks expiry")
  let agingDate = Date()
  let agingReports = Mutex<[DecoderRateObservation]>([])
  let aging = DecoderRateMonitor { selected, _, _ in
    DecoderRateObservation(sourcePID: selected.id, sampleRate: 96000, date: agingDate)
  }
  aging.start(source: source) { result in agingReports.withLock { $0.append(result) } }
  pump(until: { agingReports.withLock { $0.count >= 2 } }, timeout: 6)
  aging.stop()
  expect(
    agingReports.withLock { $0[0].sampleRate == 96000 && $0[1].sampleRate == nil },
    "unchanged evidence expires while polling")

  let blockedReads = Mutex(0)
  let blockedReports = Mutex<[DecoderRateObservation]>([])
  let blocked = DecoderRateMonitor { selected, _, _ in
    blockedReads.withLock { $0 += 1 }
    return DecoderRateObservation(sourcePID: selected.id)
  }
  let feedbackSource = AudioPlaybackSource(
    id: pid, name: "Downmix Renderer", bundleIdentifier: "com.local.downmix")
  blocked.start(source: feedbackSource) { result in
    blockedReports.withLock { $0.append(result) }
  }
  pump { blockedReports.withLock { !$0.isEmpty } }
  blocked.stop()
  expect(blockedReads.withLock { $0 == 0 }, "feedback source never queried")
  print("PASS: utility reads, main reports, nil expiry/missing, errors and generation suppression")
}

@main
private struct DecoderRateChecks {
  static func main() {
    parserChecks()
    lifecycleChecks()
    print("Decoder checks passed (isolated fixtures; no real logs or playback accessed).")
  }
}
