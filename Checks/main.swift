import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

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
