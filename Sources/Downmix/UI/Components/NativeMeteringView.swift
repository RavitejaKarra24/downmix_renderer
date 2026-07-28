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
      holdUntil = now + DownmixMeterNSView.peakHoldDuration
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

  private(set) var source: MeterSource
  private var targetSnapshot: MeterSnapshot
  private var displayedSnapshot: MeterSnapshot
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

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { true }

  init(source: MeterSource) {
    let snapshot = source.snapshot()
    self.source = source
    targetSnapshot = snapshot
    displayedSnapshot = snapshot
    lastFrameTime = ProcessInfo.processInfo.systemUptime
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
    let snapshot = newSource.snapshot()
    targetSnapshot = snapshot
    resetBallistics(to: snapshot)
    updateAccessibilityValue()

    if observing {
      observeMeterSource()
    }
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
    DownmixTheme.nsBackground.setFill()
    bounds.fill()

    let gap: CGFloat = 14
    let meterHeight = min(152, max(124, bounds.height * 0.29))
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
      selector: #selector(meterSourceDidChange),
      name: .downmixMetersDidChange,
      object: source
    )
  }

  @objc private func meterSourceDidChange() {
    targetSnapshot = source.snapshot()
    updateAccessibilityValue()
    if shouldReduceMotion {
      displayedSnapshot = targetSnapshot
    }
    if animationTimer == nil {
      resetBallistics(to: targetSnapshot)
    }
  }

  @objc private func accessibilityDisplayOptionsDidChange() {
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    guard reduceMotion != shouldReduceMotion else { return }
    shouldReduceMotion = reduceMotion
    if reduceMotion {
      displayedSnapshot = targetSnapshot
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
      resetBallistics(to: source.snapshot())
      return
    }

    guard forceRestart || animationTimer == nil else { return }
    configureAnimationTimer()
  }

  private var isWindowVisibleForMetering: Bool {
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
    lastFrameTime = ProcessInfo.processInfo.systemUptime
  }

  private func advanceAnimation() {
    // Sampling here as well as in the notification callback makes source
    // replacement and a coalesced/missed notification harmless.
    targetSnapshot = source.snapshot()

    let now = ProcessInfo.processInfo.systemUptime
    let deltaTime = min(0.1, max(0, now - lastFrameTime))
    lastFrameTime = now

    guard isWindowVisibleForMetering else {
      updateAnimationTimerActivity()
      return
    }

    if shouldReduceMotion {
      displayedSnapshot = targetSnapshot
    } else {
      interpolateDisplayedLevels(deltaTime: deltaTime)
    }
    updatePeakHolds(now: now, deltaTime: deltaTime)
    needsDisplay = true
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

  private func resetBallistics(
    to snapshot: MeterSnapshot,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) {
    let channelCount = BedChannel.allCases.count
    var levels = [Float](repeating: Self.minimumDB, count: channelCount)
    for index in levels.indices where index < snapshot.inputPeaksDb.count {
      levels[index] = Self.sanitized(snapshot.inputPeaksDb[index])
    }

    displayedSnapshot = MeterSnapshot(
      inputPeaksDb: levels,
      outputPeakLDb: Self.sanitized(snapshot.outputPeakLDb),
      outputPeakRDb: Self.sanitized(snapshot.outputPeakRDb),
      clipL: snapshot.clipL,
      clipR: snapshot.clipR
    )
    targetSnapshot = snapshot

    for index in bedPeakHolds.indices {
      bedPeakHolds[index].reset(to: levels[index], now: now)
    }
    leftPeakHold.reset(to: snapshot.outputPeakLDb, now: now)
    rightPeakHold.reset(to: snapshot.outputPeakRDb, now: now)
  }

  private static func sanitized(_ db: Float) -> Float {
    guard db.isFinite else { return minimumDB }
    return min(6, max(minimumDB, db))
  }

  private func drawCard(_ rect: NSRect) {
    guard rect.width > 1, rect.height > 1 else { return }
    let path = NSBezierPath(
      roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
      xRadius: 16,
      yRadius: 16
    )
    DownmixTheme.nsSurfaceWell.setFill()
    path.fill()
    DownmixTheme.nsCardStroke.setStroke()
    path.lineWidth = 1
    path.stroke()
  }

  // MARK: - Speaker plan

  private func drawBed(in rect: NSRect) {
    guard rect.width > 180, rect.height > 180 else { return }

    drawText(
      "9.1.6 speaker activity",
      at: NSPoint(x: rect.minX + 18, y: rect.minY + 14),
      size: 13,
      weight: .semibold,
      color: DownmixTheme.nsTextPrimary
    )
    drawText(
      "16 CHANNELS",
      at: NSPoint(x: rect.maxX - 18, y: rect.minY + 16),
      size: 9,
      weight: .medium,
      color: DownmixTheme.nsTextSecondary,
      rightAligned: true
    )

    let horizontalInset = min(22, max(14, rect.width * 0.055))
    let heightShelfHeight = min(66, max(56, rect.height * 0.19))
    let heightShelf = NSRect(
      x: rect.minX + horizontalInset,
      y: rect.minY + 44,
      width: rect.width - horizontalInset * 2,
      height: heightShelfHeight
    )
    drawHeightShelf(in: heightShelf)

    let planRect = NSRect(
      x: heightShelf.minX,
      y: heightShelf.maxY + 9,
      width: heightShelf.width,
      height: max(72, rect.maxY - heightShelf.maxY - 21)
    )
    drawGroundPlan(in: planRect)
  }

  private func drawHeightShelf(in rect: NSRect) {
    let shelf = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
    DownmixTheme.nsSurfaceRaised.withAlphaComponent(0.72).setFill()
    shelf.fill()
    DownmixTheme.nsHeightChannel.withAlphaComponent(0.20).setStroke()
    shelf.lineWidth = 1
    shelf.stroke()

    let labelWidth = min(56, rect.width * 0.15)
    drawText(
      "HEIGHT",
      at: NSPoint(x: rect.minX + 10, y: rect.midY - 5),
      size: 9,
      weight: .semibold,
      color: DownmixTheme.nsHeightChannel
    )

    let groups: [(String, BedChannel, BedChannel)] = [
      ("FRONT", .ltf, .rtf),
      ("MID", .ltm, .rtm),
      ("REAR", .ltr, .rtr),
    ]
    let channelsWidth = rect.width - labelWidth - 10
    let groupWidth = channelsWidth / CGFloat(groups.count)
    let markerY = rect.minY + rect.height * 0.53

    for (index, group) in groups.enumerated() {
      let groupCenter = rect.minX + labelWidth + groupWidth * (CGFloat(index) + 0.5)
      let pairOffset = min(17, groupWidth * 0.19)
      drawText(
        group.0,
        at: NSPoint(x: groupCenter, y: rect.minY + 7),
        size: 8,
        weight: .medium,
        color: DownmixTheme.nsTextSecondary.withAlphaComponent(0.78),
        centered: true
      )
      drawChannelMarker(
        group.1,
        at: NSPoint(x: groupCenter - pairOffset, y: markerY)
      )
      drawChannelMarker(
        group.2,
        at: NSPoint(x: groupCenter + pairOffset, y: markerY)
      )
    }
  }

  private func drawGroundPlan(in rect: NSRect) {
    let frontY = rect.minY + 12
    let rearY = rect.maxY - 9
    let centerX = rect.midX
    let frontHalfWidth = rect.width * 0.46
    let rearHalfWidth = rect.width * 0.31

    let room = NSBezierPath()
    room.move(to: NSPoint(x: centerX - frontHalfWidth, y: frontY))
    room.line(to: NSPoint(x: centerX + frontHalfWidth, y: frontY))
    room.line(to: NSPoint(x: centerX + rearHalfWidth, y: rearY))
    room.line(to: NSPoint(x: centerX - rearHalfWidth, y: rearY))
    room.close()
    DownmixTheme.nsSurfaceRaised.withAlphaComponent(0.28).setFill()
    room.fill()
    DownmixTheme.nsCardStroke.withAlphaComponent(0.92).setStroke()
    room.lineWidth = 1
    room.stroke()

    let centerGuide = NSBezierPath()
    centerGuide.move(to: NSPoint(x: centerX, y: frontY + 5))
    centerGuide.line(to: NSPoint(x: centerX, y: rearY - 5))
    DownmixTheme.nsCardStroke.withAlphaComponent(0.58).setStroke()
    centerGuide.lineWidth = 0.75
    centerGuide.stroke()

    drawText(
      "FRONT",
      at: NSPoint(x: rect.minX + 6, y: frontY - 10),
      size: 8,
      weight: .medium,
      color: DownmixTheme.nsTextSecondary.withAlphaComponent(0.65)
    )
    drawText(
      "REAR",
      at: NSPoint(x: rect.minX + 6, y: rearY - 12),
      size: 8,
      weight: .medium,
      color: DownmixTheme.nsTextSecondary.withAlphaComponent(0.65)
    )

    for channel in BedChannel.allCases where !channel.isHeight {
      guard
        let point = groundPosition(
          for: channel,
          centerX: centerX,
          frontY: frontY,
          rearY: rearY,
          width: rect.width
        )
      else { continue }
      drawChannelMarker(channel, at: point)
    }

    let listener = NSPoint(
      x: centerX,
      y: frontY + (rearY - frontY) * 0.58
    )
    drawListener(at: listener)
  }

  private func groundPosition(
    for channel: BedChannel,
    centerX: CGFloat,
    frontY: CGFloat,
    rearY: CGFloat,
    width: CGFloat
  ) -> NSPoint? {
    let depth = rearY - frontY
    switch channel {
    case .lw:
      return NSPoint(x: centerX - width * 0.40, y: frontY + depth * 0.11)
    case .l:
      return NSPoint(x: centerX - width * 0.21, y: frontY + depth * 0.06)
    case .c:
      return NSPoint(x: centerX, y: frontY + depth * 0.035)
    case .r:
      return NSPoint(x: centerX + width * 0.21, y: frontY + depth * 0.06)
    case .rw:
      return NSPoint(x: centerX + width * 0.40, y: frontY + depth * 0.11)
    case .lfe:
      return NSPoint(x: centerX + width * 0.12, y: frontY + depth * 0.25)
    case .ls:
      return NSPoint(x: centerX - width * 0.37, y: frontY + depth * 0.54)
    case .rs:
      return NSPoint(x: centerX + width * 0.37, y: frontY + depth * 0.54)
    case .lrs:
      return NSPoint(x: centerX - width * 0.23, y: frontY + depth * 0.88)
    case .rrs:
      return NSPoint(x: centerX + width * 0.23, y: frontY + depth * 0.88)
    case .ltf, .rtf, .ltm, .rtm, .ltr, .rtr:
      return nil
    }
  }

  private func drawListener(at point: NSPoint) {
    let surround = NSBezierPath(
      ovalIn: NSRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40)
    )
    DownmixTheme.nsSurfaceRaised.setFill()
    surround.fill()
    DownmixTheme.nsCardStroke.setStroke()
    surround.lineWidth = 1
    surround.stroke()

    let head = NSBezierPath(
      ovalIn: NSRect(x: point.x - 4, y: point.y - 8, width: 8, height: 8)
    )
    DownmixTheme.nsTextSecondary.setFill()
    head.fill()

    let shoulders = NSBezierPath()
    shoulders.move(to: NSPoint(x: point.x - 8, y: point.y + 7))
    shoulders.curve(
      to: NSPoint(x: point.x + 8, y: point.y + 7),
      controlPoint1: NSPoint(x: point.x - 6, y: point.y),
      controlPoint2: NSPoint(x: point.x + 6, y: point.y)
    )
    DownmixTheme.nsTextSecondary.setStroke()
    shoulders.lineWidth = 1.5
    shoulders.stroke()
  }

  private func drawChannelMarker(_ channel: BedChannel, at point: NSPoint) {
    let index = channel.rawValue
    let db =
      index < displayedSnapshot.inputPeaksDb.count
      ? displayedSnapshot.inputPeaksDb[index]
      : Self.minimumDB
    let heldDB =
      index < bedPeakHolds.count
      ? bedPeakHolds[index].db
      : Self.minimumDB
    let level = normalizedMeterLevel(db)
    let active = db > -48
    let familyColor = channelFamilyColor(channel)

    if active {
      let glowSize = 22 + 7 * level
      let glow = NSBezierPath(
        ovalIn: NSRect(
          x: point.x - glowSize / 2,
          y: point.y - glowSize / 2,
          width: glowSize,
          height: glowSize
        )
      )
      familyColor.withAlphaComponent(0.10 + 0.16 * level).setFill()
      glow.fill()
    }

    let markerRect = NSRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
    let marker = NSBezierPath(ovalIn: markerRect)
    if level > 0 {
      familyColor.withAlphaComponent(0.32 + 0.68 * level).setFill()
    } else {
      DownmixTheme.nsMeterTrack.setFill()
    }
    marker.fill()
    (active ? familyColor : DownmixTheme.nsCardStroke).setStroke()
    marker.lineWidth = active ? 1.25 : 1
    marker.stroke()

    if heldDB > Self.meterFloorDB {
      let heldLevel = normalizedMeterLevel(heldDB)
      let peakWidth = 5 + 8 * heldLevel
      let peakLine = NSBezierPath()
      peakLine.move(to: NSPoint(x: point.x - peakWidth / 2, y: point.y - 11))
      peakLine.line(to: NSPoint(x: point.x + peakWidth / 2, y: point.y - 11))
      familyColor.withAlphaComponent(0.52 + 0.48 * heldLevel).setStroke()
      peakLine.lineWidth = 1.5
      peakLine.lineCapStyle = .round
      peakLine.stroke()
    }

    drawText(
      channel.label,
      at: NSPoint(x: point.x, y: point.y + 9),
      size: 9,
      weight: .semibold,
      color:
        active
        ? DownmixTheme.nsTextPrimary
        : DownmixTheme.nsTextSecondary.withAlphaComponent(0.72),
      centered: true
    )
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
    guard rect.width > 180, rect.height > 100 else { return }

    drawText(
      "Stereo output",
      at: NSPoint(x: rect.minX + 18, y: rect.minY + 13),
      size: 13,
      weight: .semibold,
      color: DownmixTheme.nsTextPrimary
    )
    drawText(
      "dBFS · PEAK",
      at: NSPoint(x: rect.maxX - 18, y: rect.minY + 15),
      size: 9,
      weight: .medium,
      color: DownmixTheme.nsTextSecondary,
      rightAligned: true
    )

    let valueWidth: CGFloat = 66
    let barRect = NSRect(
      x: rect.minX + 43,
      y: rect.minY + 64,
      width: max(80, rect.width - 43 - valueWidth - 17),
      height: 10
    )
    let secondBarRect = barRect.offsetBy(dx: 0, dy: 35)
    drawMeterGrid(
      barRect: barRect,
      firstBarY: barRect.minY,
      lastBarY: secondBarRect.maxY
    )

    drawMeter(
      label: "L",
      db: displayedSnapshot.outputPeakLDb,
      heldDB: leftPeakHold.db,
      clip: displayedSnapshot.clipL,
      barRect: barRect,
      valueX: rect.maxX - 17
    )
    drawMeter(
      label: "R",
      db: displayedSnapshot.outputPeakRDb,
      heldDB: rightPeakHold.db,
      clip: displayedSnapshot.clipR,
      barRect: secondBarRect,
      valueX: rect.maxX - 17
    )
  }

  private func drawMeterGrid(barRect: NSRect, firstBarY: CGFloat, lastBarY: CGFloat) {
    let ticks: [(String, Float)] = [
      ("-60", -60),
      ("-40", -40),
      ("-20", -20),
      ("-6", -6),
      ("0", 0),
    ]

    for tick in ticks {
      let x = barRect.minX + barRect.width * normalizedMeterLevel(tick.1)
      let gridLine = NSBezierPath()
      gridLine.move(to: NSPoint(x: x, y: firstBarY - 15))
      gridLine.line(to: NSPoint(x: x, y: lastBarY + 2))
      DownmixTheme.nsCardStroke.withAlphaComponent(tick.1 == -6 ? 0.95 : 0.62).setStroke()
      gridLine.lineWidth = tick.1 == -6 ? 0.9 : 0.6
      gridLine.stroke()

      drawText(
        tick.0,
        at: NSPoint(x: x, y: firstBarY - 27),
        size: 8,
        weight: .medium,
        color:
          tick.1 == -6
          ? DownmixTheme.nsWarn.withAlphaComponent(0.9)
          : DownmixTheme.nsTextSecondary.withAlphaComponent(0.82),
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
      at: NSPoint(x: barRect.minX - 19, y: barRect.minY - 3),
      size: 11,
      weight: .semibold,
      color: DownmixTheme.nsTextSecondary,
      centered: true
    )

    let valueText =
      clip
      ? "CLIP"
      : db <= -119
        ? "−∞"
        : String(format: "%.1f", db)
    let valueColor =
      clip
      ? DownmixTheme.nsBad
      : db >= -6
        ? DownmixTheme.nsWarn
        : DownmixTheme.nsTextSecondary
    drawText(
      valueText,
      at: NSPoint(x: valueX, y: barRect.minY - 3),
      size: 10,
      weight: clip ? .semibold : .regular,
      color: valueColor,
      rightAligned: true,
      monospacedDigits: true
    )

    let track = NSBezierPath(roundedRect: barRect, xRadius: 5, yRadius: 5)
    DownmixTheme.nsMeterTrack.setFill()
    track.fill()

    let level = normalizedMeterLevel(db)
    if level > 0 {
      let fillRect = NSRect(
        x: barRect.minX,
        y: barRect.minY,
        width: barRect.width * level,
        height: barRect.height
      )
      let fill = NSBezierPath(
        roundedRect: fillRect,
        xRadius: min(5, fillRect.width / 2),
        yRadius: min(5, fillRect.height / 2)
      )
      let tipColor = meterTipColor(db: db, clip: clip)
      if let gradient = NSGradient(
        starting: DownmixTheme.nsAccent,
        ending: tipColor
      ) {
        gradient.draw(in: fill, angle: 0)
      } else {
        tipColor.setFill()
        fill.fill()
      }
    }

    if heldDB > Self.meterFloorDB {
      let peakLevel = normalizedMeterLevel(heldDB)
      let peakX = barRect.minX + barRect.width * peakLevel
      let peakLine = NSBezierPath()
      peakLine.move(to: NSPoint(x: peakX, y: barRect.minY - 2))
      peakLine.line(to: NSPoint(x: peakX, y: barRect.maxY + 2))
      meterTipColor(db: heldDB, clip: heldDB >= 0).setStroke()
      peakLine.lineWidth = 1.6
      peakLine.lineCapStyle = .round
      peakLine.stroke()
    }
  }

  private func meterTipColor(db: Float, clip: Bool) -> NSColor {
    if clip || db >= 0 {
      return DownmixTheme.nsBad
    }
    if db >= -6 {
      return DownmixTheme.nsWarn
    }
    return DownmixTheme.nsGood
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

  private func drawText(
    _ text: String,
    at point: NSPoint,
    size: CGFloat,
    weight: NSFont.Weight,
    color: NSColor,
    centered: Bool = false,
    rightAligned: Bool = false,
    monospacedDigits: Bool = false
  ) {
    let font =
      monospacedDigits
      ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
      : NSFont.systemFont(ofSize: size, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: color,
    ]
    let string = text as NSString
    let textSize = string.size(withAttributes: attributes)
    var x = point.x
    if centered { x -= textSize.width / 2 }
    if rightAligned { x -= textSize.width }
    string.draw(at: NSPoint(x: x, y: point.y), withAttributes: attributes)
  }
}
