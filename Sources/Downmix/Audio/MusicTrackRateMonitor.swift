import AppKit
import Foundation

/// One reading from Music.app.
enum MusicRateObservation: Equatable, Sendable {
  case playing(rate: Double, track: String)
  /// A confirmed paused/stopped player; a real playback-episode boundary.
  case idle
  /// The player may still be playing, but source metadata is missing/unusable.
  case metadataUnavailable
  case failure(MusicRateFailure)

  var rate: Double? {
    if case .playing(let rate, _) = self { return rate }
    return nil
  }
}

enum MusicRateFailure: Equatable, Sendable {
  case musicNotRunning
  case automationDenied
  /// AppleScript error number; the text is not stable across macOS releases.
  case scriptFailed(Int)
}

/// Reports the current Music.app track's sample rate. Implemented by
/// `MusicTrackRateMonitor` in the app; checks inject their own monitor.
/// `start`/`stop` are called from the main actor; reports arrive on the main queue.
protocol MusicRateMonitoring: AnyObject {
  func start(report: @escaping @Sendable (MusicRateObservation) -> Void)
  func stop()
}

/// Reads Music.app's current track rate with AppleScript so the input device can be
/// matched to it. Music never exposes a source rate through Core Audio, so this is the
/// only public route; a file opened outside the library may not report one at all.
///
/// AppleScript runs on one utility queue (it can block while Music is busy), never
/// launches Music, and polls rarely while idle. Control of Music requires the user's
/// Automation permission; failure is reported, never fatal.
final class MusicTrackRateMonitor: MusicRateMonitoring, @unchecked Sendable {
  private static let playingInterval: TimeInterval = 2
  private static let idleInterval: TimeInterval = 20
  private static let musicBundleIdentifier = "com.apple.Music"

  private let queue = DispatchQueue(label: "com.local.downmix.music-rate", qos: .utility)
  private let scriptSource = """
    tell application "Music"
      if player state is not playing then return "paused"
      if not (exists current track) then return "no track"
      set currentItem to current track
      return ((sample rate of currentItem) as text) & "|" & (name of currentItem)
    end tell
    """

  // Queue-confined state.
  private var timer: DispatchSourceTimer?
  private var script: NSAppleScript?
  private var report: (@Sendable (MusicRateObservation) -> Void)?
  private var lastObservation: MusicRateObservation?
  private var isChecking = false
  private var needsAnotherCheck = false
  private var currentInterval: TimeInterval = 0

  // Main-actor-confined state.
  private var notificationObserver: NSObjectProtocol?
  private var isMonitoring = false

  func start(report: @escaping @Sendable (MusicRateObservation) -> Void) {
    guard !isMonitoring else { return }
    isMonitoring = true
    notificationObserver = DistributedNotificationCenter.default.addObserver(
      forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.requestImmediateCheck() }
    }
    queue.async { [self] in
      self.report = report
      guard let script = NSAppleScript(source: scriptSource) else { return }
      self.script = script
      schedule(interval: Self.playingInterval, immediately: true)
      check()
    }
  }

  func stop() {
    guard isMonitoring else { return }
    isMonitoring = false
    if let notificationObserver {
      DistributedNotificationCenter.default.removeObserver(notificationObserver)
    }
    notificationObserver = nil
    queue.async { [self] in
      timer?.cancel()
      timer = nil
      script = nil
      report = nil
      lastObservation = nil
      currentInterval = 0
      needsAnotherCheck = false
    }
  }

  /// Resets the poll timer instantly on a Music player event (track change, play, pause).
  private func requestImmediateCheck() {
    queue.async { [self] in
      if isChecking {
        needsAnotherCheck = true
      } else {
        check()
      }
    }
  }

  private func schedule(interval: TimeInterval, immediately: Bool = false) {
    guard interval != currentInterval || immediately else { return }
    currentInterval = interval
    timer?.cancel()
    let created = DispatchSource.makeTimerSource(queue: queue)
    created.schedule(deadline: .now() + (immediately ? 0.3 : interval), repeating: interval)
    created.setEventHandler { [weak self] in self?.check() }
    created.resume()
    timer = created
  }

  /// Queue-confined. Sends at most one outstanding AppleScript call.
  private func check() {
    guard !isChecking else {
      needsAnotherCheck = true
      return
    }
    isChecking = true
    let observation = readObservation()
    isChecking = false
    finish(observation)
    if needsAnotherCheck {
      needsAnotherCheck = false
      check()
    }
  }

  private func finish(_ observation: MusicRateObservation) {
    defer { lastObservation = observation }
    schedule(interval: observation.rate == nil ? Self.idleInterval : Self.playingInterval)
    guard observation != lastObservation else { return }
    let report = report
    DispatchQueue.main.async {
      MainActor.assumeIsolated { report?(observation) }
    }
  }

  private func readObservation() -> MusicRateObservation {
    guard
      !NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleIdentifier)
        .isEmpty
    else { return .failure(.musicNotRunning) }
    guard let script else { return .failure(.scriptFailed(0)) }

    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if let error {
      let number = (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue ?? 0
      // -1743 is errAEEventNotPermitted: the user refused Automation access.
      return number == -1743 ? .failure(.automationDenied) : .failure(.scriptFailed(number))
    }
    return Self.parse(result.stringValue)
  }

  /// `"96000|Track name"`, `"paused"` or `"no track"`. Exposed for deterministic checks.
  static func parse(_ output: String?) -> MusicRateObservation {
    guard let output else { return .metadataUnavailable }
    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if text == "paused" { return .idle }
    if text.isEmpty || text.hasPrefix("no track") { return .metadataUnavailable }
    let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
    guard let rate = Double(String(parts[0]).trimmingCharacters(in: .whitespaces)),
      rate.isFinite, rate > 0
    else { return .metadataUnavailable }
    let track = parts.count > 1 ? String(parts[1]) : ""
    return .playing(rate: rate, track: track)
  }
}
