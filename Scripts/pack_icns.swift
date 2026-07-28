import Foundation

enum ICNSPackingError: LocalizedError {
  case usage
  case missingIcon(String)
  case invalidPNG(String)
  case fileTooLarge(String)

  var errorDescription: String? {
    switch self {
    case .usage:
      "Usage: swift Scripts/pack_icns.swift <iconset directory> <output.icns>"
    case .missingIcon(let name):
      "Missing iconset member: \(name)"
    case .invalidPNG(let name):
      "Iconset member is not a PNG: \(name)"
    case .fileTooLarge(let name):
      "Iconset member is too large for ICNS: \(name)"
    }
  }
}

private let entries: [(type: String, filename: String)] = [
  ("icp4", "icon_16x16.png"),
  ("ic11", "icon_16x16@2x.png"),
  ("icp5", "icon_32x32.png"),
  ("ic12", "icon_32x32@2x.png"),
  ("ic07", "icon_128x128.png"),
  ("ic13", "icon_128x128@2x.png"),
  ("ic08", "icon_256x256.png"),
  ("ic14", "icon_256x256@2x.png"),
  ("ic09", "icon_512x512.png"),
  ("ic10", "icon_512x512@2x.png"),
]
private let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

private func appendBigEndian(_ value: UInt32, to data: inout Data) {
  var value = value.bigEndian
  withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

func packICNS(iconsetURL: URL, outputURL: URL) throws {
  var chunks = Data()

  for entry in entries {
    let url = iconsetURL.appendingPathComponent(entry.filename)
    guard let png = try? Data(contentsOf: url) else {
      throw ICNSPackingError.missingIcon(entry.filename)
    }
    guard png.starts(with: pngSignature) else {
      throw ICNSPackingError.invalidPNG(entry.filename)
    }
    guard png.count <= Int(UInt32.max) - 8 else {
      throw ICNSPackingError.fileTooLarge(entry.filename)
    }

    chunks.append(contentsOf: entry.type.utf8)
    appendBigEndian(UInt32(png.count + 8), to: &chunks)
    chunks.append(png)
  }

  guard chunks.count <= Int(UInt32.max) - 8 else {
    throw ICNSPackingError.fileTooLarge(outputURL.lastPathComponent)
  }

  var container = Data("icns".utf8)
  appendBigEndian(UInt32(chunks.count + 8), to: &container)
  container.append(chunks)
  try container.write(to: outputURL, options: .atomic)
}

guard CommandLine.arguments.count == 3 else {
  throw ICNSPackingError.usage
}

try packICNS(
  iconsetURL: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true),
  outputURL: URL(fileURLWithPath: CommandLine.arguments[2])
)
print("Wrote \(CommandLine.arguments[2])")
