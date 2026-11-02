import AppKit
import SwiftUI

/// AppKit-backed metering surface with smooth ballistics and peak hold.
///
/// Drawing stays inside AppKit so frequent meter updates do not invalidate the
/// surrounding SwiftUI layout.
struct NativeMeteringView: NSViewRepresentable {
  let source: MeterSource

  func makeNSView(context: Context) -> DownmixMeterNSView {
    DownmixMeterNSView(source: source)
  }

  func updateNSView(_ nsView: DownmixMeterNSView, context: Context) {
    nsView.setSource(source)
  }

  static func dismantleNSView(_ nsView: DownmixMeterNSView, coordinator: Void) {
    nsView.stop()
  }
}

@MainActor
final class DownmixMeterNSView: NSView {
  @MainActor
  private struct PeakHold {
    var db: Float = DownmixMeterNSView.minimumDB
    var holdUntil: TimeInterval = 0

    mutating func reset(to db: Float, now: TimeInterval) {
      self.db = DownmixMeterNSView.sanitized(db)
      holdUntil =
        self.db <= DownmixMeterNSView.minimumDB
        ? 0 : now + DownmixMeterNSView.peakHoldDuration
    }

    mutating func update(sample: Float, now: TimeInterval, deltaTime: TimeInterval) {
      let sample = DownmixMeterNSView.sanitized(sample)
      if sample >= db {
        db = sample
        holdUntil = now + DownmixMeterNSView.peakHoldDuration
      } else if now > holdUntil {
        let decay = Float(deltaTime) * DownmixMeterNSView.peakReleaseDBPerSecond
        db = max(sample, db - decay)
      }
    }
  }

  private static let minimumDB: Float = -120
  private static let meterFloorDB: Float = -60
  private static let attackTime: TimeInterval = 0.025
  private static let releaseTime: TimeInterval = 0.38
  private static let peakHoldDuration: TimeInterval = 0.9
  private static let peakReleaseDBPerSecond: Float = 30
  private static let standardFrameInterval: TimeInterval = 1.0 / 30.0
  private static let reducedMotionFrameInterval: TimeInterval = 0.1
  private static let settledToleranceDB: Float = 0.01

  private(set) var source: MeterSource
  private var targetSnapshot: MeterSnapshot
  private var displayedSnapshot: MeterSnapshot
  private var lastResetRevision: UInt64
  private var bedPeakHolds = [PeakHold](
    repeating: PeakHold(),
    count: BedChannel.allCases.count
  )
  private var leftPeakHold = PeakHold()
  private var rightPeakHold = PeakHold()
  private var animationTimer: Timer?
  private var lastFrameTime: TimeInterval
  private var observing = false
  private var shouldReduceMotion: Bool
  private weak var observedWindow: NSWindow?
  private let currentTime: () -> TimeInterval

  #if METERING_CHECKS
    private var meteringCheckVisibility: Bool?
    private(set) var meteringCheckFrameCount = 0
  #endif

  override var isFlipped: Bool { true }
  // Cards are drawn with rounded corners over the window backdrop.
  override var isOpaque: Bool { false }

  init(
    source: MeterSource,
    currentTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    let snapshot = source.snapshot()
    self.currentTime = currentTime
    self.source = source
    targetSnapshot = snapshot
    displayedSnapshot = snapshot
    lastResetRevision = source.resetRevision()
    lastFrameTime = currentTime()
    shouldReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    super.init(frame: .zero)

    wantsLayer = true
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("9.1.6 bed activity and stereo output meters")
    resetBallistics(to: snapshot)
    updateAccessibilityValue()
    start()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 460, height: 520)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    if let observedWindow {
      removeWindowObservers(from: observedWindow)
    }
    observedWindow = window
    if observing, let window {
      observeWindow(window)
    }
    updateAnimationTimerActivity()
  }

  /// Rebinds notification observation without leaving an observer attached to
  /// the previous source. A new source starts with its own current levels.
  func setSource(_ newSource: MeterSource) {
    guard source !== newSource else { return }

    if observing {
      NotificationCenter.default.removeObserver(
        self,
        name: .downmixMetersDidChange,
        object: source
      )
    }

    source = newSource
    lastResetRevision = newSource.resetRevision()
    let snapshot = newSource.snapshot()
    targetSnapshot = snapshot
    resetBallistics(to: snapshot)
    updateAccessibilityValue()

    if observing {
      observeMeterSource()
    }
    updateAnimationTimerActivity()
    needsDisplay = true
  }

  func start() {
    guard !observing else { return }
    observing = true
    observeMeterSource()
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(accessibilityDisplayOptionsDidChange),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil
    )
    if let window {
      observedWindow = window
      observeWindow(window)
    }
    updateAnimationTimerActivity()
  }

  func stop() {
    guard observing else { return }
    NotificationCenter.default.removeObserver(
      self,
      name: .downmixMetersDidChange,
      object: source
    )
    NSWorkspace.shared.notificationCenter.removeObserver(
      self,
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil
    )
    if let observedWindow {
      removeWindowObservers(from: observedWindow)
    }
    observedWindow = nil
    animationTimer?.invalidate()
    animationTimer = nil
    observing = false
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    let gap: CGFloat = 16
    let meterHeight = min(150, max(132, bounds.height * 0.22))
    let bedRect = NSRect(
      x: 0,
      y: 0,
      width: bounds.width,
      height: max(0, bounds.height - meterHeight - gap)
    )
    let meterRect = NSRect(
      x: 0,
      y: bedRect.maxY + gap,
      width: bounds.width,
      height: meterHeight
    )

    drawCard(bedRect)
    drawBed(in: bedRect)
    drawCard(meterRect)
    drawStereoMeters(in: meterRect)
  }

  private func observeMeterSource() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(meterSourceDidChange(_:)),
      name: .downmixMetersDidChange,
      object: source
    )
  }

  @objc private func meterSourceDidChange(_ notification: Notification) {
    receiveSourceSnapshot()
    updateAnimationTimerActivity()
  }

  private func receiveSourceSnapshot() {
    // A durable generation also catches Stop/error while the view was unobserved.
    // Ordinary running silence changes the snapshot but never this reset generation.
    let resetRevision = source.resetRevision()
    let resetDisplay = resetRevision != lastResetRevision
    lastResetRevision = resetRevision
    receiveSnapshot(source.snapshot(), resetDisplay: resetDisplay)
  }

  private func receiveSnapshot(_ snapshot: MeterSnapshot, resetDisplay: Bool = false) {
    if !resetDisplay, snapshot != targetSnapshot {
      // A settled target remained current while its timer slept. Account for
      // that sample up to this transition, preserving a full hold after a
      // sustained peak drops without running idle repaint callbacks.
      updatePeakHolds(now: currentTime(), deltaTime: 0)
    }
    targetSnapshot = snapshot
    if resetDisplay {
      // Clear levels, holds AND clip flags synchronously, even without a timer.
      resetBallistics(to: .empty)
      needsDisplay = true
    } else if shouldReduceMotion {
      displayedSnapshot = Self.sanitizedSnapshot(snapshot)
      needsDisplay = true
    }
    updateAccessibilityValue()
  }

  @objc private func accessibilityDisplayOptionsDidChange() {
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    guard reduceMotion != shouldReduceMotion else { return }
    shouldReduceMotion = reduceMotion
    if reduceMotion {
      displayedSnapshot = Self.sanitizedSnapshot(targetSnapshot)
    }
    updateAnimationTimerActivity(forceRestart: true)
    needsDisplay = true
  }

  @objc private func windowVisibilityDidChange() {
    updateAnimationTimerActivity()
  }

  private func observeWindow(_ window: NSWindow) {
    let notifications: [Notification.Name] = [
      NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification,
      NSWindow.didChangeOcclusionStateNotification,
    ]
    for notification in notifications {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(windowVisibilityDidChange),
        name: notification,
        object: window
      )
    }
  }

  private func removeWindowObservers(from window: NSWindow) {
    NotificationCenter.default.removeObserver(
      self,
      name: NSWindow.didMiniaturizeNotification,
      object: window
    )
    NotificationCenter.default.removeObserver(
      self,
      name: NSWindow.didDeminiaturizeNotification,
      object: window
    )
    NotificationCenter.default.removeObserver(
      self,
      name: NSWindow.didChangeOcclusionStateNotification,
      object: window
    )
  }

  private func updateAnimationTimerActivity(forceRestart: Bool = false) {
    guard observing, isWindowVisibleForMetering else {
      animationTimer?.invalidate()
      animationTimer = nil
      return
    }

    // Refresh on window/start wake as well as notifications. Do not discard
    // release/hold history just because the timer was asleep during silence.
    receiveSourceSnapshot()
    guard hasPendingAnimation else {
      animationTimer?.invalidate()
      animationTimer = nil
      return
    }

    guard forceRestart || animationTimer == nil else { return }
    configureAnimationTimer()
  }

  private var isWindowVisibleForMetering: Bool {
    #if METERING_CHECKS
      if let meteringCheckVisibility { return meteringCheckVisibility }
    #endif
    guard let window, window.isVisible, !window.isMiniaturized else { return false }
    return window.occlusionState.contains(.visible)
  }

  private func configureAnimationTimer() {
    animationTimer?.invalidate()

    let interval =
      shouldReduceMotion
      ? Self.reducedMotionFrameInterval
      : Self.standardFrameInterval
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.advanceAnimation()
      }
    }
    timer.tolerance = interval * 0.12
    RunLoop.main.add(timer, forMode: .common)
    animationTimer = timer
    lastFrameTime = currentTime()
  }

  private func advanceAnimation() {
    #if METERING_CHECKS
      meteringCheckFrameCount += 1
    #endif
    // Sampling here also catches level changes coalesced between frames.
    receiveSourceSnapshot()

    let now = currentTime()
    let deltaTime = min(0.1, max(0, now - lastFrameTime))
    lastFrameTime = now

    guard isWindowVisibleForMetering else {
      updateAnimationTimerActivity()
      return
    }

    if shouldReduceMotion {
      displayedSnapshot = Self.sanitizedSnapshot(targetSnapshot)
    } else {
      interpolateDisplayedLevels(deltaTime: deltaTime)
    }
    updatePeakHolds(now: now, deltaTime: deltaTime)
    settleBallistics()
    needsDisplay = true
    updateAnimationTimerActivity()
  }

  /// Include the numeric stereo readout, which remains visible below -60 dB.
  private var hasPendingAnimation: Bool {
    for index in bedPeakHolds.indices {
      let target = bedTarget(at: index)
      let displayed =
        index < displayedSnapshot.inputPeaksDb.count
        ? displayedSnapshot.inputPeaksDb[index] : Self.minimumDB
      if displayed != target || bedPeakHolds[index].db != target { return true }
    }
    return displayedSnapshot.outputPeakLDb != Self.sanitized(targetSnapshot.outputPeakLDb)
      || displayedSnapshot.outputPeakRDb != Self.sanitized(targetSnapshot.outputPeakRDb)
      || leftPeakHold.db != Self.sanitized(targetSnapshot.outputPeakLDb)
      || rightPeakHold.db != Self.sanitized(targetSnapshot.outputPeakRDb)
      || displayedSnapshot.clipL != targetSnapshot.clipL
      || displayedSnapshot.clipR != targetSnapshot.clipR
  }

  private func bedTarget(at index: Int) -> Float {
    Self.sanitized(
      index < targetSnapshot.inputPeaksDb.count
        ? targetSnapshot.inputPeaksDb[index] : Self.minimumDB)
  }

  /// Exponential release never reaches its target exactly. Snap sub-readout
  /// differences only, allowing finite settlement without losing peak history.
  private func settleBallistics() {
    func settled(_ value: Float, target: Float) -> Float {
      let target = Self.sanitized(target)
      return abs(value - target) <= Self.settledToleranceDB ? target : value
    }
    for index in bedPeakHolds.indices {
      let target = bedTarget(at: index)
      displayedSnapshot.inputPeaksDb[index] = settled(
        displayedSnapshot.inputPeaksDb[index], target: target)
      bedPeakHolds[index].db = settled(bedPeakHolds[index].db, target: target)
    }
    displayedSnapshot.outputPeakLDb = settled(
      displayedSnapshot.outputPeakLDb, target: targetSnapshot.outputPeakLDb)
    displayedSnapshot.outputPeakRDb = settled(
      displayedSnapshot.outputPeakRDb, target: targetSnapshot.outputPeakRDb)
    leftPeakHold.db = settled(leftPeakHold.db, target: targetSnapshot.outputPeakLDb)
    rightPeakHold.db = settled(rightPeakHold.db, target: targetSnapshot.outputPeakRDb)
  }

  private func interpolateDisplayedLevels(deltaTime: TimeInterval) {
    let channelCount = BedChannel.allCases.count
    if displayedSnapshot.inputPeaksDb.count != channelCount {
      displayedSnapshot.inputPeaksDb = [Float](
        repeating: Self.minimumDB,
        count: channelCount
      )
    }

    for index in 0..<channelCount {
      let target =
        index < targetSnapshot.inputPeaksDb.count
        ? targetSnapshot.inputPeaksDb[index]
        : Self.minimumDB
      displayedSnapshot.inputPeaksDb[index] = ballistics(
        from: displayedSnapshot.inputPeaksDb[index],
        to: target,
        deltaTime: deltaTime
      )
    }

    displayedSnapshot.outputPeakLDb = ballistics(
      from: displayedSnapshot.outputPeakLDb,
      to: targetSnapshot.outputPeakLDb,
      deltaTime: deltaTime
    )
    displayedSnapshot.outputPeakRDb = ballistics(
      from: displayedSnapshot.outputPeakRDb,
      to: targetSnapshot.outputPeakRDb,
      deltaTime: deltaTime
    )
    displayedSnapshot.clipL = targetSnapshot.clipL
    displayedSnapshot.clipR = targetSnapshot.clipR
  }

  private func ballistics(from currentValue: Float, to targetValue: Float, deltaTime: TimeInterval)
    -> Float
  {
    let current = Self.sanitized(currentValue)
    let target = Self.sanitized(targetValue)
    let timeConstant = target > current ? Self.attackTime : Self.releaseTime
    let interpolation = 1 - exp(-deltaTime / timeConstant)
    return current + (target - current) * Float(interpolation)
  }

  private func updatePeakHolds(now: TimeInterval, deltaTime: TimeInterval) {
    for index in bedPeakHolds.indices {
      let sample =
        index < targetSnapshot.inputPeaksDb.count
        ? targetSnapshot.inputPeaksDb[index]
        : Self.minimumDB
      bedPeakHolds[index].update(sample: sample, now: now, deltaTime: deltaTime)
    }
    leftPeakHold.update(
      sample: targetSnapshot.outputPeakLDb,
      now: now,
      deltaTime: deltaTime
    )
    rightPeakHold.update(
      sample: targetSnapshot.outputPeakRDb,
      now: now,
      deltaTime: deltaTime
    )
  }

  private static func sanitizedSnapshot(_ snapshot: MeterSnapshot) -> MeterSnapshot {
    var levels = [Float](repeating: minimumDB, count: BedChannel.allCases.count)
    for index in levels.indices where index < snapshot.inputPeaksDb.count {
      levels[index] = sanitized(snapshot.inputPeaksDb[index])
    }
    return MeterSnapshot(
      inputPeaksDb: levels,
      outputPeakLDb: sanitized(snapshot.outputPeakLDb),
      outputPeakRDb: sanitized(snapshot.outputPeakRDb),
      clipL: snapshot.clipL,
      clipR: snapshot.clipR)
  }

  private func resetBallistics(to snapshot: MeterSnapshot) {
    let now = currentTime()
    displayedSnapshot = Self.sanitizedSnapshot(snapshot)
    targetSnapshot = snapshot

    for index in bedPeakHolds.indices {
      bedPeakHolds[index].reset(to: displayedSnapshot.inputPeaksDb[index], now: now)
    }
    leftPeakHold.reset(to: snapshot.outputPeakLDb, now: now)
    rightPeakHold.reset(to: snapshot.outputPeakRDb, now: now)
  }

  #if METERING_CHECKS
    // Exercise actual native state and Timer lifecycle without depending on
    // WindowServer occlusion or wall-clock sleeps. Absent from app builds.
    var meteringCheckDisplayed: MeterSnapshot { displayedSnapshot }
    var meteringCheckHeldLevels: [Float] {
      bedPeakHolds.map(\.db) + [leftPeakHold.db, rightPeakHold.db]
    }
    var meteringCheckHoldDeadlines: [TimeInterval] {
      bedPeakHolds.map(\.holdUntil) + [leftPeakHold.holdUntil, rightPeakHold.holdUntil]
    }
    var meteringCheckTimer: Timer? { animationTimer }

    func meteringCheckSetVisible(_ visible: Bool) {
      meteringCheckVisibility = visible
      updateAnimationTimerActivity()
    }

    func meteringCheckSetReducedMotion(_ reduced: Bool) {
      shouldReduceMotion = reduced
      receiveSnapshot(source.snapshot())
      updateAnimationTimerActivity(forceRestart: true)
    }
  #endif

  private static func sanitized(_ db: Float) -> Float {
    guard db.isFinite else { return minimumDB }
    return min(6, max(minimumDB, db))
  }

  // MARK: - Surfaces

  private static let cardRadius: CGFloat = 18
  private static let cardPadding: CGFloat = 20

  private func drawCard(_ rect: NSRect) {
    guard rect.width > 1, rect.height > 1 else { return }
    let path = NSBezierPath(
      roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
      xRadius: Self.cardRadius,
      yRadius: Self.cardRadius
    )
    if let gradient = NSGradient(
      starting: DownmixTheme.nsPanelTop,
      ending: DownmixTheme.nsPanelBottom
    ) {
      // Flipped view: 90° runs from the top edge to the bottom edge.
      gradient.draw(in: path, angle: 90)
    } else {
      DownmixTheme.nsPanelBottom.setFill()
      path.fill()
    }
    DownmixTheme.nsCardStroke.setStroke()
    path.lineWidth = 1
    path.stroke()

    // A faint top-edge highlight gives the card a lit, glassy rim.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let rim = NSBezierPath()
    rim.move(to: NSPoint(x: rect.minX + Self.cardRadius, y: rect.minY + 1))
    rim.line(to: NSPoint(x: rect.maxX - Self.cardRadius, y: rect.minY + 1))
    DownmixTheme.nsPanelHighlight.setStroke()
    rim.lineWidth = 1
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()
  }

  // MARK: - Soundfield

  private func drawBed(in rect: NSRect) {
    guard rect.width > 200, rect.height > 200 else { return }
    let pad = Self.cardPadding

    drawText(
      "Soundfield",
      at: NSPoint(x: rect.minX + pad, y: rect.minY + 16),
      size: 15,
      weight: .semibold,
      color: DownmixTheme.nsTextPrimary,
      rounded: true
    )
    drawText(
      "9.1.6 BED  ·  TOP VIEW",
      at: NSPoint(x: rect.minX + pad, y: rect.minY + 38),
      size: 9,
      weight: .semibold,
      color: DownmixTheme.nsTextSecondary.withAlphaComponent(0.8),
      kern: 0.9
    )
    drawLegend(trailing: rect.maxX - pad, centerY: rect.minY + 27)

    let headerHeight: CGFloat = 58
    let stage = NSRect(
      x: rect.minX + pad,
      y: rect.minY + headerHeight,
      width: rect.width - pad * 2,
      height: rect.height - headerHeight - pad + 4
    )
    // Leave a lane above and below the plate for the FRONT/REAR captions.
    let radius = min(stage.width, stage.height - 36) / 2
    guard radius > 80 else { return }
    drawSoundfield(center: NSPoint(x: stage.midX, y: stage.midY), radius: radius)
  }

  private func drawLegend(trailing: CGFloat, centerY: CGFloat) {
    let items: [(String, NSColor)] = [
      ("LFE", DownmixTheme.nsLFEChannel),
      ("Height", DownmixTheme.nsHeightChannel),
      ("Bed", DownmixTheme.nsBedChannel),
    ]
    var x = trailing
    for item in items {
      let width = drawText(
        item.0,
        at: NSPoint(x: x, y: centerY),
        size: 10,
        weight: .medium,
        color: DownmixTheme.nsTextSecondary,
        rightAligned: true,
        verticallyCentered: true
      ).width
      x -= width + 6
      let dot = NSBezierPath(ovalIn: NSRect(x: x - 7, y: centerY - 3.5, width: 7, height: 7))
      item.1.setFill()
      dot.fill()
      x -= 7 + 14
    }
  }

  private func drawSoundfield(center: NSPoint, radius: CGFloat) {
    let outerRadius = radius * 0.97
    let bedRadius = radius * 0.79
    let heightRadius = radius * 0.47
    let markerRadius = min(17, max(11, radius * 0.048))
    let listenerRadius = max(17, radius * 0.085)
    let energy = BedChannel.allCases.reduce(CGFloat(0)) {
      max($0, normalizedMeterLevel(displayedLevel($1)))
    }

    // Floor plate with an ambient glow that breathes with overall activity.
    let plate = NSBezierPath(ovalIn: circleRect(center, outerRadius))
    if let floor = NSGradient(colors: [
      DownmixTheme.nsStageCenter,
      DownmixTheme.nsStageEdge,
    ]) {
      floor.draw(in: plate, relativeCenterPosition: .zero)
    }
    if let ambient = NSGradient(colors: [
      DownmixTheme.nsBedChannel.withAlphaComponent(0.03 + 0.09 * energy),
      DownmixTheme.nsBedChannel.withAlphaComponent(0),
    ]) {
      ambient.draw(in: plate, relativeCenterPosition: .zero)
    }
    DownmixTheme.nsCardStroke.setStroke()
    plate.lineWidth = 1
    plate.stroke()

    drawStereoSector(center: center, radius: bedRadius, energy: energy)
    drawGuides(
      center: center,
      outerRadius: outerRadius,
      bedRadius: bedRadius,
      heightRadius: heightRadius
    )

    // Beams converge on the listener first, so every puck sits above them.
    let placements: [(BedChannel, NSPoint, CGFloat)] = BedChannel.allCases.map { channel in
      if channel == .lfe {
        return (channel, NSPoint(x: center.x, y: center.y - radius * 0.26), markerRadius * 0.92)
      }
      let ring = channel.isHeight ? heightRadius : bedRadius
      let size = channel.isHeight ? markerRadius * 0.86 : markerRadius
      return (channel, polar(center, ring, Self.azimuth(of: channel)), size)
    }
    for (channel, point, size) in placements {
      drawBeam(
        from: point,
        to: center,
        stopRadius: listenerRadius,
        color: channelFamilyColor(channel),
        level: normalizedMeterLevel(displayedLevel(channel)),
        width: size * 1.3
      )
    }
    for (channel, point, size) in placements {
      drawSpeaker(channel, at: point, radius: size)
    }

    drawListener(at: center, radius: listenerRadius)
  }

  /// The ±30° wedge a stereo pair actually reproduces, shown as a soft fan.
  private func drawStereoSector(center: NSPoint, radius: CGFloat, energy: CGFloat) {
    let sector = NSBezierPath()
    sector.move(to: center)
    // Flipped view: −90° points to the front (top). Arcs drawn counter-clockwise
    // in model space run clockwise on screen.
    sector.appendArc(
      withCenter: center,
      radius: radius,
      startAngle: -120,
      endAngle: -60,
      clockwise: false
    )
    sector.close()
    if let fan = NSGradient(colors: [
      DownmixTheme.nsAccent.withAlphaComponent(0.05 + 0.07 * energy),
      DownmixTheme.nsAccent.withAlphaComponent(0),
    ]) {
      NSGraphicsContext.saveGraphicsState()
      sector.addClip()
      fan.draw(from: center, to: NSPoint(x: center.x, y: center.y - radius), options: [])
      NSGraphicsContext.restoreGraphicsState()
    }
  }

  private func drawGuides(
    center: NSPoint,
    outerRadius: CGFloat,
    bedRadius: CGFloat,
    heightRadius: CGFloat
  ) {
    let hairline = DownmixTheme.nsStageGuide

    // Compass ticks every 15°, emphasised every 45°.
    for step in 0..<24 {
      let degrees = CGFloat(step) * 15
      let major = step % 3 == 0
      let inner = outerRadius - (major ? 9 : 5)
      let tick = NSBezierPath()
      tick.move(to: polar(center, inner, degrees))
      tick.line(to: polar(center, outerRadius - 1.5, degrees))
      faded(hairline, major ? 1.5 : 0.8).setStroke()
      tick.lineWidth = major ? 1.2 : 0.8
      tick.lineCapStyle = .round
      tick.stroke()
    }

    // Crosshair axes, dashed and very quiet.
    let axes = NSBezierPath()
    axes.move(to: NSPoint(x: center.x, y: center.y - outerRadius + 14))
    axes.line(to: NSPoint(x: center.x, y: center.y + outerRadius - 14))
    axes.move(to: NSPoint(x: center.x - outerRadius + 14, y: center.y))
    axes.line(to: NSPoint(x: center.x + outerRadius - 14, y: center.y))
    axes.setLineDash([2, 5], count: 2, phase: 0)
    faded(hairline, 0.75).setStroke()
    axes.lineWidth = 0.8
    axes.stroke()

    // Distance rings: bed layer, height layer and the near field.
    let bedRing = NSBezierPath(ovalIn: circleRect(center, bedRadius))
    hairline.setStroke()
    bedRing.lineWidth = 1
    bedRing.stroke()

    let heightRing = NSBezierPath(ovalIn: circleRect(center, heightRadius))
    heightRing.setLineDash([3, 4], count: 2, phase: 0)
    DownmixTheme.nsHeightChannel.withAlphaComponent(0.32).setStroke()
    heightRing.lineWidth = 1
    heightRing.stroke()

    let nearRing = NSBezierPath(ovalIn: circleRect(center, heightRadius * 0.5))
    faded(hairline, 0.7).setStroke()
    nearRing.lineWidth = 0.8
    nearRing.stroke()

    // Orientation captions sit just outside the plate on the vertical axis.
    let labelColor = DownmixTheme.nsTextSecondary.withAlphaComponent(0.55)
    drawText(
      "FRONT",
      at: NSPoint(x: center.x, y: center.y - outerRadius - 15),
      size: 8,
      weight: .bold,
      color: labelColor,
      centered: true,
      kern: 1.6
    )
    drawText(
      "REAR",
      at: NSPoint(x: center.x, y: center.y + outerRadius + 5),
      size: 8,
      weight: .bold,
      color: labelColor,
      centered: true,
      kern: 1.6
    )
    drawText(
      "HEIGHT",
      at: NSPoint(x: center.x, y: center.y + heightRadius + 5),
      size: 7.5,
      weight: .bold,
      color: DownmixTheme.nsHeightChannel.withAlphaComponent(0.55),
      centered: true,
      kern: 1.4
    )
  }

  private func drawBeam(
    from point: NSPoint,
    to center: NSPoint,
    stopRadius: CGFloat,
    color: NSColor,
    level: CGFloat,
    width: CGFloat
  ) {
    guard level > 0.02 else { return }
    let dx = center.x - point.x
    let dy = center.y - point.y
    let length = hypot(dx, dy)
    guard length > stopRadius + 4 else { return }
    let ux = dx / length
    let uy = dy / length
    let end = NSPoint(x: center.x - ux * stopRadius, y: center.y - uy * stopRadius)
    let half = width * (0.3 + 0.7 * level) / 2

    let beam = NSBezierPath()
    beam.move(to: NSPoint(x: point.x - uy * half, y: point.y + ux * half))
    beam.line(to: NSPoint(x: end.x - uy * 1.2, y: end.y + ux * 1.2))
    beam.line(to: NSPoint(x: end.x + uy * 1.2, y: end.y - ux * 1.2))
    beam.line(to: NSPoint(x: point.x + uy * half, y: point.y - ux * half))
    beam.close()

    guard
      let gradient = NSGradient(colors: [
        color.withAlphaComponent(0.30 * level),
        color.withAlphaComponent(0.02),
      ])
    else { return }
    NSGraphicsContext.saveGraphicsState()
    beam.addClip()
    gradient.draw(from: point, to: end, options: [])
    NSGraphicsContext.restoreGraphicsState()
  }

  private func drawSpeaker(_ channel: BedChannel, at point: NSPoint, radius: CGFloat) {
    let index = channel.rawValue
    let db = displayedLevel(channel)
    let heldDB = index < bedPeakHolds.count ? bedPeakHolds[index].db : Self.minimumDB
    let level = normalizedMeterLevel(db)
    let active = db > -48
    let color = channelFamilyColor(channel)
    let ringWidth = max(2, radius * 0.15)

    // Soft bloom behind the puck.
    if level > 0 {
      let bloom = NSBezierPath(ovalIn: circleRect(point, radius * (1.55 + 1.25 * level)))
      if let gradient = NSGradient(colors: [
        color.withAlphaComponent(0.42 * level),
        color.withAlphaComponent(0),
      ]) {
        gradient.draw(in: bloom, relativeCenterPosition: .zero)
      }
    }

    // Level ring: a quiet track and a bright arc that fills clockwise from the top.
    let track = NSBezierPath(ovalIn: circleRect(point, radius))
    DownmixTheme.nsMeterTrack.setStroke()
    track.lineWidth = ringWidth
    track.stroke()

    if level > 0.004 {
      let arc = NSBezierPath()
      arc.appendArc(
        withCenter: point,
        radius: radius,
        startAngle: -90,
        endAngle: -90 + 360 * level,
        clockwise: false
      )
      color.setStroke()
      arc.lineWidth = ringWidth
      arc.lineCapStyle = .round
      arc.stroke()
    }

    if heldDB > Self.meterFloorDB {
      let held = normalizedMeterLevel(heldDB)
      let angle = (-90 + 360 * held) * .pi / 180
      let tip = NSPoint(x: point.x + cos(angle) * radius, y: point.y + sin(angle) * radius)
      let peak = NSBezierPath(ovalIn: circleRect(tip, ringWidth * 0.62))
      DownmixTheme.nsTextPrimary.withAlphaComponent(0.55 + 0.4 * held).setFill()
      peak.fill()
    }

    // Driver body. The sub is a cabinet; everything else is a round driver.
    let bodyRadius = radius - ringWidth / 2 - 2.5
    let body =
      channel == .lfe
      ? NSBezierPath(
        roundedRect: circleRect(point, bodyRadius * 0.92),
        xRadius: bodyRadius * 0.38,
        yRadius: bodyRadius * 0.38
      )
      : NSBezierPath(ovalIn: circleRect(point, bodyRadius))
    DownmixTheme.nsSpeakerBody.setFill()
    body.fill()
    if level > 0 {
      color.withAlphaComponent(0.12 + 0.5 * level).setFill()
      body.fill()
    }
    (active ? color.withAlphaComponent(0.55) : DownmixTheme.nsCardStroke).setStroke()
    body.lineWidth = 0.8
    body.stroke()

    let coneColor =
      level > 0
      ? NSColor.white.withAlphaComponent(0.35 + 0.55 * level)
      : DownmixTheme.nsTextSecondary.withAlphaComponent(0.32)
    let cone = NSBezierPath(ovalIn: circleRect(point, bodyRadius * 0.52))
    coneColor.setStroke()
    cone.lineWidth = 1
    cone.stroke()
    let cap = NSBezierPath(ovalIn: circleRect(point, max(1.4, bodyRadius * 0.17)))
    coneColor.setFill()
    cap.fill()

    drawText(
      channel.label,
      at: NSPoint(x: point.x, y: point.y + radius + ringWidth / 2 + 3),
      size: 10,
      weight: .semibold,
      color:
        active
        ? DownmixTheme.nsTextPrimary
        : DownmixTheme.nsTextSecondary.withAlphaComponent(0.7),
      centered: true,
      rounded: true
    )
  }

  /// A top-down listener: shoulders, head and a small nose pointing to the front.
  private func drawListener(at point: NSPoint, radius: CGFloat) {
    let halo = NSBezierPath(ovalIn: circleRect(point, radius * 1.6))
    if let gradient = NSGradient(colors: [
      DownmixTheme.nsPanelBottom.withAlphaComponent(0.85),
      DownmixTheme.nsPanelBottom.withAlphaComponent(0),
    ]) {
      gradient.draw(in: halo, relativeCenterPosition: .zero)
    }

    let disc = NSBezierPath(ovalIn: circleRect(point, radius))
    DownmixTheme.nsSpeakerBody.setFill()
    disc.fill()
    DownmixTheme.nsCardStroke.setStroke()
    disc.lineWidth = 1
    disc.stroke()

    let figure = DownmixTheme.nsTextSecondary
    let shoulders = NSBezierPath(
      roundedRect: NSRect(
        x: point.x - radius * 0.6,
        y: point.y - radius * 0.02,
        width: radius * 1.2,
        height: radius * 0.4
      ),
      xRadius: radius * 0.2,
      yRadius: radius * 0.2
    )
    faded(figure, 0.42).setFill()
    shoulders.fill()

    let headCenter = NSPoint(x: point.x, y: point.y - radius * 0.04)
    let headRadius = radius * 0.27
    for side in [-1.0, 1.0] as [CGFloat] {
      let ear = NSBezierPath(
        ovalIn: NSRect(
          x: headCenter.x + side * headRadius - radius * 0.07,
          y: headCenter.y - radius * 0.1,
          width: radius * 0.14,
          height: radius * 0.2
        )
      )
      faded(figure, 0.8).setFill()
      ear.fill()
    }
    DownmixTheme.nsSpeakerBody.setStroke()
    let head = NSBezierPath(ovalIn: circleRect(headCenter, headRadius))
    figure.setFill()
    head.fill()
    head.lineWidth = 1.5
    head.stroke()

    // Facing indicator: a small chevron pointing to the front.
    let chevronY = point.y - radius * 0.58
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: point.x - radius * 0.13, y: chevronY + radius * 0.07))
    chevron.line(to: NSPoint(x: point.x, y: chevronY - radius * 0.05))
    chevron.line(to: NSPoint(x: point.x + radius * 0.13, y: chevronY + radius * 0.07))
    DownmixTheme.nsAccent.setStroke()
    chevron.lineWidth = 1.4
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.stroke()
  }

  /// Scales a dynamic colour's own alpha. `withAlphaComponent` replaces it, which
  /// would turn translucent hairlines opaque.
  private func faded(_ color: NSColor, _ factor: CGFloat) -> NSColor {
    let resolved = color.usingColorSpace(.deviceRGB) ?? color
    return resolved.withAlphaComponent(min(1, resolved.alphaComponent * factor))
  }

  /// Nominal azimuth in degrees: 0 is straight ahead, positive is to the right.
  private static func azimuth(of channel: BedChannel) -> CGFloat {
    switch channel {
    case .c, .lfe: 0
    case .l: -30
    case .r: 30
    case .lw: -60
    case .rw: 60
    case .ls: -90
    case .rs: 90
    case .lrs: -135
    case .rrs: 135
    case .ltf: -45
    case .rtf: 45
    case .ltm: -90
    case .rtm: 90
    case .ltr: -135
    case .rtr: 135
    }
  }

  private func polar(_ center: NSPoint, _ radius: CGFloat, _ azimuthDegrees: CGFloat) -> NSPoint {
    let radians = azimuthDegrees * .pi / 180
    // Flipped view: the front (azimuth 0) is toward smaller y.
    return NSPoint(x: center.x + sin(radians) * radius, y: center.y - cos(radians) * radius)
  }

  private func circleRect(_ center: NSPoint, _ radius: CGFloat) -> NSRect {
    NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
  }

  private func displayedLevel(_ channel: BedChannel) -> Float {
    let index = channel.rawValue
    return index < displayedSnapshot.inputPeaksDb.count
      ? displayedSnapshot.inputPeaksDb[index]
      : Self.minimumDB
  }

  private func channelFamilyColor(_ channel: BedChannel) -> NSColor {
    if channel.isHeight {
      return DownmixTheme.nsHeightChannel
    }
    if channel == .lfe {
      return DownmixTheme.nsLFEChannel
    }
    return DownmixTheme.nsBedChannel
  }

  // MARK: - Stereo meter

  private func drawStereoMeters(in rect: NSRect) {
    guard rect.width > 200, rect.height > 100 else { return }
    let pad = Self.cardPadding

    drawText(
      "Stereo output",
      at: NSPoint(x: rect.minX + pad, y: rect.minY + 16),
      size: 15,
      weight: .semibold,
      color: DownmixTheme.nsTextPrimary,
      rounded: true
    )
    drawText(
      "PEAK  ·  dBFS",
      at: NSPoint(x: rect.maxX - pad, y: rect.minY + 27),
      size: 9,
      weight: .semibold,
      color: DownmixTheme.nsTextSecondary.withAlphaComponent(0.8),
      rightAligned: true,
      verticallyCentered: true,
      kern: 0.9
    )

    let labelWidth: CGFloat = 22
    let valueWidth: CGFloat = 62
    let barHeight: CGFloat = 12
    let barGap: CGFloat = 12
    let blockHeight = barHeight * 2 + barGap + 24
    let top = rect.minY + 50 + max(0, (rect.height - 50 - 12 - blockHeight) / 2)
    let barRect = NSRect(
      x: rect.minX + pad + labelWidth,
      y: top,
      width: max(80, rect.width - pad * 2 - labelWidth - valueWidth),
      height: barHeight
    )
    let secondBarRect = barRect.offsetBy(dx: 0, dy: barHeight + barGap)
    let valueX = rect.maxX - pad

    drawMeter(
      label: "L",
      db: displayedSnapshot.outputPeakLDb,
      heldDB: leftPeakHold.db,
      clip: displayedSnapshot.clipL,
      barRect: barRect,
      valueX: valueX
    )
    drawMeter(
      label: "R",
      db: displayedSnapshot.outputPeakRDb,
      heldDB: rightPeakHold.db,
      clip: displayedSnapshot.clipR,
      barRect: secondBarRect,
      valueX: valueX
    )
    drawMeterScale(barRect: barRect, y: secondBarRect.maxY + 8)
  }

  private func drawMeterScale(barRect: NSRect, y: CGFloat) {
    let ticks: [Float] = [-60, -48, -36, -24, -12, -6, 0]
    for tick in ticks {
      let x = barRect.minX + barRect.width * normalizedMeterLevel(tick)
      let mark = NSBezierPath()
      mark.move(to: NSPoint(x: x, y: y))
      mark.line(to: NSPoint(x: x, y: y + 3))
      DownmixTheme.nsStageGuide.setStroke()
      mark.lineWidth = 1
      mark.stroke()

      let hot = tick >= -6
      drawText(
        tick == 0 ? "0" : String(format: "%.0f", tick).replacingOccurrences(of: "-", with: "−"),
        at: NSPoint(x: x, y: y + 5),
        size: 9,
        weight: .medium,
        color:
          hot
          ? DownmixTheme.nsWarn.withAlphaComponent(0.85)
          : DownmixTheme.nsTextSecondary.withAlphaComponent(0.7),
        centered: true,
        monospacedDigits: true
      )
    }
  }

  private func drawMeter(
    label: String,
    db: Float,
    heldDB: Float,
    clip: Bool,
    barRect: NSRect,
    valueX: CGFloat
  ) {
    drawText(
      label,
      at: NSPoint(x: barRect.minX - 14, y: barRect.midY),
      size: 11,
      weight: .bold,
      color: DownmixTheme.nsTextSecondary,
      centered: true,
      verticallyCentered: true,
      rounded: true
    )

    let valueText =
      clip
      ? "CLIP"
      : db <= -119
        ? "−∞"
        : String(format: "%.1f", db).replacingOccurrences(of: "-", with: "−")
    let valueColor =
      clip
      ? DownmixTheme.nsBad
      : db >= -6
        ? DownmixTheme.nsWarn
        : db <= -119 ? DownmixTheme.nsTextSecondary : DownmixTheme.nsTextPrimary
    drawText(
      valueText,
      at: NSPoint(x: valueX, y: barRect.midY),
      size: 12,
      weight: .semibold,
      color: valueColor,
      rightAligned: true,
      verticallyCentered: true,
      monospacedDigits: true
    )

    let radius = barRect.height / 2
    let track = NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius)
    DownmixTheme.nsMeterTrack.setFill()
    track.fill()

    let level = normalizedMeterLevel(db)
    if level > 0 {
      let fillRect = NSRect(
        x: barRect.minX,
        y: barRect.minY,
        width: max(barRect.height, barRect.width * level),
        height: barRect.height
      )
      let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)

      NSGraphicsContext.saveGraphicsState()
      let glow = NSShadow()
      glow.shadowColor = meterTipColor(db: db, clip: clip).withAlphaComponent(0.45)
      glow.shadowBlurRadius = 9
      glow.shadowOffset = .zero
      glow.set()
      meterTipColor(db: db, clip: clip).withAlphaComponent(0.6).setFill()
      fill.fill()
      NSGraphicsContext.restoreGraphicsState()

      // The gradient spans the whole scale so colour encodes level, not length.
      NSGraphicsContext.saveGraphicsState()
      fill.addClip()
      if let gradient = NSGradient(
        colors: [
          DownmixTheme.nsBedChannel,
          DownmixTheme.nsAccent,
          DownmixTheme.nsGood,
          DownmixTheme.nsWarn,
          DownmixTheme.nsBad,
        ],
        atLocations: [0, 0.45, 0.74, 0.9, 1],
        colorSpace: .deviceRGB
      ) {
        gradient.draw(
          from: NSPoint(x: barRect.minX, y: barRect.midY),
          to: NSPoint(x: barRect.maxX, y: barRect.midY),
          options: []
        )
      }
      // LED-style segmentation.
      DownmixTheme.nsPanelBottom.withAlphaComponent(0.55).setFill()
      var x = barRect.minX + 4
      while x < fillRect.maxX {
        NSRect(x: x, y: barRect.minY, width: 1, height: barRect.height).fill(
          using: .sourceOver)
        x += 5
      }
      NSGraphicsContext.restoreGraphicsState()
    }

    if heldDB > Self.meterFloorDB {
      let peakX = barRect.minX + barRect.width * normalizedMeterLevel(heldDB)
      let peak = NSBezierPath(
        roundedRect: NSRect(
          x: min(barRect.maxX - 3, max(barRect.minX, peakX - 1.5)),
          y: barRect.minY - 2,
          width: 3,
          height: barRect.height + 4
        ),
        xRadius: 1.5,
        yRadius: 1.5
      )
      (heldDB >= -6 ? meterTipColor(db: heldDB, clip: heldDB >= 0) : DownmixTheme.nsTextPrimary)
        .withAlphaComponent(0.9).setFill()
      peak.fill()
    }
  }

  private func meterTipColor(db: Float, clip: Bool) -> NSColor {
    if clip || db >= 0 {
      return DownmixTheme.nsBad
    }
    if db >= -6 {
      return DownmixTheme.nsWarn
    }
    if db >= -18 {
      return DownmixTheme.nsGood
    }
    return DownmixTheme.nsAccent
  }

  private func normalizedMeterLevel(_ db: Float) -> CGFloat {
    let value = CGFloat(Self.sanitized(db))
    return min(1, max(0, (value - CGFloat(Self.meterFloorDB)) / -CGFloat(Self.meterFloorDB)))
  }

  private func updateAccessibilityValue() {
    let left = accessibilityLevelDescription(
      db: targetSnapshot.outputPeakLDb,
      clip: targetSnapshot.clipL
    )
    let right = accessibilityLevelDescription(
      db: targetSnapshot.outputPeakRDb,
      clip: targetSnapshot.clipR
    )
    setAccessibilityValue("Left \(left), right \(right)")
  }

  private func accessibilityLevelDescription(db: Float, clip: Bool) -> String {
    if clip {
      return "clipping"
    }
    if db <= -119 || !db.isFinite {
      return "silent"
    }
    return String(format: "%.1f decibels full scale", db)
  }

  // MARK: - Text

  /// Draws a single line. `point.y` is the top edge unless `verticallyCentered`.
  @discardableResult
  private func drawText(
    _ text: String,
    at point: NSPoint,
    size: CGFloat,
    weight: NSFont.Weight,
    color: NSColor,
    centered: Bool = false,
    rightAligned: Bool = false,
    verticallyCentered: Bool = false,
    monospacedDigits: Bool = false,
    rounded: Bool = false,
    kern: CGFloat = 0
  ) -> NSSize {
    var font =
      monospacedDigits
      ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
      : NSFont.systemFont(ofSize: size, weight: weight)
    if rounded, let descriptor = font.fontDescriptor.withDesign(.rounded),
      let roundedFont = NSFont(descriptor: descriptor, size: size)
    {
      font = roundedFont
    }
    var attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: color,
    ]
    if kern != 0 { attributes[.kern] = kern }
    let string = text as NSString
    let textSize = string.size(withAttributes: attributes)
    var x = point.x
    var y = point.y
    if centered { x -= textSize.width / 2 }
    if rightAligned { x -= textSize.width }
    if verticallyCentered { y -= textSize.height / 2 }
    string.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    return textSize
  }
}
