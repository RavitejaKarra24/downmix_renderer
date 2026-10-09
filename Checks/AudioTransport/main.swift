import AudioToolbox
import Dispatch
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

func snapshot(_ diagnostics: AudioDiagnostics) -> EngineDiagnostics {
  diagnostics.snapshot(requested: 128, input: 256, output: 512)
}

let ring = FloatRingBuffer(capacity: 16)
let diagnostics = AudioDiagnostics()
let renderer = StereoOutputRenderer(ring: ring, diagnostics: diagnostics, maximumFrames: 4)
let source: [Float] = [0.1, 0.2, 0.3, 0.4]
source.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: $0.count) }
var output = [Float](repeating: 99, count: 8)
output.withUnsafeMutableBufferPointer { storage in
  var list = AudioBufferList(
    mNumberBuffers: 1,
    mBuffers: AudioBuffer(
      mNumberChannels: 2, mDataByteSize: 24, mData: storage.baseAddress!.advanced(by: 1))
  )
  require(renderer.render(frameCount: 3, bufferList: &list) == noErr, "partial read succeeds")
}
require(Array(output[1...4]) == source, "stereo samples retain order")
require(output[5] == 0 && output[6] == 0, "underrun suffix is silent")
require(output[0] == 99 && output[7] == 99, "render preserves byte-bound canaries")
require(snapshot(diagnostics).underrunCount == 1, "one underrun event per callback")
require(snapshot(diagnostics).underrunFrames == 1, "underrun frames, not samples")
require(snapshot(diagnostics).queuedFrames == 0, "queue snapshot follows consumer read")

source.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: $0.count) }
output.withUnsafeMutableBufferPointer { storage in
  var list = AudioBufferList(
    mNumberBuffers: 1,
    mBuffers: AudioBuffer(
      mNumberChannels: 2, mDataByteSize: 8, mData: storage.baseAddress!.advanced(by: 1))
  )
  require(renderer.render(frameCount: 1, bufferList: &list) == noErr, "complete read succeeds")
}
require(snapshot(diagnostics).queuedFrames == 1, "remaining queue fill uses complete stereo frames")
require(snapshot(diagnostics).underrunCount == 1, "complete reads do not count as underruns")

let silenceDiagnostics = AudioDiagnostics()
let keepAlive = StereoOutputRenderer(ring: nil, diagnostics: silenceDiagnostics, maximumFrames: 4)
output = [Float](repeating: 99, count: 8)
output.withUnsafeMutableBufferPointer { storage in
  var list = AudioBufferList(
    mNumberBuffers: 1,
    mBuffers: AudioBuffer(
      mNumberChannels: 2, mDataByteSize: 16, mData: storage.baseAddress!.advanced(by: 1))
  )
  require(keepAlive.render(frameCount: 2, bufferList: &list) == noErr, "keep-alive succeeds")
}
require(output[1...4].allSatisfy { $0 == 0 }, "keep-alive writes silence")
require(output[0] == 99 && output[5] == 99, "keep-alive respects byte bounds")
require(snapshot(silenceDiagnostics).underrunCount == 0, "deliberate silence is never an underrun")

output = [Float](repeating: 99, count: 8)
output.withUnsafeMutableBufferPointer { storage in
  var list = AudioBufferList(
    mNumberBuffers: 1,
    mBuffers: AudioBuffer(
      mNumberChannels: 2, mDataByteSize: 16, mData: storage.baseAddress!.advanced(by: 1))
  )
  require(
    renderer.render(frameCount: 5, bufferList: &list) == kAudioUnitErr_TooManyFramesToProcess,
    "oversized slice rejected")
}
require(output[1...4].allSatisfy { $0 == 0 }, "rejected slice silences the provided buffer only")
require(output[0] == 99 && output[5] == 99, "rejected slice preserves canaries")
require(snapshot(diagnostics).rejectedSliceCount == 1, "rejected slice counted")
require(
  diagnostics.takePendingFailure() == kAudioUnitErr_TooManyFramesToProcess,
  "control receives rejected-slice failure")
require(diagnostics.takePendingFailure() == noErr, "pending failure consumed exactly once")

output = [Float](repeating: 99, count: 8)
output.withUnsafeMutableBufferPointer { storage in
  var list = AudioBufferList(
    mNumberBuffers: 1,
    mBuffers: AudioBuffer(
      mNumberChannels: 1, mDataByteSize: 8, mData: storage.baseAddress!.advanced(by: 1))
  )
  require(
    renderer.render(frameCount: 2, bufferList: &list) == noErr, "invalid layout is safely silenced")
}
require(
  output[1] == 0 && output[2] == 0 && output[3] == 99, "invalid layout clears only advertised bytes"
)
require(
  snapshot(diagnostics).renderErrorCount == 1, "invalid layout is reported off the render thread")
require(
  diagnostics.takePendingFailure() == kAudioUnitErr_FormatNotSupported,
  "invalid layout exposes actionable error")

// Independently test byte capacity with an otherwise valid stereo format. This catches
// missing size checks even if the separate invalid-channel test still passes.
output = [Float](repeating: 99, count: 8)
output.withUnsafeMutableBufferPointer { storage in
  var list = AudioBufferList(
    mNumberBuffers: 1,
    mBuffers: AudioBuffer(
      mNumberChannels: 2, mDataByteSize: 8, mData: storage.baseAddress!.advanced(by: 1))
  )
  require(
    renderer.render(frameCount: 2, bufferList: &list) == noErr, "undersized stereo buffer is silent"
  )
}
require(
  output[1] == 0 && output[2] == 0 && output[0] == 99 && output[3] == 99,
  "undersized stereo buffer does not write beyond advertised capacity")
require(snapshot(diagnostics).renderErrorCount == 2, "undersized stereo buffer is reported")
require(
  diagnostics.takePendingFailure() == kAudioUnitErr_FormatNotSupported,
  "undersized buffer exposes format failure")

var nullList = AudioBufferList(
  mNumberBuffers: 1,
  mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 16, mData: nil)
)
require(
  renderer.render(frameCount: 2, bufferList: &nullList) == noErr,
  "null data is handled without dereference")
require(snapshot(diagnostics).renderErrorCount == 3, "null data reported off callback thread")
require(
  diagnostics.takePendingFailure() == kAudioUnitErr_FormatNotSupported,
  "null data exposes format failure")

// Multiple unexpected buffers must all be silent, rather than leaving a channel untouched.
let byteCount = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
let rawList = UnsafeMutableRawPointer.allocate(
  byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment)
defer { rawList.deallocate() }
let listPointer = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
listPointer.initialize(to: AudioBufferList(mNumberBuffers: 2, mBuffers: AudioBuffer()))
output = [Float](repeating: 99, count: 8)
output.withUnsafeMutableBufferPointer { storage in
  let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
  buffers[0] = AudioBuffer(
    mNumberChannels: 1, mDataByteSize: 8, mData: storage.baseAddress!.advanced(by: 1))
  buffers[1] = AudioBuffer(
    mNumberChannels: 1, mDataByteSize: 8, mData: storage.baseAddress!.advanced(by: 4))
  _ = renderer.render(frameCount: 2, bufferList: listPointer)
}
listPointer.deinitialize(count: 1)
require(
  output[1] == 0 && output[2] == 0 && output[4] == 0 && output[5] == 0,
  "unexpected planar buffers all silenced")
require(output[0] == 99 && output[3] == 99 && output[6] == 99, "multi-buffer canaries untouched")

let concurrent = AudioDiagnostics()
DispatchQueue.concurrentPerform(iterations: 1000) { _ in
  concurrent.recordUnderrun(frames: 2)
  concurrent.recordOverrun(frames: 3)
  concurrent.recordClipping(left: true, right: true)
}
let counts = snapshot(concurrent)
require(counts.underrunCount == 1000 && counts.overrunCount == 1000, "concurrent events never lost")
require(
  counts.underrunFrames == 2000 && counts.overrunFrames == 3000,
  "concurrent frame counts never lost")
require(
  counts.requestedBufferFrames == 128 && counts.inputBufferFrames == 256
    && counts.outputBufferFrames == 512,
  "diagnostics distinguish requested and negotiated buffers")
let clips = concurrent.takeClipping()
require(clips.left && clips.right, "clipping survives coalesced meter publications")
let clearedClips = concurrent.takeClipping()
require(!clearedClips.left && !clearedClips.right, "clipping resets only when UI consumes it")
concurrent.updateQueuedFrames(240)
require(snapshot(concurrent).queueLatencyMs == 5, "queue latency is buffered frames at 48 kHz")
concurrent.recordOverrun(frames: 0)
concurrent.recordUnderrun(frames: -1)
require(
  snapshot(concurrent).overrunCount == 1000 && snapshot(concurrent).underrunCount == 1000,
  "nonpositive transfers are not events")
require(
  snapshot(AudioDiagnostics())
    == EngineDiagnostics(
      requestedBufferFrames: 128, inputBufferFrames: 256, outputBufferFrames: 512),
  "new runs begin with zero counters")
// Exercise the actual renderer integration, not just the converter in isolation.
let correctedRing = FloatRingBuffer(capacity: 9600)
let correctedDiagnostics = AudioDiagnostics()
let correctedRenderer = StereoOutputRenderer(
  ring: correctedRing, diagnostics: correctedDiagnostics, maximumFrames: 128,
  driftCorrection: true, targetFrames: 512)
var correctedOutput = [Float](repeating: 99, count: 258)
@MainActor
func renderCorrected() {
  correctedOutput.withUnsafeMutableBufferPointer { storage in
    var list = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: 2, mDataByteSize: 128 * 8,
        mData: storage.baseAddress!.advanced(by: 1)))
    require(
      correctedRenderer.render(frameCount: 128, bufferList: &list) == noErr,
      "corrected render succeeds")
  }
  require(
    correctedOutput[0] == 99 && correctedOutput[257] == 99, "corrected render preserves canaries")
  require(
    correctedOutput[1...256].allSatisfy { $0.isFinite && abs($0) <= 1 },
    "converted hardware PCM is finite and bounded")
}
func fillCorrected(left: Float, right: Float, frames: Int = 1024) {
  var samples = [Float](repeating: 0, count: frames * 2)
  for frame in 0..<frames {
    samples[frame * 2] = left
    samples[frame * 2 + 1] = right
  }
  samples.withUnsafeBufferPointer {
    require(correctedRing.write($0.baseAddress!, count: $0.count) == $0.count, "fixture fits ring")
  }
}
renderCorrected()
require(correctedOutput[1...256].allSatisfy { $0 == 0 }, "initial priming is silent")
require(
  snapshot(correctedDiagnostics).isPriming && snapshot(correctedDiagnostics).driftCorrectionEnabled,
  "priming is observable")
require(
  snapshot(correctedDiagnostics).underrunCount == 0, "intentional initial priming is not a dropout")
fillCorrected(left: 1.5, right: -1.5)
for _ in 0..<4 { renderCorrected() }
require(!snapshot(correctedDiagnostics).isPriming, "sufficient reservoir completes priming")
require(
  correctedOutput[1] == 1 && correctedOutput[2] == -1,
  "reconstruction overshoot is safely saturated")
let postConversionClips = correctedDiagnostics.takeClipping()
require(
  postConversionClips.left && postConversionClips.right,
  "post-conversion clips survive for UI consumption")
require(
  snapshot(correctedDiagnostics).underrunCount == 0, "complete corrected callbacks are not dropouts"
)
for _ in 0..<12 { renderCorrected() }
let starved = snapshot(correctedDiagnostics)
require(starved.isPriming && starved.rebufferCount == 1, "starvation reprimes exactly once")
require(
  starved.underrunCount > 1 && starved.underrunFrames > 1024,
  "running starvation and all subsequent recovery silence are counted")
require(correctedOutput[1...256].allSatisfy { $0 == 0 }, "repriming does not replay old PCM")
for _ in 0..<10 { renderCorrected() }
require(
  snapshot(correctedDiagnostics).underrunFrames == starved.underrunFrames + 1280
    && snapshot(correctedDiagnostics).underrunCount == starved.underrunCount + 10,
  "every recovery-silence callback contributes its missing frames")
fillCorrected(left: 0, right: 0)
renderCorrected()
require(correctedOutput[1...256].allSatisfy { $0 == 0 }, "recovery cannot leak pre-gap FIR history")
require(
  !snapshot(correctedDiagnostics).isPriming && snapshot(correctedDiagnostics).rebufferCount == 1,
  "recovery retains diagnostic history")

// All advertised maximum slices must be able to prime with room for a producer
// burst, including drivers whose actual I/O size exceeds the requested 1024 frames.
for ioFrames in [32, 128, 512, 1024, 4096, 65_536] {
  let maximum = max(4096, ioFrames)
  let geometry = StereoOutputBuffering(
    inputFrames: ioFrames, outputFrames: ioFrames,
    maximumInputFrames: maximum, maximumOutputFrames: maximum)
  require(geometry.targetFrames >= ioFrames * 4, "reservoir covers hardware packet jitter")
  require(
    geometry.ringCapacityFrames > geometry.targetFrames + maximum * 2,
    "large supported slices can prime and absorb bursts")
}
let largeGeometry = StereoOutputBuffering(
  inputFrames: 1024, outputFrames: 1024, maximumInputFrames: 4096, maximumOutputFrames: 4096)
let largeRing = FloatRingBuffer(capacity: largeGeometry.ringCapacityFrames * 2)
let largeDiagnostics = AudioDiagnostics()
let largeRenderer = StereoOutputRenderer(
  ring: largeRing, diagnostics: largeDiagnostics, maximumFrames: 4096,
  driftCorrection: true, targetFrames: largeGeometry.targetFrames)
let largeSource = [Float](repeating: 0.1, count: (largeGeometry.targetFrames + 4096) * 2)
largeSource.withUnsafeBufferPointer {
  require(
    largeRing.write($0.baseAddress!, count: $0.count) == $0.count, "large priming threshold fits")
}
var largeOutput = [Float](repeating: 99, count: 4096 * 2 + 2)
largeOutput.withUnsafeMutableBufferPointer { storage in
  var list = AudioBufferList(
    mNumberBuffers: 1,
    mBuffers: AudioBuffer(
      mNumberChannels: 2, mDataByteSize: 4096 * 8, mData: storage.baseAddress!.advanced(by: 1)))
  require(
    largeRenderer.render(frameCount: 4096, bufferList: &list) == noErr,
    "maximum-size callback primes and renders")
}
require(
  !snapshot(largeDiagnostics).isPriming && snapshot(largeDiagnostics).underrunCount == 0,
  "no permanent large-slice priming")
require(
  largeOutput[0] == 99 && largeOutput.last == 99, "large corrected callback respects canaries")
require(abs(largeOutput[4000] - 0.1) < 0.00001, "large corrected callback preserves steady DC")

concurrent.updateClockCorrection(
  enabled: true, isPriming: true, correctionPPM: .nan, rebufferCount: 2)
require(snapshot(concurrent).correctionPPM == 0, "nonfinite diagnostic correction is sanitized")
concurrent.updateClockCorrection(
  enabled: true, isPriming: false, correctionPPM: 1e30, rebufferCount: 3)
require(
  snapshot(concurrent).correctionPPM == 2000 && snapshot(concurrent).rebufferCount == 3,
  "diagnostic correction is bounded")
print(
  "Audio transport checks passed (silence, canaries, layouts, counters, clipping, latency, clock correction integration)"
)
