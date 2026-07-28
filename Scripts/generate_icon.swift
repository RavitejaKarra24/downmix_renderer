import AppKit
import Foundation

let output = CommandLine.arguments.dropFirst().first ?? "Icon.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
  fatalError("No graphics context")
}
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

let tile = NSBezierPath(
  roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 210, yRadius: 210)
let gradient = NSGradient(colors: [
  NSColor(red: 0.035, green: 0.045, blue: 0.065, alpha: 1),
  NSColor(red: 0.075, green: 0.10, blue: 0.15, alpha: 1),
])!
gradient.draw(in: tile, angle: -45)

NSColor.white.withAlphaComponent(0.10).setStroke()
tile.lineWidth = 8
tile.stroke()

let leftTarget = NSPoint(x: 438, y: 350)
let rightTarget = NSPoint(x: 586, y: 350)
let channelPoints: [NSPoint] = [
  .init(x: 280, y: 740), .init(x: 410, y: 800), .init(x: 512, y: 830), .init(x: 614, y: 800),
  .init(x: 744, y: 740),
  .init(x: 215, y: 610), .init(x: 315, y: 610), .init(x: 709, y: 610), .init(x: 809, y: 610),
  .init(x: 235, y: 470), .init(x: 350, y: 485), .init(x: 674, y: 485), .init(x: 789, y: 470),
  .init(x: 330, y: 690), .init(x: 694, y: 690), .init(x: 512, y: 650),
]

for (index, point) in channelPoints.enumerated() {
  let target =
    point.x < 512
    ? leftTarget
    : (point.x > 512 ? rightTarget : (index.isMultiple(of: 2) ? leftTarget : rightTarget))
  let path = NSBezierPath()
  path.move(to: point)
  let controlA = NSPoint(x: point.x + (target.x - point.x) * 0.32, y: point.y - 70)
  let controlB = NSPoint(x: target.x, y: target.y + 110)
  path.curve(to: target, controlPoint1: controlA, controlPoint2: controlB)
  NSColor(red: 0.35, green: 0.68, blue: 1.0, alpha: index < 5 ? 0.48 : 0.72).setStroke()
  path.lineWidth = index < 5 ? 8 : 10
  path.lineCapStyle = .round
  path.stroke()

  let dotColor =
    index < 5
    ? NSColor(red: 0.72, green: 0.55, blue: 1.0, alpha: 1)
    : NSColor(red: 0.40, green: 0.76, blue: 1.0, alpha: 1)
  dotColor.setFill()
  NSBezierPath(ovalIn: NSRect(x: point.x - 13, y: point.y - 13, width: 26, height: 26)).fill()
}

for (x, label) in [(438.0, "L"), (586.0, "R")] {
  let bar = NSBezierPath(
    roundedRect: NSRect(x: x - 45, y: 235, width: 90, height: 180), xRadius: 45, yRadius: 45)
  NSColor(red: 0.36, green: 0.70, blue: 1.0, alpha: 1).setFill()
  bar.fill()

  let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 54, weight: .bold),
    .foregroundColor: NSColor.white,
  ]
  let text = label as NSString
  let textSize = text.size(withAttributes: attributes)
  text.draw(at: NSPoint(x: x - textSize.width / 2, y: 290), withAttributes: attributes)
}

image.unlockFocus()

let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = representation.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
