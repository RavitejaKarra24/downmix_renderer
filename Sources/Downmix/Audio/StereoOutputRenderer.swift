import AudioToolbox
import Foundation

/// Pre-start buffer geometry. The reservoir is post-callback audio, not ring capacity.
/// Reserve both maximum slices so a supported large callback can actually prime and
/// a producer burst fits while the independent consumer renders. Never resize live.
struct StereoOutputBuffering {
  static let maximumSliceFrames = 65_536
  let targetFrames: Int
  let ringCapacityFrames: Int

  init(inputFrames: Int, outputFrames: Int, maximumInputFrames: Int, maximumOutputFrames: Int) {
    precondition(inputFrames >= 0 && outputFrames > 0)
    precondition(maximumInputFrames >= inputFrames && maximumOutputFrames >= outputFrames)
    precondition(maximumInputFrames <= Self.maximumSliceFrames)
    precondition(maximumOutputFrames <= Self.maximumSliceFrames)
    // The 100 ppm/s clock slew needs startup/reversal headroom; a 512-frame
    // reservoir can repeatedly starve before learning a supported negative skew.
    targetFrames = max(
      AdaptiveStereoResampler.minimumRecommendedTargetFrames, 4 * max(inputFrames, outputFrames))
    let maximumConsumption = Int(ceil(Double(maximumOutputFrames) * 1.002))
    ringCapacityFrames = max(4800, targetFrames + maximumInputFrames + maximumConsumption + 64)
  }
}

/// One output callback consumer per instance. Lifetime extends beyond callback quiescence.
/// Storage, ring and diagnostics are created on the control thread, never inside render().
final class StereoOutputRenderer {
  private let ring: FloatRingBuffer?
  private let diagnostics: AudioDiagnostics
  private let maximumFrames: UInt32
  private let resampler: AdaptiveStereoResampler?

  init(
    ring: FloatRingBuffer?, diagnostics: AudioDiagnostics, maximumFrames: UInt32,
    driftCorrection: Bool = false, targetFrames: Int = 2048
  ) {
    self.ring = ring
    self.diagnostics = diagnostics
    self.maximumFrames = maximumFrames
    if driftCorrection, let ring {
      resampler = AdaptiveStereoResampler(
        ring: ring, targetFrames: targetFrames, maximumOutputFrames: Int(maximumFrames)
      )
    } else {
      resampler = nil
    }
  }

  func render(frameCount: UInt32, bufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    guard frameCount <= maximumFrames else {
      Self.silence(buffers)
      diagnostics.recordRejectedSlice(error: kAudioUnitErr_TooManyFramesToProcess)
      return kAudioUnitErr_TooManyFramesToProcess
    }
    guard frameCount > 0 else { return noErr }
    let needed = Int(frameCount) * 2
    guard buffers.count == 1, let first = buffers.first, first.mNumberChannels == 2,
      Int(first.mDataByteSize) >= needed * MemoryLayout<Float>.size,
      let data = first.mData
    else {
      Self.silence(buffers)
      diagnostics.recordRenderError(kAudioUnitErr_FormatNotSupported)
      return noErr
    }
    // A nil ring is deliberate keep-alive. Silence is not an underrun.
    guard let ring else {
      Self.silence(buffers)
      return noErr
    }
    let destination = data.assumingMemoryBound(to: Float.self)
    if let resampler {
      let wasPriming = resampler.isPriming
      let previousRebuffers = resampler.rebufferCount
      let produced = resampler.render(into: destination, frameCount: Int(frameCount))
      if produced < Int(frameCount) {
        destination.advanced(by: produced * 2).update(repeating: 0, count: needed - produced * 2)
        // Initial intentional priming is not a dropout. Once running, starvation and
        // its missing suffix count even though the converter has re-entered priming.
        if !wasPriming || previousRebuffers > 0 || resampler.rebufferCount > previousRebuffers {
          diagnostics.recordUnderrun(frames: Int(frameCount) - produced)
        }
      }
      // A reconstruction filter can overshoot otherwise bounded PCM. Keep hardware
      // output finite/in-range and latch post-conversion clipping for the UI.
      var clippedL = false
      var clippedR = false
      for frame in 0..<produced {
        let left = destination[frame * 2]
        let right = destination[frame * 2 + 1]
        clippedL = clippedL || (left.isFinite && abs(left) > 1)
        clippedR = clippedR || (right.isFinite && abs(right) > 1)
        destination[frame * 2] = left.isFinite ? min(1, max(-1, left)) : 0
        destination[frame * 2 + 1] = right.isFinite ? min(1, max(-1, right)) : 0
      }
      diagnostics.recordClipping(left: clippedL, right: clippedR)
      diagnostics.updateQueuedFrames(resampler.bufferedFrames)
      diagnostics.updateClockCorrection(
        enabled: true, isPriming: resampler.isPriming,
        correctionPPM: resampler.correctionPPM, rebufferCount: resampler.rebufferCount
      )
      return noErr
    }
    let read = ring.read(into: destination, count: needed)
    if read < needed {
      destination.advanced(by: read).update(repeating: 0, count: needed - read)
      diagnostics.recordUnderrun(frames: (needed - read) / 2)
    }
    diagnostics.updateQueuedFrames(ring.availableToRead / 2)
    return noErr
  }

  static func silence(_ buffers: UnsafeMutableAudioBufferListPointer) {
    for buffer in buffers {
      if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
  }
}
