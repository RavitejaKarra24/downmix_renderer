import AppKit
import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
  let description: String
}

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw CheckFailure(description: message) }
}

@MainActor
private final class Fixture {
  let source = MeterSource()
  var now: TimeInterval = 10
  lazy var view = DownmixMeterNSView(source: source, currentTime: { [unowned self] in now })

  static let hot = MeterSnapshot(
    inputPeaksDb: [Float](repeating: -3, count: BedChannel.allCases.count),
    outputPeakLDb: 2, outputPeakRDb: 1, clipL: true, clipR: true)

  init(reduced: Bool = false) {
    view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
    view.meteringCheckSetReducedMotion(reduced)
    view.meteringCheckSetVisible(true)
  }

  func tick(_ duration: TimeInterval = 1.0 / 30.0) {
    now += duration
    view.meteringCheckTimer?.fire()
  }

  func warm() {
    source.update(Self.hot)
    for _ in 0..<30 {
      if view.meteringCheckTimer == nil { break }
      tick()
    }
  }

  func resetIntent() {
    source.reset()
  }

  func requireEmpty() throws {
    try require(
      view.meteringCheckDisplayed == .empty, "Reset must immediately clear displayed/clip state")
    try require(
      view.meteringCheckHeldLevels.allSatisfy { $0 == -120 },
      "Reset must clear all 16 bed and both stereo peak holds")
    try require(
      view.meteringCheckHoldDeadlines.allSatisfy { $0 == 0 }, "Reset must clear hold deadlines")
    try require(
      view.accessibilityValue() as? String == "Left silent, right silent",
      "Reset clears accessible clipping")
    try require(view.meteringCheckTimer == nil, "Empty reset must suspend repaint timer")
  }
}

@main
private struct MeteringChecks {
  @MainActor
  static func main() {
    do {
      // Actual NSView, MeterSource, NotificationCenter and Timer objects. No
      // audio engine, preferences, routes, windows or system settings are used.
      _ = NSApplication.shared
      for reduced in [false, true] {
        try resetChecks(reduced: reduced)
        try runningSilenceChecks(reduced: reduced)
        try visibilityAndSourceChecks(reduced: reduced)
      }
      try sanitizationChecks()
      try sustainedPeakChecks()
      print(
        "PASS native metering: reset/clip/hold, running silence, timer settlement/wake, visibility/rebind, sanitization"
      )
      print(
        "Window occlusion and system Reduce Motion are simulated at the native view boundary; not hardware/visual qualification."
      )
    } catch {
      FileHandle.standardError.write(Data("Metering checks FAILED: \(error)\n".utf8))
      exit(1)
    }
  }

  @MainActor
  private static func resetChecks(reduced: Bool) throws {
    let fixture = Fixture(reduced: reduced)
    let view = fixture.view
    defer { view.stop() }
    try require(view.meteringCheckTimer == nil, "Initially silent view must not schedule frames")
    fixture.warm()
    try require(
      view.meteringCheckDisplayed.clipL && view.meteringCheckDisplayed.clipR,
      "Fixture must display clipping")
    try require(view.meteringCheckHeldLevels.allSatisfy { $0 > -6 }, "Fixture must fill every hold")
    // Running silence has already made the source empty before the explicit
    // inactive event. Reset MUST bypass source snapshot equality deduplication.
    fixture.source.update(.empty)
    try require(view.meteringCheckTimer != nil, "Silence starts release rather than reset")
    let timer = view.meteringCheckTimer
    fixture.resetIntent()
    try fixture.requireEmpty()
    try require(timer?.isValid == false, "Reset must invalidate the previous Timer")
    let frames = view.meteringCheckFrameCount
    for _ in 0..<300 { fixture.tick() }
    timer?.fire()
    RunLoop.main.run(until: Date().addingTimeInterval(0.12))
    try require(
      view.meteringCheckFrameCount == frames, "Stopped view must perform zero repaint callbacks")
    fixture.resetIntent()
    try fixture.requireEmpty()
    fixture.source.update(Fixture.hot)
    try require(view.meteringCheckTimer != nil || reduced, "New activity wakes settled view")
    fixture.tick()
    try require(
      view.meteringCheckDisplayed.outputPeakLDb > -120, "New activity displays after reset")
    view.meteringCheckSetVisible(false)
    fixture.resetIntent()
    try fixture.requireEmpty()
    print(
      "PASS immediate inactive reset, repeated empty intent, zero stopped work, restart (reduced=\(reduced))"
    )
  }

  @MainActor
  private static func runningSilenceChecks(reduced: Bool) throws {
    let fixture = Fixture(reduced: reduced)
    let view = fixture.view
    defer { view.stop() }
    fixture.warm()
    let displayed = view.meteringCheckDisplayed
    let holds = view.meteringCheckHeldLevels
    let deadlines = view.meteringCheckHoldDeadlines
    try require(view.meteringCheckTimer == nil, "Stable hot targets should also settle")
    fixture.source.update(.empty)
    try require(
      view.meteringCheckHeldLevels == holds, "Silent notification must not reset peak history")
    try require(
      view.meteringCheckHoldDeadlines == deadlines, "Silent notification must not restart holds")
    if !reduced {
      try require(
        view.meteringCheckDisplayed == displayed,
        "Silent notification must preserve release history")
    }
    let timer = view.meteringCheckTimer
    try require(timer != nil, "Silent target wakes the stopped timer for release/hold decay")
    fixture.tick(0.1)
    try require(view.meteringCheckHeldLevels == holds, "Holds persist through their deadline")
    if !reduced {
      try require(
        view.meteringCheckDisplayed.outputPeakLDb > -120,
        "Normal silence must release, not jump to empty")
    }
    for _ in 0..<200 { fixture.tick(0.1) }
    try require(
      view.meteringCheckDisplayed == .empty, "Release must settle exactly at silent targets")
    try require(
      view.meteringCheckHeldLevels.allSatisfy { $0 == -120 }, "Holds must eventually settle")
    try require(
      view.meteringCheckTimer == nil && timer?.isValid == false, "Settled silence invalidates Timer"
    )
    let frames = view.meteringCheckFrameCount
    fixture.source.update(.empty)
    for _ in 0..<200 { fixture.tick() }
    try require(view.meteringCheckFrameCount == frames, "Settled silence performs no frame work")
    // Clip-only activity is not overlooked by the pending-work calculation.
    var clippedSilence = MeterSnapshot.empty
    clippedSilence.clipR = true
    fixture.source.update(clippedSilence)
    fixture.tick()
    try require(view.meteringCheckDisplayed.clipR, "Clip-only change must reach display")
    print("PASS running silence preserves history and finitely settles (reduced=\(reduced))")
  }

  @MainActor
  private static func visibilityAndSourceChecks(reduced: Bool) throws {
    let fixture = Fixture(reduced: reduced)
    let view = fixture.view
    defer { view.stop() }
    fixture.warm()
    fixture.source.update(.empty)
    let displayed = view.meteringCheckDisplayed
    let holds = view.meteringCheckHeldLevels
    let timer = view.meteringCheckTimer
    view.meteringCheckSetVisible(false)
    try require(
      view.meteringCheckTimer == nil && timer?.isValid == false, "Hidden view suspends timer")
    fixture.source.update(.empty)
    try require(view.meteringCheckHeldLevels == holds, "Hidden normal silence preserves holds")
    try require(view.meteringCheckDisplayed == displayed, "Hidden view retains release history")
    view.meteringCheckSetVisible(true)
    try require(view.meteringCheckTimer != nil, "Window wake resumes unsettled decay")
    try require(view.meteringCheckHeldLevels == holds, "Window wake does not reset holds")
    view.stop()
    try require(view.meteringCheckTimer == nil, "Dismantling stops timer")
    var restarted = Fixture.hot
    restarted.outputPeakLDb = -12
    restarted.clipL = false
    fixture.source.update(restarted)
    view.start()
    try require(view.meteringCheckTimer != nil, "Start resamples current source")
    fixture.tick()
    try require(
      !view.meteringCheckDisplayed.clipL, "Start consumes changes missed while unobserved")
    view.stop()
    fixture.source.reset()
    view.start()
    try fixture.requireEmpty()
    let replacement = MeterSource()
    view.setSource(replacement)
    try fixture.requireEmpty()
    fixture.source.update(.empty)
    fixture.source.update(Fixture.hot)
    try require(view.meteringCheckDisplayed == .empty, "Old source is no longer observed")
    replacement.update(Fixture.hot)
    fixture.tick()
    try require(view.meteringCheckDisplayed.clipL, "Replacement source wakes and updates view")
    print("PASS visibility, observation restart and source rebinding (reduced=\(reduced))")
  }

  @MainActor
  private static func sustainedPeakChecks() throws {
    for reduced in [false, true] {
      let fixture = Fixture(reduced: reduced)
      let view = fixture.view
      defer { view.stop() }
      fixture.warm()
      let holds = view.meteringCheckHeldLevels
      let frames = view.meteringCheckFrameCount
      fixture.now += 5
      try require(
        view.meteringCheckFrameCount == frames, "Sustained settled peak performs no frame work")
      fixture.source.update(.empty)
      try require(
        view.meteringCheckHoldDeadlines.allSatisfy { $0 > fixture.now },
        "A sustained peak still gets its full hold when a sleeping timer wakes")
      fixture.tick(0.1)
      try require(
        view.meteringCheckHeldLevels == holds,
        "Sustained peak hold must not expire while timer slept")
    }
  }

  @MainActor
  private static func sanitizationChecks() throws {
    for reduced in [false, true] {
      let fixture = Fixture(reduced: reduced)
      defer { fixture.view.stop() }
      fixture.source.update(
        MeterSnapshot(
          inputPeaksDb: [.nan], outputPeakLDb: .infinity,
          outputPeakRDb: -.infinity, clipL: false, clipR: false))
      fixture.tick()
      try require(
        fixture.view.meteringCheckDisplayed == .empty,
        "Invalid/short snapshots normalize to silence")
      try require(
        fixture.view.meteringCheckTimer == nil,
        "Invalid samples cannot leave endless animation work")
    }
  }
}
