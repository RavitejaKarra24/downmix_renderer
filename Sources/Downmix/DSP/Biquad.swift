import Foundation

struct BiquadCoefficients: Sendable, Equatable {
  var b0: Double
  var b1: Double
  var b2: Double
  var a1: Double
  var a2: Double

  static let passthrough = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
}

struct BiquadFilter: Sendable {
  var coefficients: BiquadCoefficients = .passthrough
  private var z1 = 0.0
  private var z2 = 0.0

  mutating func reset() {
    z1 = 0
    z2 = 0
  }

  mutating func process(_ input: Double) -> Double {
    let c = coefficients
    let output = c.b0 * input + z1
    z1 = c.b1 * input - c.a1 * output + z2
    z2 = c.b2 * input - c.a2 * output
    return output
  }
}

enum BiquadDesign {
  static func peaking(freq: Double, q: Double, gainDb: Double, sampleRate: Double)
    -> BiquadCoefficients
  {
    let a = pow(10.0, gainDb / 40.0)
    let w0 = 2.0 * .pi * freq / sampleRate
    let alpha = sin(w0) / (2.0 * max(q, 0.05))
    let cosw = cos(w0)

    let b0 = 1 + alpha * a
    let b1 = -2 * cosw
    let b2 = 1 - alpha * a
    let a0 = 1 + alpha / a
    let a1 = -2 * cosw
    let a2 = 1 - alpha / a
    return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
  }

  static func lowShelf(freq: Double, q: Double, gainDb: Double, sampleRate: Double)
    -> BiquadCoefficients
  {
    let a = pow(10.0, gainDb / 40.0)
    let w0 = 2.0 * .pi * freq / sampleRate
    let cosw = cos(w0)
    let sinw = sin(w0)
    let alpha = sinw / (2.0 * max(q, 0.05))
    let twoSqrtAAlpha = 2 * sqrt(a) * alpha

    let b0 = a * ((a + 1) - (a - 1) * cosw + twoSqrtAAlpha)
    let b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
    let b2 = a * ((a + 1) - (a - 1) * cosw - twoSqrtAAlpha)
    let a0 = (a + 1) + (a - 1) * cosw + twoSqrtAAlpha
    let a1 = -2 * ((a - 1) + (a + 1) * cosw)
    let a2 = (a + 1) + (a - 1) * cosw - twoSqrtAAlpha
    return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
  }

  static func highShelf(freq: Double, q: Double, gainDb: Double, sampleRate: Double)
    -> BiquadCoefficients
  {
    let a = pow(10.0, gainDb / 40.0)
    let w0 = 2.0 * .pi * freq / sampleRate
    let cosw = cos(w0)
    let sinw = sin(w0)
    let alpha = sinw / (2.0 * max(q, 0.05))
    let twoSqrtAAlpha = 2 * sqrt(a) * alpha

    let b0 = a * ((a + 1) + (a - 1) * cosw + twoSqrtAAlpha)
    let b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
    let b2 = a * ((a + 1) + (a - 1) * cosw - twoSqrtAAlpha)
    let a0 = (a + 1) - (a - 1) * cosw + twoSqrtAAlpha
    let a1 = 2 * ((a - 1) - (a + 1) * cosw)
    let a2 = (a + 1) - (a - 1) * cosw - twoSqrtAAlpha
    return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
  }

  /// Butterworth low-pass cascade section helper (RBJ cookbook style with Q).
  static func lowPass(freq: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
    let w0 = 2.0 * .pi * freq / sampleRate
    let cosw = cos(w0)
    let sinw = sin(w0)
    let alpha = sinw / (2.0 * max(q, 0.05))

    let b0 = (1 - cosw) / 2
    let b1 = 1 - cosw
    let b2 = (1 - cosw) / 2
    let a0 = 1 + alpha
    let a1 = -2 * cosw
    let a2 = 1 - alpha
    return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
  }

  private static func normalize(
    b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double
  ) -> BiquadCoefficients {
    let inv = 1.0 / a0
    return BiquadCoefficients(
      b0: b0 * inv,
      b1: b1 * inv,
      b2: b2 * inv,
      a1: a1 * inv,
      a2: a2 * inv
    )
  }
}
