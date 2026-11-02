import AudioToolbox

/// Real-time multichannel sample-rate conversion from the input device rate to the
/// fixed 48 kHz DSP rate.
///
/// AUHAL does not convert sample rates on the input side of a virtual device such as
/// BlackHole: with the device at 44.1 kHz, a 48 kHz client format makes every
/// `AudioUnitRender` fail with `kAudioUnitErr_CannotDoInCurrentContext` (-10863).
/// Downmix therefore opens the input at the device's own rate and converts here.
///
/// Ownership: built and destroyed on the audio control queue while the input unit is
/// stopped. `process` runs on the input render callback and never allocates, locks,
/// logs, or touches UI state. One converter is used by exactly one callback thread.
final class InputRateConverter {
  /// Internal DSP and stereo queue rate.
  static let outputSampleRate = 48_000.0
  /// Rates the converter is willing to open. Anything else is refused explicitly.
  static let supportedDeviceRates = 8_000.0...768_000.0
  /// Extra output frames allowed for converter priming inside one callback.
  private static let outputSlackFrames = 64

  fileprivate final class Feed {
    var input: UnsafePointer<Float>?
    var frames = 0
    var consumed = 0
    var channels = 0
  }

  let deviceRate: Double
  let channelCount: Int
  /// Output frames per input frame when fully primed.
  let ratio: Double

  private let converter: AudioConverterRef
  private let feed = Feed()
  private let feedPointer: UnsafeMutableRawPointer

  /// `nil` when the rate already matches: no converter, no added latency or CPU.
  init?(deviceRate: Double, channelCount: Int) {
    guard deviceRate.isFinite, Self.supportedDeviceRates.contains(deviceRate),
      channelCount > 0, channelCount <= 512
    else { return nil }
    guard deviceRate != Self.outputSampleRate else { return nil }

    var input = Self.format(rate: deviceRate, channels: channelCount)
    var output = Self.format(rate: Self.outputSampleRate, channels: channelCount)
    var created: AudioConverterRef?
    guard AudioConverterNew(&input, &output, &created) == noErr, let created else {
      return nil
    }
    // Quality property is advisory; a refusal keeps Apple's default converter.
    var complexity = kAudioConverterSampleRateConverterComplexity_Mastering
    _ = AudioConverterSetProperty(
      created, kAudioConverterSampleRateConverterComplexity,
      UInt32(MemoryLayout<UInt32>.size), &complexity)

    self.converter = created
    self.deviceRate = deviceRate
    self.channelCount = channelCount
    ratio = Self.outputSampleRate / deviceRate
    feed.channels = channelCount
    feedPointer = Unmanaged.passUnretained(feed).toOpaque()
  }

  deinit {
    AudioConverterDispose(converter)
  }

  /// Frames a fully primed converter produces for one callback of `frameCount` frames.
  func convertedFrames(forInputFrames frameCount: Int) -> Int {
    guard frameCount > 0 else { return 0 }
    return Int((Double(frameCount) * ratio).rounded(.up))
  }

  /// Storage a single `process` call may write.
  func outputCapacity(forInputFrames frameCount: Int) -> Int {
    convertedFrames(forInputFrames: frameCount) + Self.outputSlackFrames
  }

  /// Warms converter state on the control thread. Call once after construction, while
  /// the input unit is stopped, so the first render callback does not pay for any
  /// internal converter setup.
  func prime() {
    let frames = 128
    let capacity = outputCapacity(forInputFrames: frames)
    let input = [Float](repeating: 0, count: frames * channelCount)
    var output = [Float](repeating: 0, count: capacity * channelCount)
    input.withUnsafeBufferPointer { inBuffer in
      output.withUnsafeMutableBufferPointer { outBuffer in
        _ = process(
          input: inBuffer.baseAddress!, frameCount: frames,
          output: outBuffer.baseAddress!, capacity: capacity)
      }
    }
  }

  /// Converts one interleaved block. Returns the produced 48 kHz frames; the caller
  /// treats no output as priming silence and never reorders across calls.
  func process(
    input: UnsafePointer<Float>,
    frameCount: Int,
    output: UnsafeMutablePointer<Float>,
    capacity: Int
  ) -> Int {
    guard frameCount > 0, capacity > 0 else { return 0 }
    feed.input = input
    feed.frames = frameCount
    feed.consumed = 0
    defer {
      feed.input = nil
      feed.frames = 0
      feed.consumed = 0
    }

    var produced = 0
    while produced < capacity {
      var requested = UInt32(capacity - produced)
      var list = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: UInt32(channelCount),
          mDataByteSize: UInt32((capacity - produced) * channelCount * MemoryLayout<Float>.size),
          mData: UnsafeMutableRawPointer(mutating: output.advanced(by: produced * channelCount))
        )
      )
      let status = AudioConverterFillComplexBuffer(
        converter, supplyInputForRateConversion, feedPointer, &requested, &list, nil)
      produced += Int(requested)
      guard status == noErr else { break }
      // A priming converter can need another call for the same block. Only continue
      // when the converter made progress, so a stalled converter cannot spin here.
      if feed.consumed >= frameCount || requested == 0 { break }
    }
    return min(produced, capacity)
  }

  private static func format(rate: Double, channels: Int) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
      mSampleRate: rate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        | kAudioFormatFlagsNativeEndian,
      mBytesPerPacket: UInt32(MemoryLayout<Float>.size * channels),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(MemoryLayout<Float>.size * channels),
      mChannelsPerFrame: UInt32(channels),
      mBitsPerChannel: 32,
      mReserved: 0
    )
  }
}

/// Pull callback: hands the converter the current block, never allocates.
private func supplyInputForRateConversion(
  _ converter: AudioConverterRef,
  _ packets: UnsafeMutablePointer<UInt32>,
  _ ioData: UnsafeMutablePointer<AudioBufferList>,
  _ description: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
  _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let userData else {
    packets.pointee = 0
    return noErr
  }
  let feed = Unmanaged<InputRateConverter.Feed>.fromOpaque(userData).takeUnretainedValue()
  let available = max(0, feed.frames - feed.consumed)
  let frames = min(Int(packets.pointee), available)
  ioData.pointee.mNumberBuffers = 1
  ioData.pointee.mBuffers.mNumberChannels = UInt32(feed.channels)
  ioData.pointee.mBuffers.mData =
    frames > 0
    ? UnsafeMutableRawPointer(mutating: feed.input!.advanced(by: feed.consumed * feed.channels))
    : nil
  ioData.pointee.mBuffers.mDataByteSize =
    UInt32(frames * feed.channels * MemoryLayout<Float>.size)
  feed.consumed += frames
  packets.pointee = UInt32(frames)
  return noErr
}
