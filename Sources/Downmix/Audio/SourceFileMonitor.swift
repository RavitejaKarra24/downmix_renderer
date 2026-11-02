import AudioToolbox
import Darwin
import Foundation
import Synchronization

/// Format read from the header of the audio file a routed player has open: the
/// source's real rate, bit depth and channel count, before any player conversion.
struct SourceFileFormat: Equatable, Sendable {
  var fileName: String
  var sampleRate: Double
  /// `nil` for lossy codecs (MP3, AAC, Opus…), which have no source bit depth.
  var bitDepth: Int?
  var channels: Int

  var summary: String {
    var parts = ["\(Int(sampleRate.rounded())) Hz"]
    if let bitDepth { parts.append("\(bitDepth)-bit") }
    parts.append("\(channels) ch")
    return parts.joined(separator: ", ")
  }
}

/// What one routed client is playing from disk, if anything can be read.
struct SourceFileObservation: Equatable, Sendable {
  var sourcePID: Int32
  /// The file this client is playing; `nil` when none is open or the choice is ambiguous.
  var format: SourceFileFormat? = nil
  /// Several open audio files disagree and none is identifiably the current track.
  var isAmbiguous = false
  /// The file's read position has stood still for a while (a paused player). Players
  /// that read without moving the position are never reported idle.
  var isIdle = false
}

/// Call start/stop on the main thread; reports arrive on the main queue.
protocol SourceFileMonitoring: AnyObject {
  func start(
    source: AudioPlaybackSource, report: @escaping @Sendable (SourceFileObservation) -> Void)
  func stop()
}

/// Pure pieces of open-file source detection, separated for isolated checks.
enum SourceFileInspector {
  static let audioExtensions: Set<String> = [
    "flac", "wav", "wave", "aif", "aiff", "aifc", "caf", "m4a", "m4b", "alac", "mp3", "mp2",
    "aac", "adts", "ac3", "ec3", "mp4", "m4v", "mov", "3gp", "amr",
  ]
  static let maximumFiles = 16

  /// Only user media: never app resources, system sounds or caches.
  static func isCandidate(path: String) -> Bool {
    guard path.hasPrefix("/"), !path.contains(".app/"), !path.hasPrefix("/System/"),
      !path.hasPrefix("/usr/"), !path.hasPrefix("/private/var/db/"),
      !path.contains("/Library/Caches/")
    else { return false }
    let ext = (path as NSString).pathExtension.lowercased()
    return audioExtensions.contains(ext)
  }

  /// Source bit depth from Core Audio's description: PCM word size, or the lossless
  /// source-depth flag shared by ALAC and FLAC. Lossy codecs have none.
  static func bitDepth(of format: AudioStreamBasicDescription, sourceBitDepth: Int32?) -> Int? {
    if let sourceBitDepth, sourceBitDepth != 0 { return Int(abs(sourceBitDepth)) }
    switch format.mFormatID {
    case kAudioFormatLinearPCM:
      return format.mBitsPerChannel > 0 ? Int(format.mBitsPerChannel) : nil
    case kAudioFormatAppleLossless, kAudioFormatFLAC:
      switch format.mFormatFlags {
      case 1: return 16
      case 2: return 20
      case 3: return 24
      case 4: return 32
      default: return nil
      }
    default:
      return nil
    }
  }

  struct OpenFile: Equatable, Sendable {
    var path: String
    var offset: Int64
    var format: SourceFileFormat
  }

  /// Picks the track being played from the client's open audio files. Gapless players
  /// open the next track before the current one ends, so the current file stays
  /// authoritative while it remains open; a file whose read position advances (while
  /// the others stand still) identifies the active one. Otherwise disagreement is
  /// ambiguous, never resolved by guessing.
  struct Selection {
    static let idleAfter: TimeInterval = 10
    private(set) var currentPath: String?
    private var lastOffsets: [String: Int64] = [:]
    /// When each open file's read position last moved (or was first seen).
    private var lastActivity: [String: Date] = [:]

    struct Choice: Equatable {
      var format: SourceFileFormat?
      var ambiguous = false
      var idle = false
    }

    mutating func choose(_ files: [OpenFile], now: Date = Date()) -> Choice {
      let advancing = files.filter { file in
        lastOffsets[file.path].map { $0 != file.offset } ?? false
      }
      var activity: [String: Date] = [:]
      for file in files {
        let moved = advancing.contains { $0.path == file.path }
        activity[file.path] = moved ? now : (lastActivity[file.path] ?? now)
      }
      defer {
        lastOffsets = Dictionary(
          files.map { ($0.path, $0.offset) }, uniquingKeysWith: { first, _ in first })
        lastActivity = activity
      }
      func choice(_ file: OpenFile) -> Choice {
        let quiet = now.timeIntervalSince(activity[file.path] ?? now)
        return Choice(format: file.format, idle: file.offset != 0 && quiet >= Self.idleAfter)
      }
      guard let first = files.first else {
        currentPath = nil
        return Choice()
      }
      if advancing.count == 1 {
        currentPath = advancing[0].path
        return choice(advancing[0])
      }
      if let currentPath, let current = files.first(where: { $0.path == currentPath }) {
        return choice(current)
      }
      if files.allSatisfy({ sameFormat($0.format, first.format) }) {
        currentPath = files.count == 1 ? first.path : nil
        return choice(first)
      }
      currentPath = nil
      return Choice(ambiguous: true)
    }

    private func sameFormat(_ a: SourceFileFormat, _ b: SourceFileFormat) -> Bool {
      a.sampleRate == b.sampleRate && a.bitDepth == b.bitDepth && a.channels == b.channels
    }
  }

  /// Paths and read offsets of regular files `pid` has open. Same-user processes only;
  /// a protected process yields an empty list, never an error the UI must interpret.
  static func openFiles(pid: Int32) -> [(path: String, offset: Int64)] {
    guard pid > 0 else { return [] }
    let stride = MemoryLayout<proc_fdinfo>.stride
    let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard needed > 0 else { return [] }
    // Headroom for descriptors opened between the two calls.
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
    let used = fds.withUnsafeMutableBytes { raw in
      proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
    }
    guard used > 0 else { return [] }
    var result: [(path: String, offset: Int64)] = []
    for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
      var info = vnode_fdinfowithpath()
      let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
      guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
        continue
      }
      let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
      }
      guard isCandidate(path: path) else { continue }
      result.append((path, info.pfi.fi_offset))
      if result.count >= maximumFiles { break }
    }
    return result
  }

  /// Reads the container header through Core Audio (read-only). `nil` when the file
  /// cannot be opened or describes no usable audio stream.
  static func readFormat(path: String) -> SourceFileFormat? {
    var file: AudioFileID?
    let url = URL(fileURLWithPath: path) as CFURL
    guard AudioFileOpenURL(url, .readPermission, 0, &file) == noErr, let file else { return nil }
    defer { AudioFileClose(file) }
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format) == noErr,
      format.mSampleRate.isFinite, format.mSampleRate > 0, format.mChannelsPerFrame > 0
    else { return nil }
    var sourceDepth: Int32 = 0
    size = UInt32(MemoryLayout<Int32>.size)
    let depthStatus = AudioFileGetProperty(
      file, kAudioFilePropertySourceBitDepth, &size, &sourceDepth)
    return SourceFileFormat(
      fileName: (path as NSString).lastPathComponent, sampleRate: format.mSampleRate,
      bitDepth: bitDepth(of: format, sourceBitDepth: depthStatus == noErr ? sourceDepth : nil),
      channels: Int(format.mChannelsPerFrame))
  }
}

/// Polls the routed client's open audio files about once a second on a utility queue.
/// Read-only: no playback, routing or file changes; file contents beyond the header
/// are never read, and no paths are logged or persisted.
final class SourceFileMonitor: SourceFileMonitoring, Sendable {
  typealias Lister = @Sendable (Int32) -> [(path: String, offset: Int64)]
  typealias FormatReader = @Sendable (String) -> SourceFileFormat?

  private struct CachedFormat {
    var size: Int64
    var modified: Date?
    var format: SourceFileFormat?
  }

  private struct State {
    var generation: UInt64 = 0
    var timer: DispatchSourceTimer?
    var selection = SourceFileInspector.Selection()
    var cache: [String: CachedFormat] = [:]
    var lastObservation: SourceFileObservation?
  }

  private let state = Mutex(State())
  private let queue = DispatchQueue(label: "com.local.downmix.source-files", qos: .utility)
  private let lister: Lister
  private let formatReader: FormatReader
  private let interval: DispatchTimeInterval

  init(
    lister: @escaping Lister = SourceFileInspector.openFiles,
    formatReader: @escaping FormatReader = SourceFileInspector.readFormat,
    interval: DispatchTimeInterval = .seconds(1)
  ) {
    self.lister = lister
    self.formatReader = formatReader
    self.interval = interval
  }

  func start(
    source: AudioPlaybackSource, report: @escaping @Sendable (SourceFileObservation) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    state.withLock { state in
      state.timer?.cancel()
      state.generation &+= 1
      state.selection = SourceFileInspector.Selection()
      state.lastObservation = nil
      let generation = state.generation
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
      timer.setEventHandler { [weak self] in
        self?.poll(source: source, generation: generation, report: report)
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
    source: AudioPlaybackSource, generation: UInt64,
    report: @escaping @Sendable (SourceFileObservation) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard isCurrent(generation) else { return }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let listed = source.id > 0 && source.id != ownPID ? lister(source.id) : []
    var files: [SourceFileInspector.OpenFile] = []
    for entry in listed.prefix(SourceFileInspector.maximumFiles) {
      guard let format = cachedFormat(path: entry.path) else { continue }
      files.append(.init(path: entry.path, offset: entry.offset, format: format))
    }
    let observation: SourceFileObservation? = state.withLock { state in
      guard state.generation == generation, state.timer != nil else { return nil }
      let choice = state.selection.choose(files)
      let observation = SourceFileObservation(
        sourcePID: source.id, format: choice.format, isAmbiguous: choice.ambiguous,
        isIdle: choice.idle)
      guard state.lastObservation != observation else { return nil }
      state.lastObservation = observation
      return observation
    }
    guard let observation else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isCurrent(generation) else { return }
      report(observation)
    }
  }

  /// Header reads are cached per path, size and modification date.
  private func cachedFormat(path: String) -> SourceFileFormat? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    let modified = attributes?[.modificationDate] as? Date
    if let cached = state.withLock({ $0.cache[path] }), cached.size == size,
      cached.modified == modified
    {
      return cached.format
    }
    let format = formatReader(path)
    state.withLock { state in
      if state.cache.count >= 64 { state.cache.removeAll(keepingCapacity: true) }
      state.cache[path] = CachedFormat(size: size, modified: modified, format: format)
    }
    return format
  }
}
