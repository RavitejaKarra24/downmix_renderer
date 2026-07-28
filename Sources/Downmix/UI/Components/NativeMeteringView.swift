import AppKit
import SwiftUI

/// AppKit-backed metering surface. Redraws at 10 Hz without invalidating SwiftUI layout.
struct NativeMeteringView: NSViewRepresentable {
  let source: MeterSource

  func makeNSView(context: Context) -> DownmixMeterNSView {
    DownmixMeterNSView(source: source)
  }

  func updateNSView(_ nsView: DownmixMeterNSView, context: Context) {
    nsView.source = source
  }

  static func dismantleNSView(_ nsView: DownmixMeterNSView, coordinator: Void) {
    nsView.stop()
  }
}

@MainActor
final class DownmixMeterNSView: NSView {
  var source: MeterSource
  private var observing = false

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { true }

  init(source: MeterSource) {
    self.source = source
    super.init(frame: .zero)
    wantsLayer = true
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("9.1.6 bed activity and stereo output meters")
    start()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 460, height: 520)
  }

  func start() {
    guard !observing else { return }
    observing = true
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(redrawMeterSurface),
      name: .downmixMetersDidChange,
      object: source
    )
  }

  @objc private func redrawMeterSurface() {
    guard let window, window.isVisible, !window.isMiniaturized else { return }
    needsDisplay = true
  }

  func stop() {
    guard observing else { return }
    NotificationCenter.default.removeObserver(self, name: .downmixMetersDidChange, object: source)
    observing = false
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    NSColor(red: 0.04, green: 0.045, blue: 0.055, alpha: 1).setFill()
    bounds.fill()

    let snapshot = source.snapshot()
    let gap: CGFloat = 16
    let meterHeight: CGFloat = 112
    let bedRect = NSRect(
      x: 0,
      y: 0,
      width: bounds.width,
      height: max(260, bounds.height - meterHeight - gap)
    )
    let meterRect = NSRect(
      x: 0,
      y: bedRect.maxY + gap,
      width: bounds.width,
      height: meterHeight
    )

    drawCard(bedRect)
    drawBed(in: bedRect, levels: snapshot.inputPeaksDb)
    drawCard(meterRect)
    drawStereoMeters(in: meterRect, snapshot: snapshot)
  }

  private func drawCard(_ rect: NSRect) {
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18)
    NSColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1).setFill()
    path.fill()
    NSColor.white.withAlphaComponent(0.08).setStroke()
    path.lineWidth = 1
    path.stroke()
  }

  private func drawBed(in rect: NSRect, levels: [Float]) {
    let inner = rect.insetBy(dx: 24, dy: 22)
    let size = min(inner.width, inner.height)
    let center = NSPoint(x: rect.midX, y: rect.midY + 4)

    let guideRect = NSRect(
      x: center.x - size * 0.36,
      y: center.y - size * 0.36,
      width: size * 0.72,
      height: size * 0.72
    )
    let guide = NSBezierPath(roundedRect: guideRect, xRadius: 28, yRadius: 28)
    NSColor.white.withAlphaComponent(0.055).setStroke()
    guide.lineWidth = 1
    guide.stroke()

    NSColor.white.withAlphaComponent(0.045).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 27, y: center.y - 27, width: 54, height: 54)).fill()
    if let image = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil) {
      image.draw(in: NSRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20))
    }

    for channel in BedChannel.allCases {
      let position = channel.visualPosition
      let point = NSPoint(
        x: center.x + CGFloat(position.x) * size * 0.34,
        y: center.y - CGFloat(position.y) * size * 0.34
      )
      let db = channel.rawValue < levels.count ? levels[channel.rawValue] : -120
      let active = db > -48
      let color = channelColor(channel, active: active, db: db)

      color.setFill()
      NSBezierPath(ovalIn: NSRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)).fill()
      NSColor.white.withAlphaComponent(0.18).setStroke()
      let outline = NSBezierPath(
        ovalIn: NSRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
      outline.lineWidth = 1
      outline.stroke()

      drawText(
        channel.label,
        at: NSPoint(x: point.x, y: point.y + 13),
        size: 10,
        weight: .semibold,
        color: active ? textPrimary : textSecondary.withAlphaComponent(0.72),
        centered: true
      )
    }
  }

  private func drawStereoMeters(in rect: NSRect, snapshot: MeterSnapshot) {
    drawText(
      "Output meters",
      at: NSPoint(x: rect.minX + 16, y: rect.minY + 14),
      size: 13,
      weight: .semibold,
      color: textPrimary
    )

    drawMeter(
      label: "L", db: snapshot.outputPeakLDb, clip: snapshot.clipL, y: rect.minY + 48, rect: rect)
    drawMeter(
      label: "R", db: snapshot.outputPeakRDb, clip: snapshot.clipR, y: rect.minY + 80, rect: rect)
  }

  private func drawMeter(label: String, db: Float, clip: Bool, y: CGFloat, rect: NSRect) {
    drawText(
      label, at: NSPoint(x: rect.minX + 16, y: y - 3), size: 11, weight: .semibold,
      color: textSecondary)

    let valueText = clip ? "CLIP" : String(format: "%.1f dB", db)
    let valueColor = clip ? NSColor(red: 1, green: 0.38, blue: 0.42, alpha: 1) : textSecondary
    drawText(
      valueText, at: NSPoint(x: rect.maxX - 16, y: y - 3), size: 10, weight: .regular,
      color: valueColor, rightAligned: true)

    let barRect = NSRect(x: rect.minX + 42, y: y, width: max(80, rect.width - 136), height: 8)
    let track = NSBezierPath(roundedRect: barRect, xRadius: 4, yRadius: 4)
    NSColor.white.withAlphaComponent(0.065).setFill()
    track.fill()

    let level = min(1, max(0, (CGFloat(db) + 60) / 60))
    if level > 0 {
      let fillRect = NSRect(
        x: barRect.minX, y: barRect.minY, width: barRect.width * level, height: barRect.height)
      let fill = NSBezierPath(roundedRect: fillRect, xRadius: 4, yRadius: 4)
      NSColor(red: 0.35, green: 0.68, blue: 1.0, alpha: 0.95).setFill()
      fill.fill()
    }
  }

  private func channelColor(_ channel: BedChannel, active: Bool, db: Float) -> NSColor {
    guard active else { return NSColor.white.withAlphaComponent(0.12) }
    let level = min(1, max(0, (CGFloat(db) + 48) / 48))
    let alpha = 0.45 + 0.55 * level
    if channel.isHeight {
      return NSColor(red: 0.72, green: 0.55, blue: 1, alpha: alpha)
    }
    if channel == .lfe {
      return NSColor(red: 1, green: 0.72, blue: 0.28, alpha: alpha)
    }
    return NSColor(red: 0.35, green: 0.68, blue: 1, alpha: alpha)
  }

  private func drawText(
    _ text: String,
    at point: NSPoint,
    size: CGFloat,
    weight: NSFont.Weight,
    color: NSColor,
    centered: Bool = false,
    rightAligned: Bool = false
  ) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
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

  private var textPrimary: NSColor {
    NSColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)
  }

  private var textSecondary: NSColor {
    NSColor(red: 0.62, green: 0.66, blue: 0.72, alpha: 1)
  }
}
