import Foundation
import OSLog
import Synchronization

struct DecoderRateObservation: Equatable, Sendable {
  var sourcePID: Int32? = nil
  var sampleRate: Double? = nil
  var date: Date? = nil
  var isAvailable: Bool = true
  /// Source bit depth stated by the same decoder record ("from 24-bit source").
  var bitDepth: Int? = nil
}

/// Call start/stop on the main thread; reports arrive on the main queue.
protocol DecoderRateMonitoring: AnyObject {
  func start(
    source: AudioPlaybackSource, report: @escaping @Sendable (DecoderRateObservation) -> Void)
  func stop()
}

/// Deliberately NOT a general ASBD/rate parser. Only the explicit ALAC decoder
/// input diagnostic below is supported. No verified FLAC/AAC/MP3 diagnostic
/// grammar is available here; absence of evidence must remain an unknown rate.
enum DecoderInputRateParser {
  static let maximumAge: TimeInterval = 4
  static let maximumRecords = 512
  static let maximumMessageBytes = 4096
  static let audioSubsystems = ["com.apple.coreaudio", "com.apple.coremedia", "com.apple.Music"]
  static let supportedRates: Set<Double> = [
    8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000,
    64000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000,
  ]

  /// Ephemeral fixture/entry view. The monitor never stores records or raw logs.
  struct Record: Sendable {
    var sourcePID: Int32?
    var process: String
    var subsystem: String
    var message: String
    var date: Date
  }

  static func isFresh(_ date: Date, now: Date) -> Bool {
    let age = now.timeIntervalSince(date)
    return age.isFinite && age >= -0.5 && age <= maximumAge
  }

  static func permitsProcess(_ process: String) -> Bool {
    let name = process.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return !name.isEmpty && !name.contains("downmix")
      && name != "coreaudiod" && name != "audiomxd"
  }

  static func permitsSource(_ source: AudioPlaybackSource, ownPID: Int32) -> Bool {
    source.id > 0 && source.id != ownPID && permitsProcess(source.name)
      && !(source.bundleIdentifier?.lowercased().contains("downmix") ?? false)
      && !(source.bundleIdentifier?.lowercased().contains("coreaudiod") ?? false)
  }

  // Anchored, single-record grammar: decoder identity AND Input format AND an
  // explicit source bit depth. The optional 'alac' ASBD flag is descriptive only.
  // Arbitrary prefixes/suffixes, embedded output/device/config records, privacy
  // placeholders, multiple input records, and generic format guesses all fail.
  private static let inputPattern = try! NSRegularExpression(
    pattern:
      #"\AACAppleLosslessDecoder(?:\.cpp)?(?::[0-9]{1,6})?[ \t:]*(?:\[(?:0x)?[0-9A-Fa-f]{1,16}\][ \t]*)?Input format:[ \t]*([1-9][0-9]?) ch,[ \t]*([0-9]{4,6}(?:\.0{1,3})?) Hz(?:,[ \t]*'alac'[ \t]*\(0x[0-9A-Fa-f]{1,8}\))?[ \t]+from (16|20|24|32)-bit source[ \t]*\z"#
  )

  static func sampleRate(in message: String) -> Double? {
    guard let rate = declaredInputRate(in: message), supportedRates.contains(rate) else {
      return nil
    }
    return rate
  }

  private static func declaredInputRate(in message: String) -> Double? {
    declaredInput(in: message)?.rate
  }

  /// Rate and source bit depth from one anchored decoder-input record.
  static func declaredInput(in message: String) -> (rate: Double, bits: Int)? {
    guard message.utf8.count <= maximumMessageBytes,
      let match = inputPattern.firstMatch(
        in: message, range: NSRange(message.startIndex..., in: message)),
      let range = Range(match.range(at: 2), in: message),
      let rate = Double(message[range]), rate.isFinite,
      let bitsRange = Range(match.range(at: 3), in: message),
      let bits = Int(message[bitsRange])
    else { return nil }
    return (rate, bits)
  }

  /// Streaming selection keeps only numeric evidence, not messages. Equal latest
  /// timestamps with different rates are ambiguous regardless of iteration order.
  struct Selection {
    private var latest: Date?
    private var rate: Double?
    private var bits: Int?
    private var conflicted = false

    mutating func consider(
      _ record: Record, sourcePID: Int32, ownPID: Int32, lowerBound: Date, now: Date
    ) {
      guard sourcePID > 0, sourcePID != ownPID, record.sourcePID == sourcePID,
        permitsProcess(record.process), audioSubsystems.contains(record.subsystem),
        record.date >= lowerBound, isFresh(record.date, now: now),
        let candidate = declaredInput(in: record.message)
      else { return }
      if latest == nil || record.date > latest! {
        latest = record.date
        rate = candidate.rate
        bits = candidate.bits
        conflicted = false
      } else if record.date == latest, candidate.rate != rate || candidate.bits != bits {
        conflicted = true
      }
    }

    func observation(sourcePID: Int32) -> DecoderRateObservation {
      guard let latest else { return DecoderRateObservation(sourcePID: sourcePID) }
      guard !conflicted, let rate, supportedRates.contains(rate) else {
        // A recognized but unusable/conflicting NEW input supersedes older evidence.
        return DecoderRateObservation(sourcePID: sourcePID, date: latest)
      }
      return DecoderRateObservation(
        sourcePID: sourcePID, sampleRate: rate, date: latest, bitDepth: bits)
    }
  }

  static func select(
    _ records: [Record], sourcePID: Int32, ownPID: Int32, lowerBound: Date, now: Date
  ) -> DecoderRateObservation {
    guard records.count <= maximumRecords else {
      return DecoderRateObservation(sourcePID: sourcePID)
    }
    var selection = Selection()
    for record in records {
      selection.consider(
        record, sourcePID: sourcePID, ownPID: ownPID, lowerBound: lowerBound, now: now)
    }
    return selection.observation(sourcePID: sourcePID)
  }
}

/// Public, read-only unified-log access. No playback/device operations, process
/// launches, privilege requests, source-file reads, or application-default rates.
/// Log availability does not imply that a client (notably browsers/Kew) emits
/// source decoder diagnostics, nor does a PID identify a particular browser tab.
final class DecoderRateMonitor: DecoderRateMonitoring, Sendable {
  typealias Reader = @Sendable (AudioPlaybackSource, Date, Date) throws -> DecoderRateObservation

  private struct State {
    var generation: UInt64 = 0
    var timer: DispatchSourceTimer?
    var lastObservation: DecoderRateObservation?
  }

  private let state = Mutex(State())
  private let queue = DispatchQueue(label: "com.local.downmix.decoder-rates", qos: .utility)
  private let reader: Reader

  // Reader injection supports isolated checks without touching real logs.
  init(reader: @escaping Reader = DecoderRateMonitor.readObservation) {
    self.reader = reader
  }

  func start(
    source: AudioPlaybackSource, report: @escaping @Sendable (DecoderRateObservation) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    let lowerBound = Date().addingTimeInterval(-1.5)
    state.withLock { state in
      state.timer?.cancel()
      state.generation &+= 1
      state.lastObservation = nil
      let generation = state.generation
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
      timer.setEventHandler { [weak self] in
        self?.poll(source: source, lowerBound: lowerBound, generation: generation, report: report)
      }
      state.timer = timer
      timer.resume()
    }
  }

  func stop() {
    dispatchPrecondition(condition: .onQueue(.main))
    state.withLock { state in
      state.generation &+= 1
      state.timer?.cancel()
      state.timer = nil
      state.lastObservation = nil
    }
  }

  deinit {
    state.withLock { $0.timer?.cancel() }
  }

  private func isCurrent(_ generation: UInt64) -> Bool {
    state.withLock { $0.generation == generation && $0.timer != nil }
  }

  private func poll(
    source: AudioPlaybackSource, lowerBound: Date, generation: UInt64,
    report: @escaping @Sendable (DecoderRateObservation) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard isCurrent(generation) else { return }
    let observation = autoreleasepool {
      guard
        DecoderInputRateParser.permitsSource(
          source, ownPID: ProcessInfo.processInfo.processIdentifier)
      else { return DecoderRateObservation(sourcePID: source.id) }
      do {
        return try reader(source, lowerBound, Date())
      } catch {
        // Do not expose error descriptions: they may include log/user metadata.
        return DecoderRateObservation(sourcePID: source.id, isAvailable: false)
      }
    }
    guard isCurrent(generation) else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isCurrent(generation) else { return }
      // A busy main queue must not deliver an observation that expired in flight.
      var delivered = observation
      if let rate = delivered.sampleRate {
        if delivered.sourcePID != source.id || !rate.isFinite
          || !DecoderInputRateParser.supportedRates.contains(rate)
          || delivered.date.map({
            $0 >= lowerBound && DecoderInputRateParser.isFresh($0, now: Date())
          }) != true || !delivered.isAvailable
        {
          delivered = DecoderRateObservation(
            sourcePID: source.id, isAvailable: delivered.isAvailable)
        }
      }
      let changed = self.state.withLock { state in
        guard state.lastObservation != delivered else { return false }
        state.lastObservation = delivered
        return true
      }
      // Main-thread lifecycle calls cannot interleave here. No callback under lock.
      if changed { report(delivered) }
    }
  }

  private static func readObservation(
    source: AudioPlaybackSource, lowerBound: Date, now: Date
  ) throws -> DecoderRateObservation {
    precondition(!Thread.isMainThread)
    let missing = DecoderRateObservation(sourcePID: source.id)
    let ownPID = ProcessInfo.processInfo.processIdentifier
    guard DecoderInputRateParser.permitsSource(source, ownPID: ownPID) else { return missing }
    let earliest = max(lowerBound, now.addingTimeInterval(-DecoderInputRateParser.maximumAge))
    let store = try OSLogStore.local()
    let predicate = NSPredicate(
      format: "processIdentifier == %d AND subsystem IN %@ AND date >= %@ AND date <= %@",
      source.id, DecoderInputRateParser.audioSubsystems, earliest as NSDate,
      now.addingTimeInterval(0.5) as NSDate)
    let entries = try store.getEntries(
      at: store.position(date: earliest), matching: predicate)
    var selection = DecoderInputRateParser.Selection()
    var count = 0
    let scanStart = DispatchTime.now().uptimeNanoseconds
    for entry in entries {
      // Bounds cover application-side scanning, not a synchronous OSLog call
      // blocked inside the OS. Such calls cannot block the main queue or report
      // into a later generation. Truncation must never choose a partial winner.
      guard count < DecoderInputRateParser.maximumRecords,
        DispatchTime.now().uptimeNanoseconds - scanStart < 150_000_000
      else { return missing }
      count += 1
      guard entry.date >= earliest, let log = entry as? OSLogEntryLog,
        log.processIdentifier == source.id, log.processIdentifier != ownPID,
        DecoderInputRateParser.audioSubsystems.contains(log.subsystem),
        DecoderInputRateParser.permitsProcess(log.process),
        DecoderInputRateParser.isFresh(log.date, now: now)
      else { continue }
      selection.consider(
        DecoderInputRateParser.Record(
          sourcePID: log.processIdentifier, process: log.process, subsystem: log.subsystem,
          message: log.composedMessage, date: log.date),
        sourcePID: source.id, ownPID: ownPID, lowerBound: earliest, now: now)
    }
    return selection.observation(sourcePID: source.id)
  }
}
