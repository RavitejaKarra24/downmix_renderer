import Foundation

struct PEQFilterDraft: Identifiable, Equatable {
  let id: UUID
  var kind: PEQFilterKind
  var frequency: Double
  var gainDb: Double
  var q: Double
  var channel: PEQBand.PEQChannel

  init(id: UUID = UUID(), band: PEQBand) {
    self.id = id
    kind = band.kind
    frequency = band.frequency
    gainDb = band.gainDb
    q = band.q
    channel = band.channel
  }

  init(id: UUID = UUID(), channel: PEQBand.PEQChannel = .all) {
    self.init(
      id: id,
      band: PEQBand(
        kind: .peaking,
        frequency: 1_000,
        gainDb: 0,
        q: 1,
        channel: channel
      )
    )
  }

  var band: PEQBand {
    PEQBand(
      kind: kind,
      frequency: frequency,
      gainDb: gainDb,
      q: max(q, 0.05),
      channel: channel
    )
  }

  var validationMessage: String? {
    if !frequency.isFinite || frequency <= 0 || frequency >= PEQResponseCalculator.nyquist {
      return "Frequency must be above 0 Hz and below 24 kHz."
    }
    if !gainDb.isFinite {
      return "Gain must be a finite number."
    }
    if !q.isFinite || q < 0.05 {
      return "Q must be at least 0.05."
    }
    return nil
  }
}

struct PEQResponseSnapshot: Equatable {
  static let empty = PEQResponseSnapshot(frequencies: [], leftDb: [], rightDb: [])

  var frequencies: [Double]
  var leftDb: [Double]
  var rightDb: [Double]

  var rangeDescription: String {
    let values = leftDb + rightDb
    guard let minimum = values.min(), let maximum = values.max() else {
      return "No response data"
    }
    return
      "\(PEQResponseCalculator.formatDb(minimum)) to "
      + "\(PEQResponseCalculator.formatDb(maximum))"
  }
}

struct PEQEditorDraft: Equatable {
  var preampDb: Double {
    didSet { rebuildResponse() }
  }
  var filters: [PEQFilterDraft] {
    didSet { rebuildResponse() }
  }
  private(set) var response: PEQResponseSnapshot

  init(text: String) {
    let parsed = PEQParser.parse(text)
    preampDb = parsed.preampDb
    filters = parsed.bands.map { PEQFilterDraft(band: $0) }
    response = .empty
    rebuildResponse()
  }

  var parsed: ParsedPEQ {
    ParsedPEQ(preampDb: preampDb, bands: filters.map(\.band))
  }

  var serializedText: String {
    PEQParser.serialize(parsed)
  }

  mutating func replace(with text: String) {
    let parsed = PEQParser.parse(text)
    let oldIDs = filters.map(\.id)
    preampDb = parsed.preampDb
    filters = parsed.bands.enumerated().map { index, band in
      PEQFilterDraft(id: index < oldIDs.count ? oldIDs[index] : UUID(), band: band)
    }
    rebuildResponse()
  }

  mutating func addFilter(channel: PEQBand.PEQChannel = .all) {
    filters.append(PEQFilterDraft(channel: channel))
  }

  mutating func removeFilter(id: PEQFilterDraft.ID) {
    filters.removeAll { $0.id == id }
  }

  mutating func moveFilter(id: PEQFilterDraft.ID, offset: Int) {
    guard let source = filters.firstIndex(where: { $0.id == id }) else { return }
    let destination = source + offset
    guard filters.indices.contains(destination) else { return }
    filters.swapAt(source, destination)
  }

  private mutating func rebuildResponse() {
    response = PEQResponseCalculator.makeSnapshot(for: parsed)
  }
}

enum PEQPreviewSide: Equatable {
  case left
  case right
}

enum PEQResponseCalculator {
  static let sampleRate = 48_000.0
  static let nyquist = sampleRate / 2
  static let minimumFrequency = 20.0
  static let maximumFrequency = 20_000.0

  static func makeSnapshot(for parsed: ParsedPEQ, sampleCount: Int = 161)
    -> PEQResponseSnapshot
  {
    let count = max(sampleCount, 2)
    let logMinimum = log10(minimumFrequency)
    let logSpan = log10(maximumFrequency) - logMinimum
    let frequencies = (0..<count).map { index in
      pow(10, logMinimum + (Double(index) / Double(count - 1)) * logSpan)
    }

    return PEQResponseSnapshot(
      frequencies: frequencies,
      leftDb: response(for: parsed, side: .left, frequencies: frequencies),
      rightDb: response(for: parsed, side: .right, frequencies: frequencies)
    )
  }

  static func formatDb(_ value: Double) -> String {
    let rounded = value.rounded(toPlaces: 1)
    let prefix = rounded > 0 ? "+" : ""
    return "\(prefix)\(rounded.formatted(.number.precision(.fractionLength(1)))) dB"
  }

  private static func response(
    for parsed: ParsedPEQ,
    side: PEQPreviewSide,
    frequencies: [Double]
  ) -> [Double] {
    let coefficients = parsed.bands.compactMap { band -> BiquadCoefficients? in
      guard applies(band.channel, to: side),
        band.frequency.isFinite,
        band.frequency > 0,
        band.frequency < nyquist,
        band.gainDb.isFinite,
        band.q.isFinite
      else {
        return nil
      }

      switch band.kind {
      case .peaking:
        return BiquadDesign.peaking(
          freq: band.frequency,
          q: band.q,
          gainDb: band.gainDb,
          sampleRate: sampleRate
        )
      case .lowShelf:
        return BiquadDesign.lowShelf(
          freq: band.frequency,
          q: band.q,
          gainDb: band.gainDb,
          sampleRate: sampleRate
        )
      case .highShelf:
        return BiquadDesign.highShelf(
          freq: band.frequency,
          q: band.q,
          gainDb: band.gainDb,
          sampleRate: sampleRate
        )
      case .off:
        return nil
      }
    }

    return frequencies.map { frequency in
      var db = parsed.preampDb.isFinite ? parsed.preampDb : 0
      for coefficient in coefficients {
        db += magnitudeDb(of: coefficient, at: frequency)
      }
      return db.isFinite ? db : 0
    }
  }

  private static func applies(_ channel: PEQBand.PEQChannel, to side: PEQPreviewSide) -> Bool {
    switch channel {
    case .all:
      return true
    case .left:
      return side == .left
    case .right:
      return side == .right
    case .index(let index):
      return (side == .left && index == 0) || (side == .right && index == 1)
    }
  }

  private static func magnitudeDb(
    of coefficients: BiquadCoefficients,
    at frequency: Double
  ) -> Double {
    let omega = 2 * Double.pi * frequency / sampleRate
    let cosOne = cos(omega)
    let sinOne = sin(omega)
    let cosTwo = cos(2 * omega)
    let sinTwo = sin(2 * omega)

    let numeratorReal =
      coefficients.b0 + coefficients.b1 * cosOne + coefficients.b2 * cosTwo
    let numeratorImaginary = -coefficients.b1 * sinOne - coefficients.b2 * sinTwo
    let denominatorReal = 1 + coefficients.a1 * cosOne + coefficients.a2 * cosTwo
    let denominatorImaginary = -coefficients.a1 * sinOne - coefficients.a2 * sinTwo

    let numeratorMagnitudeSquared =
      numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary
    let denominatorMagnitudeSquared =
      denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary
    guard numeratorMagnitudeSquared.isFinite,
      denominatorMagnitudeSquared.isFinite,
      denominatorMagnitudeSquared > 1e-24
    else {
      return 0
    }

    let magnitude = sqrt(max(numeratorMagnitudeSquared / denominatorMagnitudeSquared, 1e-24))
    return 20 * log10(magnitude)
  }
}

extension Double {
  fileprivate func rounded(toPlaces places: Int) -> Double {
    let factor = pow(10, Double(places))
    return (self * factor).rounded() / factor
  }
}
