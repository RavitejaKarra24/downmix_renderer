import Foundation
import Synchronization

/// Severity of one diagnostic line.
enum DiagnosticLevel: String, Sendable {
  case info = "INFO"
  case warning = "WARN"
  case error = "ERROR"
}

/// Anything the app can log to. The UI and lifecycle code depend on this protocol so
/// tests can stay silent; production uses `DownmixLog.shared`.
protocol DiagnosticLogging: Sendable {
  func log(_ level: DiagnosticLevel, _ category: String, _ message: String)
}

extension DiagnosticLogging {
  /// One compact line for a failed run. Counters are the per-run engine diagnostics.
  func logFailure(_ message: String, context: String, diagnostics: EngineDiagnostics?) {
    var line = "\(context): \(message)"
    if let diagnostics {
      line +=
        " | buffers=\(diagnostics.requestedBufferFrames)/\(diagnostics.inputBufferFrames)/\(diagnostics.outputBufferFrames)"
        + " underruns=\(diagnostics.underrunCount)/\(diagnostics.underrunFrames)f"
        + " overruns=\(diagnostics.overrunCount)/\(diagnostics.overrunFrames)f"
        + " rejected=\(diagnostics.rejectedSliceCount) renderErrors=\(diagnostics.renderErrorCount)"
        + " rebuffers=\(diagnostics.rebufferCount) queued=\(diagnostics.queuedFrames)"
    }
    log(.error, "engine", line)
  }
}

/// Rotating on-disk diagnostics log at `~/Library/Logs/Downmix/downmix.log`.
///
/// The app writes lifecycle events, every transport failure with its per-run counters,
/// and a periodic heartbeat while rendering. A session marker records whether the last
/// run ended cleanly, so an abrupt stop (crash, forced quit, power loss) is visible on
/// the next launch. Fatal signals are appended from a pre-opened descriptor.
///
/// Every write happens on one utility queue. Nothing here is called from an audio
/// callback. Logging failures are swallowed: diagnostics must never break rendering.
final class DownmixLog: DiagnosticLogging, @unchecked Sendable {
  static let shared = DownmixLog()

  /// Rotate before the file grows past this size; two older files are kept.
  static let maximumFileBytes = 512 * 1024
  static let archivedFileCount = 2

  static var defaultDirectory: URL {
    FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Logs/Downmix", isDirectory: true)
  }

  let directory: URL
  var fileURL: URL { directory.appendingPathComponent("downmix.log") }

  private let queue = DispatchQueue(label: "com.local.downmix.diagnostics", qos: .utility)
  private let enabled = Atomic<Bool>(false)
  private let sessionMarker = "session start"
  private let cleanMarker = "clean exit"

  // Queue-confined state.
  private var handle: FileHandle?
  private var bytesWritten = 0
  private var timestampFormatter: ISO8601DateFormatter?

  init(directory: URL = DownmixLog.defaultDirectory) {
    self.directory = directory
  }

  deinit {
    try? handle?.close()
    handle = nil
  }

  var isEnabled: Bool { enabled.load(ordering: .acquiring) }

  /// Starts one app session: enables logging, rotates oversized files, reports a
  /// previous unclean exit, and installs fatal-signal recording.
  /// Test processes never call this, so their logs stay untouched.
  func beginSession(version: String, details: [String] = []) {
    guard enabled.exchange(true, ordering: .acquiringAndReleasing) == false else { return }
    queue.async { [self] in
      prepareDirectory()
      rotateIfNeeded()
      let previousWasClean = previousSessionEndedCleanly()
      openHandle()
      if !previousWasClean {
        write(
          .warning, "lifecycle",
          "previous session ended without a clean exit; the lines above show its last state")
      }
      write(.info, "lifecycle", "\(sessionMarker) version=\(version)")
      for detail in details { write(.info, "startup", detail) }
      DownmixLog.installFatalSignalHandlers(descriptor: handle?.fileDescriptor ?? -1)
    }
  }

  /// Waits for queued lines. Never called from the log queue itself.
  func flush() {
    queue.sync {}
  }

  /// Records a clean exit and closes the file. Called from application termination,
  /// where losing the final lines would hide the previous-session verdict.
  func endSession(reason: String = "quit") {
    guard isEnabled else { return }
    queue.sync { [self] in
      write(.info, "lifecycle", "\(cleanMarker) reason=\(reason)")
      try? handle?.synchronize()
      try? handle?.close()
      handle = nil
      handle = nil
      DownmixLog.installFatalSignalHandlers(descriptor: -1)
      enabled.store(false, ordering: .releasing)
    }
  }

  func log(_ level: DiagnosticLevel, _ category: String, _ message: String) {
    guard isEnabled else { return }
    queue.async { [self] in write(level, category, message) }
  }

  // MARK: - File handling (log queue only)

  private func prepareDirectory() {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  private func openHandle() {
    let url = fileURL
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let opened = try? FileHandle(forWritingTo: url) else { return }
    _ = try? opened.seekToEnd()
    bytesWritten = Int((try? opened.offset()) ?? 0)
    handle = opened
    // Rotation closes the old descriptor; fatal-signal records must follow the live file.
    fatalDescriptor = opened.fileDescriptor
  }

  private func rotateIfNeeded() {
    let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
    let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    guard size >= DownmixLog.maximumFileBytes else { return }
    try? handle?.close()
    handle = nil
    let manager = FileManager.default
    let oldest = directory.appendingPathComponent("downmix.\(DownmixLog.archivedFileCount).log")
    try? manager.removeItem(at: oldest)
    for index in stride(from: DownmixLog.archivedFileCount - 1, through: 1, by: -1) {
      let source = directory.appendingPathComponent("downmix.\(index).log")
      let destination = directory.appendingPathComponent("downmix.\(index + 1).log")
      if manager.fileExists(atPath: source.path) {
        try? manager.moveItem(at: source, to: destination)
      }
    }
    try? manager.moveItem(at: fileURL, to: directory.appendingPathComponent("downmix.1.log"))
  }

  /// Reads the tail of the existing log and looks at its last lifecycle marker.
  private func previousSessionEndedCleanly() -> Bool {
    guard let existing = try? FileHandle(forReadingFrom: fileURL) else { return true }
    defer { try? existing.close() }
    let size = Int((try? existing.seekToEnd()) ?? 0)
    let window = min(size, 32 * 1024)
    guard window > 0 else { return true }
    try? existing.seek(toOffset: UInt64(size - window))
    guard let data = try? existing.read(upToCount: window) else { return true }
    let text = String(decoding: data, as: UTF8.self)
    for line in text.split(separator: "\n").reversed() where line.contains("[lifecycle]") {
      return line.contains(cleanMarker)
    }
    // A long session can push its start marker out of the window. Without a clean-exit
    // marker at the end, the previous session did not shut down normally.
    return false
  }

  private func write(_ level: DiagnosticLevel, _ category: String, _ message: String) {
    guard handle != nil else { return }
    if bytesWritten >= DownmixLog.maximumFileBytes {
      rotateIfNeeded()
      openHandle()
      guard handle != nil else { return }
    }
    let formatter: ISO8601DateFormatter
    if let timestampFormatter {
      formatter = timestampFormatter
    } else {
      let created = ISO8601DateFormatter()
      created.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      timestampFormatter = created
      formatter = created
    }
    let paddedLevel = level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)
    let line =
      "\(formatter.string(from: Date())) \(paddedLevel)[\(category)] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    do {
      try handle?.write(contentsOf: data)
      bytesWritten += data.count
    } catch {
      // A full or read-only log must never interrupt audio.
      try? handle?.close()
      handle = nil
    }
  }

  // MARK: - Abrupt termination

  /// Records fatal signals into the same file. The handler only calls `write` and then
  /// re-raises the default action, so the system crash report is still produced.
  static func installFatalSignalHandlers(descriptor: Int32) {
    fatalDescriptor = descriptor
    // `SIGKILL` cannot be caught; the session marker reports it on the next launch.
    for signalNumber in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGTERM, SIGINT] {
      signal(signalNumber, fatalSignalHandler)
    }
    NSSetUncaughtExceptionHandler { exception in
      let reason = exception.reason ?? "unknown"
      DownmixLog.shared.log(
        .error, "crash",
        "uncaught Objective-C exception \(exception.name.rawValue): \(reason)")
    }
  }

  fileprivate static func recordFatalSignal(_ signalNumber: Int32) {
    guard fatalDescriptor >= 0 else { return }
    switch signalNumber {
    case SIGABRT: writeFatal("SIGABRT")
    case SIGSEGV: writeFatal("SIGSEGV")
    case SIGBUS: writeFatal("SIGBUS")
    case SIGILL: writeFatal("SIGILL")
    case SIGFPE: writeFatal("SIGFPE")
    case SIGTRAP: writeFatal("SIGTRAP")
    case SIGTERM: writeFatal("SIGTERM")
    case SIGINT: writeFatal("SIGINT")
    default: writeFatal("unknown signal")
    }
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
  }

  /// Async-signal-safe: a pre-opened descriptor and a static byte literal only.
  private static func writeFatal(_ name: StaticString) {
    let prefix = StaticString("[FATAL] uncaught ")
    prefix.withUTF8Buffer { bytes in
      guard let base = bytes.baseAddress else { return }
      _ = _DarwinFoundation3.write(fatalDescriptor, base, bytes.count)
    }
    name.withUTF8Buffer { bytes in
      guard let base = bytes.baseAddress else { return }
      _ = _DarwinFoundation3.write(fatalDescriptor, base, bytes.count)
    }
    StaticString("; terminating\n").withUTF8Buffer { bytes in
      guard let base = bytes.baseAddress else { return }
      _ = _DarwinFoundation3.write(fatalDescriptor, base, bytes.count)
    }
  }
}

/// Descriptor for fatal-signal records. One process-wide log, like the file itself.
nonisolated(unsafe) private var fatalDescriptor: Int32 = -1

private func fatalSignalHandler(_ signalNumber: Int32) {
  DownmixLog.recordFatalSignal(signalNumber)
}
