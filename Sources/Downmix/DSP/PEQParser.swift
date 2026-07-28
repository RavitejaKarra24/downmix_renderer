import Foundation

enum PEQFilterKind: String, Sendable {
  case peaking
  case lowShelf
  case highShelf
  case off
}

struct PEQBand: Sendable, Equatable {
  var kind: PEQFilterKind
  var frequency: Double
  var gainDb: Double
  var q: Double
  var channel: PEQChannel

  enum PEQChannel: Sendable, Equatable {
    case all
    case left
    case right
    case index(Int)
  }
}

struct ParsedPEQ: Sendable, Equatable {
  var preampDb: Double = 0
  var bands: [PEQBand] = []
}

enum PEQParser {
  static func parse(_ text: String) -> ParsedPEQ {
    var result = ParsedPEQ()
    var currentChannel: PEQBand.PEQChannel = .all

    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }

      let lower = line.lowercased()
      if lower.hasPrefix("preamp:") || lower.hasPrefix("preamp ") {
        if let value = firstNumber(in: line) {
          result.preampDb = value
        }
        continue
      }

      if let channel = parseChannelHeader(line) {
        currentChannel = channel
        continue
      }

      if lower.contains("xfeed") || lower.contains("graphic eq") {
        continue
      }

      if let band = parseFilterLine(line, channel: currentChannel), band.kind != .off {
        result.bands.append(band)
      }
    }
    return result
  }

  private static func stripComment(_ line: String) -> String {
    if let idx = line.firstIndex(of: "#") {
      return String(line[..<idx])
    }
    if let idx = line.range(of: "//")?.lowerBound {
      return String(line[..<idx])
    }
    return line
  }

  private static func parseChannelHeader(_ line: String) -> PEQBand.PEQChannel? {
    let compact = line.replacingOccurrences(of: " ", with: "").lowercased()
    if compact.hasPrefix("channel:l") || compact.hasPrefix("ch:l") || compact == "channel:0"
      || compact == "ch:0"
    {
      return .left
    }
    if compact.hasPrefix("channel:r") || compact.hasPrefix("ch:r") || compact == "channel:1"
      || compact == "ch:1"
    {
      return .right
    }
    if compact.hasPrefix("channel:") || compact.hasPrefix("ch:") {
      if let number = firstNumber(in: line) {
        return .index(Int(number))
      }
    }
    return nil
  }

  private static func parseFilterLine(_ line: String, channel: PEQBand.PEQChannel) -> PEQBand? {
    let tokens = tokenize(line)
    guard !tokens.isEmpty else { return nil }

    // Equalizer APO style:
    // Filter: ON PK Fc 100 Hz Gain -3 dB Q 1.0
    // Filter 1: ON LS Fc 80 Hz Gain 2 dB Q 0.7
    let upperTokens = tokens.map { $0.uppercased() }
    if upperTokens.contains("OFF") {
      return PEQBand(kind: .off, frequency: 0, gainDb: 0, q: 1, channel: channel)
    }

    let kind: PEQFilterKind
    if upperTokens.contains("PK") || upperTokens.contains("PEQ") || upperTokens.contains("PEAKING")
      || upperTokens.contains("EQ")
    {
      kind = .peaking
    } else if upperTokens.contains("LS") || upperTokens.contains("LSC")
      || upperTokens.contains("LOWSHELF") || upperTokens.contains("LOW-SHELF")
    {
      kind = .lowShelf
    } else if upperTokens.contains("HS") || upperTokens.contains("HSC")
      || upperTokens.contains("HIGHSHELF") || upperTokens.contains("HIGH-SHELF")
    {
      kind = .highShelf
    } else if line.lowercased().contains("filter") {
      // Unknown filter type — ignore rather than mis-apply.
      return nil
    } else {
      return nil
    }

    let fc = valueAfter(keys: ["FC", "F"], in: tokens) ?? firstNumber(in: line) ?? 1000
    let gain = valueAfter(keys: ["GAIN", "G"], in: tokens) ?? 0
    let q = valueAfter(keys: ["Q", "BW"], in: tokens) ?? 1.0

    return PEQBand(kind: kind, frequency: fc, gainDb: gain, q: max(q, 0.05), channel: channel)
  }

  private static func tokenize(_ line: String) -> [String] {
    line
      .replacingOccurrences(of: ":", with: " ")
      .replacingOccurrences(of: ",", with: " ")
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
  }

  private static func valueAfter(keys: [String], in tokens: [String]) -> Double? {
    for (index, token) in tokens.enumerated() {
      let upper = token.uppercased()
      if keys.contains(upper), index + 1 < tokens.count {
        if let value = Double(
          tokens[index + 1].replacingOccurrences(of: "dB", with: "", options: .caseInsensitive))
        {
          return value
        }
      }
      for key in keys where upper.hasPrefix(key) && upper.count > key.count {
        let rest = String(upper.dropFirst(key.count))
        if let value = Double(rest) { return value }
      }
    }
    return nil
  }

  private static func firstNumber(in text: String) -> Double? {
    let pattern = #"-?\d+(?:\.\d+)?"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
      let swiftRange = Range(match.range, in: text)
    else { return nil }
    return Double(text[swiftRange])
  }
}
