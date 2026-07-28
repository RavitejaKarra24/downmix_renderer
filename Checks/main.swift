import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

let peqText = """
  Preamp: -6.0 dB
  Filter: ON PK Fc 100 Hz Gain -3.5 dB Q 1.2
  Filter: ON LS Fc 80 Hz Gain 2 dB Q 0.7
  Filter: OFF PK Fc 1000 Hz Gain 1 dB Q 1
  Channel: L
  Filter: ON HS Fc 8000 Hz Gain -1 dB Q 0.7
  """
let parsed = PEQParser.parse(peqText)
require(parsed.preampDb == -6, "PEQ preamp")
require(parsed.bands.count == 3, "PEQ active filter count")
require(parsed.bands[0].kind == .peaking, "peaking filter")
require(parsed.bands[0].frequency == 100, "peaking frequency")
require(parsed.bands[1].kind == .lowShelf, "low shelf")
require(parsed.bands[2].kind == .highShelf, "high shelf")
require(parsed.bands[2].channel == .left, "channel section")

var processor = DownmixProcessor()
var silence = [Float](repeating: 0, count: 16 * 256)
var output = [Float](repeating: 1, count: 2 * 256)
silence.withUnsafeBufferPointer { inputBuffer in
  output.withUnsafeMutableBufferPointer { outputBuffer in
    processor.process(
      input: inputBuffer.baseAddress!,
      inputChannelCount: 16,
      output: outputBuffer.baseAddress!,
      frameCount: 256
    )
  }
}
require(output.allSatisfy { abs($0) < 0.000001 }, "silence remains silent")

let lowpass = BiquadDesign.lowPass(freq: 125, q: 0.541196100146197, sampleRate: 48_000)
require(lowpass.b0.isFinite && lowpass.a1.isFinite, "low-pass coefficients are finite")
require(DownmixProcessor.lfeCoefficient == 2.26464431, "original LFE coefficient")

print("DSP checks passed")
