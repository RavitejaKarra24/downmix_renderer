import Foundation

enum PEQFilterKind: String, Sendable, Hashable {
  case peaking
  case lowShelf
  case highShelf
  case off
}

struct PEQBand: Sendable, Equatable, Hashable {
  var kind: PEQFilterKind
  var frequency: Double
  var gainDb: Double
  var q: Double
  var channel: PEQChannel

  enum PEQChannel: Sendable, Equatable, Hashable {
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

  /// Emits a deterministic Equalizer APO representation of the supported PEQ subset.
  ///
  /// Comments and unsupported directives are intentionally not represented by `ParsedPEQ`;
  /// callers that need lossless raw-text editing should retain the original source until a
  /// structured edit is committed.
  static func serialize(_ parsed: ParsedPEQ) -> String {
    var lines = ["Preamp: \(formatNumber(parsed.preampDb)) dB"]
    var currentChannel: PEQBand.PEQChannel = .all
    var filterNumber = 1

    for band in parsed.bands where band.kind != .off {
      if band.channel != currentChannel {
        lines.append("Channel: \(channelToken(band.channel))")
        currentChannel = band.channel
      }

      lines.append(
        "Filter \(filterNumber): ON \(kindToken(band.kind)) "
          + "Fc \(formatNumber(band.frequency)) Hz "
          + "Gain \(formatNumber(band.gainDb)) dB "
          + "Q \(formatNumber(max(band.q, 0.05)))"
      )
      filterNumber += 1
    }

    return lines.joined(separator: "\n") + "\n"
  }

  static func canonicalize(_ text: String) -> String {
    serialize(parse(text))
  }

  private static func stripComment(_ line: String) -> String {
    var commentStart = line.endIndex
    if let hash = line.firstIndex(of: "#") {
      commentStart = min(commentStart, hash)
    }
    if let slash = line.range(of: "//")?.lowerBound {
      commentStart = min(commentStart, slash)
    }
    return String(line[..<commentStart])
  }

  private static func parseChannelHeader(_ line: String) -> PEQBand.PEQChannel? {
    let compact = line.replacingOccurrences(of: " ", with: "").lowercased()
    let value: Substring
    if compact.hasPrefix("channel:") {
      value = compact.dropFirst("channel:".count)
    } else if compact.hasPrefix("ch:") {
      value = compact.dropFirst("ch:".count)
    } else {
      return nil
    }

    switch value {
    case "all", "*":
      return .all
    case "l", "left", "0":
      return .left
    case "r", "right", "1":
      return .right
    default:
      // Preserve the permissive forms accepted by the original parser (for example
      // "Channel: L R" and numeric headers with trailing punctuation).
      if value.hasPrefix("l") {
        return .left
      }
      if value.hasPrefix("r") {
        return .right
      }
      if let index = Int(value) {
        return .index(index)
      }
      if let number = firstNumber(in: String(value)) {
        return .index(Int(number))
      }
      return nil
    }
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

  private static func kindToken(_ kind: PEQFilterKind) -> String {
    switch kind {
    case .peaking: "PK"
    case .lowShelf: "LS"
    case .highShelf: "HS"
    case .off: "OFF"
    }
  }

  private static func channelToken(_ channel: PEQBand.PEQChannel) -> String {
    switch channel {
    case .all: "ALL"
    case .left: "L"
    case .right: "R"
    case .index(let index): String(index)
    }
  }

  private static func formatNumber(_ value: Double) -> String {
    guard value.isFinite else { return "0" }
    let normalized = abs(value) < 0.0000005 ? 0 : value
    let formatted = String(
      format: "%.6f",
      locale: Locale(identifier: "en_US_POSIX"),
      normalized
    )
    return
      formatted
      .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
  }
}
