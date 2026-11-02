import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

enum EnginePhase: String, Sendable {
  case stopped
  case starting
  case running
  case keepAlive
  case stopping
  case error
}

struct EngineStatus: Sendable, Equatable {
  var phase: EnginePhase = .stopped
  var message: String = "Idle"
  var meters: MeterSnapshot = .empty
  var diagnostics: EngineDiagnostics = .empty
  /// Bed layout advertisement for the input device of this run: `nil` when the run has
  /// no 16-channel input, `false` when the HAL refused the layout change.
  var bedLayoutInstalled: Bool?
  /// Live input format of this run. `nil` while stopped or erroring.
  var inputSampleRate: Double?
  var inputChannelCount: Int?
  /// Rate the DSP and stereo output client run at. Equals `inputSampleRate` for
  /// passthrough, or the fallback when the output device refuses the input rate.
  var renderSampleRate: Double?
}

/// Dual-device Core Audio engine: multi-channel input → DSP → stereo output.
/// Control, HAL setup/teardown, route checks and status delivery belong to ONE serial queue.
/// Unchecked Sendable expresses this GCD confinement, not permission for concurrent calls.
/// HAL callbacks own fixed resources/DSP while running; queue mutates them only at quiescence.
/// The per-run gate is the sole main-writable object and remains retained until disposal.
final class AudioEngine: @unchecked Sendable {
  static let targetSampleRate: Double = 48_000

  private let logger = Logger(subsystem: "com.local.downmix", category: "AudioEngine")
  private let queue: DispatchQueue
  private var renderGate: AudioRenderGate?
  // If HAL refuses disposal, deliberately retain callback storage rather than leave a
  // dangling unretained refCon. A subsequent successful stop breaks this safety cycle.
  private var retainedForCallbacks: AudioEngine?

  init(queue: DispatchQueue) {
    self.queue = queue
  }

  // Worker-queue control publishes fixed-size configuration. Only the input callback
  // owns processor state while running; UI consumes fixed-size meter publications.
  private let configurationMailbox = RealtimeMailbox(
    DownmixProcessor.RealtimeConfiguration(DownmixProcessor.Configuration()))
  private let meterMailbox = RealtimeMailbox(RealtimeMeterSnapshot.empty)
  private var audioDiagnostics = AudioDiagnostics()
  private var outputRenderer: StereoOutputRenderer?
  private var latestMeterSnapshot = RealtimeMeterSnapshot.empty
  private var framesSinceMeterPublish = 0
  private var negotiatedInputFrames = 0
  private var negotiatedOutputFrames = 0

  private var inputUnit: AudioComponentInstance?
  private var outputUnit: AudioComponentInstance?
  private var ring: FloatRingBuffer?
  private var processor = DownmixProcessor()
  private var configuration = DownmixProcessor.Configuration()
  private var inputChannels = 16
  /// Client format rate of the input unit. The HAL cannot convert virtual-device
  /// input rates, so the input follows the device.
  private var inputDeviceRate = AudioEngine.targetSampleRate
  /// Rate the DSP, stereo queue and output client run at. Normally the input device's
  /// rate (passthrough); the 48 kHz default only appears when the DAC refuses it.
  private var pipelineRate = AudioEngine.targetSampleRate
  private var meterPublishFrames = 4_800
  private var lastOutputRateNotice: Double?
  private var inputRateConverter: InputRateConverter?
  private var convertedInput = [Float]()
  private var maximumConvertedFrames = 0
  private var framesPerBuffer: UInt32 = 128
  private var expectedInputDeviceID = AudioDeviceID(kAudioObjectUnknown)
  private var expectedOutputDeviceID = AudioDeviceID(kAudioObjectUnknown)
  private var expectedOutputInfo: AudioDeviceInfo?
  private var expectedInputUID = ""
  private var maximumInputFrames: UInt32 = 0
  private var maximumOutputFrames: UInt32 = 0
  private var isRunning = false
  private var keepAliveOnly = false

  private var status = EngineStatus()
  private var onStatus: (@Sendable (EngineStatus) -> Void)?

  func setStatusHandler(_ handler: @escaping @Sendable (EngineStatus) -> Void) {
    dispatchPrecondition(condition: .onQueue(queue))
    onStatus = handler
  }

  var currentStatus: EngineStatus {
    dispatchPrecondition(condition: .onQueue(queue))
    return status
  }

  var finalDiagnostics: EngineDiagnostics {
    dispatchPrecondition(condition: .onQueue(queue))
    var snapshot = diagnosticsSnapshot()
    if !isRunning {
      snapshot.queuedFrames = 0
      snapshot.isPriming = false
    }
    return snapshot
  }

  func start(
    inputDeviceID: AudioDeviceID,
    outputDeviceID: AudioDeviceID,
    configuration: DownmixProcessor.Configuration,
    framesPerBuffer: Int,
    keepAliveOnly: Bool = false,
    renderGate: AudioRenderGate? = nil
  ) throws {
    dispatchPrecondition(condition: .onQueue(queue))
    dispatchPrecondition(condition: .notOnQueue(.main))
    do {
      try stopInternal(notify: false)
      self.renderGate = renderGate ?? AudioRenderGate()
      guard self.renderGate?.isOpen == true else { return }

      logger.info(
        "Start requested: input=\(inputDeviceID), output=\(outputDeviceID), frames=\(framesPerBuffer), keepAlive=\(keepAliveOnly)"
      )
      publish(phase: .starting, message: "Opening audio devices…", meters: .empty)

      // The previous callbacks have stopped before any state or transport is reset.
      audioDiagnostics = AudioDiagnostics()
      negotiatedInputFrames = 0
      negotiatedOutputFrames = 0
      latestMeterSnapshot = .empty
      framesSinceMeterPublish = 0
      // Consume any previous pending values on their consumer paths only after quiescence.
      _ = configurationMailbox.consumeLatest()
      _ = meterMailbox.consumeLatest()
      self.framesPerBuffer = UInt32(min(1024, max(32, framesPerBuffer)))
      self.keepAliveOnly = keepAliveOnly
      let inputFormat = try validateDevices(
        inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID)
      // Known before the rate helpers run: the output rate is set before any unit opens.
      expectedInputDeviceID = inputDeviceID
      expectedOutputDeviceID = outputDeviceID
      // The device, not the cached catalog, owns the live width and rate. Players and
      // sample-rate switchers can change them between catalog refreshes.
      self.inputChannels = inputFormat.channels
      self.inputDeviceRate = inputFormat.rate
      // Passthrough: render at the input device's rate and ask the output device to
      // match it, so no sample-rate conversion happens inside Downmix or at the output.
      if keepAliveOnly {
        let outputRate = DeviceManager.sampleRate(id: outputDeviceID)
        self.pipelineRate =
          DownmixProcessor.supportedSampleRates.contains(outputRate)
          ? outputRate : Self.targetSampleRate
      } else {
        self.pipelineRate = resolvePipelineRate(
          inputRate: inputFormat.rate, outputDeviceID: outputDeviceID)
        self.pipelineRate = applyOutputSampleRate(self.pipelineRate)
      }
      self.configuration = configuration
      self.configuration.inputChannelCount = inputFormat.channels
      self.configuration.sampleRate = pipelineRate
      self.meterPublishFrames = Self.meterFrames(forSampleRate: pipelineRate)
      // Players downmix to stereo unless the input device advertises a layout their
      // channel map can convert. Install it before IO opens so the next client stream
      // negotiates the full bed. A refused layout is reported, never fatal.
      // A 16-channel bed only: a wider device keeps its own layout, and a narrower one
      // cannot describe the bed.
      status.bedLayoutInstalled =
        keepAliveOnly
        ? nil
        : InputChannelLayout.installIfNeeded(
          deviceID: inputDeviceID, channelCount: inputFormat.deviceChannels)
      if status.bedLayoutInstalled == false {
        logger.warning("Input device refused the 9.1.6 bed layout; players may send stereo")
      }

      // Do not retain a copied processor at startup: its delay arrays must be uniquely
      // owned before callbacks begin, otherwise the first write could trigger COW allocation.
      processor = DownmixProcessor()
      processor.apply(configuration: self.configuration)

      if !keepAliveOnly {
        let unit = try makeHALUnit()
        inputUnit = unit
        expectedInputDeviceID = inputDeviceID
        try configureInputUnit(unit, deviceID: inputDeviceID)
        maximumInputFrames = try maximumFramesPerSlice(unit)
        guard UInt64(maximumInputFrames) * UInt64(inputChannels) * 4 <= UInt64(UInt32.max)
        else {
          throw EngineError.setupFailed("Input slice exceeds the audio buffer byte limit")
        }
        // Allocate all callback scratch storage before either unit can start callbacks.
        try allocateInputBuffers()
      }

      let unit = try makeHALUnit()
      outputUnit = unit
      expectedOutputDeviceID = outputDeviceID
      try configureOutputUnit(unit, deviceID: outputDeviceID, sampleRate: pipelineRate)
      maximumOutputFrames = try maximumFramesPerSlice(unit)
      guard Int(maximumInputFrames) >= negotiatedInputFrames,
        Int(maximumOutputFrames) >= negotiatedOutputFrames
      else {
        throw EngineError.setupFailed(
          "Audio unit maximum slice is smaller than the device I/O buffer")
      }
      // Queue geometry follows the pipeline-rate frames a callback produces, not the
      // device-rate frames the input unit receives.
      let buffering = StereoOutputBuffering(
        inputFrames: converterFrames(forDeviceFrames: negotiatedInputFrames),
        outputFrames: negotiatedOutputFrames,
        maximumInputFrames: maximumConvertedFrames,
        maximumOutputFrames: Int(maximumOutputFrames),
        sampleRate: pipelineRate
      )
      ring = keepAliveOnly ? nil : FloatRingBuffer(capacity: buffering.ringCapacityFrames * 2)
      outputRenderer = StereoOutputRenderer(
        ring: ring, diagnostics: audioDiagnostics, maximumFrames: maximumOutputFrames,
        driftCorrection: !keepAliveOnly, targetFrames: buffering.targetFrames,
        sampleRate: pipelineRate
      )
      try verifyRoutes()

      // Consumer first: the output renders priming silence while the input unit starts,
      // instead of the producer overfilling the ring while the output initializes.
      try startUnit(unit)
      if let inputUnit {
        try startUnit(inputUnit)
      }

      // Cancellation may arrive during a blocking initialize or UnitStart. Never reopen
      // the gate; dispose on this same queue immediately after setup returns.
      guard self.renderGate?.isOpen == true else {
        try stopInternal(notify: false)
        return
      }
      isRunning = true

      publish(
        phase: keepAliveOnly ? .keepAlive : .running,
        message: keepAliveOnly
          ? "Output keep-alive running"
          : Self.runningMessage(inputRate: inputDeviceRate, renderRate: pipelineRate)
      )
      startMeterTimer()
    } catch {
      do {
        try stopInternal(notify: false)
      } catch {
        logger.error("Start cleanup failed: \(error.localizedDescription)")
      }
      publish(phase: .error, message: error.localizedDescription, meters: .empty)
      throw error
    }
  }

  func updateConfiguration(_ configuration: DownmixProcessor.Configuration) {
    dispatchPrecondition(condition: .onQueue(queue))
    // Array-to-POD conversion and sanitization happen on the worker queue.
    // The callback applies the newest complete value at its next block boundary.
    var configuration = configuration
    // The device owns the live input width; a cached catalog value must not make the
    // processor read past the frames its callback actually rendered.
    if !keepAliveOnly { configuration.inputChannelCount = inputChannels }
    configuration.sampleRate = pipelineRate
    self.configuration = configuration
    configurationMailbox.publish(DownmixProcessor.RealtimeConfiguration(configuration))
  }

  /// Best-effort rate match for the running input device. The watchdog notices the new
  /// nominal rate and recreates both units, with the selected output following it.
  func requestInputSampleRate(_ rate: Double) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard isRunning, !keepAliveOnly, rate.isFinite,
      InputRateConverter.supportedDeviceRates.contains(rate)
    else { return }
    let deviceID = expectedInputDeviceID
    guard deviceID != kAudioObjectUnknown else { return }
    guard DeviceManager.sampleRate(id: deviceID) != rate else { return }
    guard DeviceManager.isSampleRateAvailable(rate, id: deviceID) else {
      logger.notice("Input device does not offer \(rate) Hz; keeping \(self.inputDeviceRate) Hz")
      return
    }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var settable: DarwinBoolean = false
    guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
      settable.boolValue
    else {
      logger.warning("Input device rate is not settable; keeping \(self.inputDeviceRate) Hz")
      return
    }
    var value = rate
    let status = AudioObjectSetPropertyData(
      deviceID, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
    logger.notice(
      "Requested input device rate \(rate) Hz (was \(self.inputDeviceRate) Hz): status \(status)"
    )
  }

  func stop() {
    dispatchPrecondition(condition: .onQueue(queue))
    logger.info("Stop requested")
    do {
      try stopInternal(notify: true)
    } catch {
      publish(phase: .error, message: error.localizedDescription, meters: .empty)
    }
  }

  deinit {
    // The queue owner stops and releases the worker on its queue. No main-thread wait.
    // HAL callbacks use an unretained refCon, so release must follow quiescence.
    dispatchPrecondition(condition: .onQueue(queue))
    do {
      try stopInternal(notify: false)
    } catch {
      logger.error("Deinit cleanup failed: \(error.localizedDescription)")
    }
    logger.info("AudioEngine deinitialized")
  }

  // MARK: - Setup

  private func makeHALUnit() throws -> AudioComponentInstance {
    var description = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_HALOutput,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0
    )
    guard let component = AudioComponentFindNext(nil, &description) else {
      throw EngineError.setupFailed("HAL output component unavailable")
    }
    var instance: AudioComponentInstance?
    let status = AudioComponentInstanceNew(component, &instance)
    guard status == noErr, let instance else {
      throw EngineError.setupFailed("Could not create audio unit (\(status))")
    }
    return instance
  }

  private func configureInputUnit(_ unit: AudioComponentInstance, deviceID: AudioDeviceID) throws {
    // HAL: bus 0 = output, bus 1 = input
    var enableInput: UInt32 = 1
    var disableOutput: UInt32 = 0
    try check(
      AudioUnitSetProperty(
        unit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Input,
        1,
        &enableInput,
        UInt32(MemoryLayout<UInt32>.size)
      ),
      "enable input IO"
    )
    try check(
      AudioUnitSetProperty(
        unit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Output,
        0,
        &disableOutput,
        UInt32(MemoryLayout<UInt32>.size)
      ),
      "disable output IO on input unit"
    )

    var device = deviceID
    try check(
      AudioUnitSetProperty(
        unit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &device,
        UInt32(MemoryLayout<AudioDeviceID>.size)
      ),
      "set input device"
    )

    var asbd = streamFormat(channels: UInt32(inputChannels), sampleRate: inputDeviceRate)
    try check(
      AudioUnitSetProperty(
        unit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Output,
        1,
        &asbd,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      ),
      "set input unit client format"
    )

    try configureBufferFrameSize(deviceID: deviceID)

    var callback = AURenderCallbackStruct(
      inputProc: inputRenderCallback,
      inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
    )
    try check(
      AudioUnitSetProperty(
        unit,
        kAudioOutputUnitProperty_SetInputCallback,
        kAudioUnitScope_Global,
        0,
        &callback,
        UInt32(MemoryLayout<AURenderCallbackStruct>.size)
      ),
      "set input callback"
    )

    try setMaximumFramesPerSlice(unit, deviceID: deviceID)
    try check(AudioUnitInitialize(unit), "initialize input unit")
  }

  private func configureOutputUnit(
    _ unit: AudioComponentInstance, deviceID: AudioDeviceID, sampleRate: Double
  ) throws {
    var enableOutput: UInt32 = 1
    var disableInput: UInt32 = 0
    try check(
      AudioUnitSetProperty(
        unit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Output,
        0,
        &enableOutput,
        UInt32(MemoryLayout<UInt32>.size)
      ),
      "enable output IO"
    )
    try check(
      AudioUnitSetProperty(
        unit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Input,
        1,
        &disableInput,
        UInt32(MemoryLayout<UInt32>.size)
      ),
      "disable input IO on output unit"
    )

    var device = deviceID
    try check(
      AudioUnitSetProperty(
        unit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &device,
        UInt32(MemoryLayout<AudioDeviceID>.size)
      ),
      "set output device"
    )

    var asbd = streamFormat(channels: 2, sampleRate: sampleRate)
    try check(
      AudioUnitSetProperty(
        unit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input,
        0,
        &asbd,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      ),
      "set output unit client format"
    )

    try configureBufferFrameSize(deviceID: deviceID)

    var callback = AURenderCallbackStruct(
      inputProc: outputRenderCallback,
      inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
    )
    try check(
      AudioUnitSetProperty(
        unit,
        kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input,
        0,
        &callback,
        UInt32(MemoryLayout<AURenderCallbackStruct>.size)
      ),
      "set output callback"
    )

    try setMaximumFramesPerSlice(unit, deviceID: deviceID)
    try check(AudioUnitInitialize(unit), "initialize output unit")
  }

  private func configureBufferFrameSize(deviceID: AudioDeviceID) throws {
    // Buffer frame size is a HAL device property, not an Audio Unit property ID.
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyBufferFrameSize,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var settable: DarwinBoolean = false
    try check(
      AudioObjectIsPropertySettable(deviceID, &address, &settable), "query I/O buffer support")
    guard settable.boolValue else { return }

    var rangeAddress = address
    rangeAddress.mSelector = kAudioDevicePropertyBufferFrameSizeRange
    var range = AudioValueRange()
    var size = UInt32(MemoryLayout<AudioValueRange>.size)
    try check(
      AudioObjectGetPropertyData(deviceID, &rangeAddress, 0, nil, &size, &range),
      "query I/O buffer range")
    guard range.mMinimum.isFinite, range.mMaximum.isFinite,
      range.mMinimum >= 1, range.mMaximum >= range.mMinimum,
      range.mMaximum <= Double(UInt32.max)
    else { throw EngineError.setupFailed("Device reported an invalid I/O buffer range") }
    var frames = UInt32(min(range.mMaximum, max(range.mMinimum, Double(framesPerBuffer))))
    try check(
      AudioObjectSetPropertyData(
        deviceID, &address, 0, nil,
        UInt32(MemoryLayout<UInt32>.size), &frames), "set device I/O buffer size")
  }

  private func setMaximumFramesPerSlice(_ unit: AudioComponentInstance, deviceID: AudioDeviceID)
    throws
  {
    // Hardware can negotiate a larger buffer than requested; size storage for its actual value.
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyBufferFrameSize,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var actualFrames: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    try check(
      AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &actualFrames),
      "query device I/O buffer size")
    guard actualFrames > 0, actualFrames <= UInt32(StereoOutputBuffering.maximumSliceFrames) else {
      throw EngineError.setupFailed("Unsupported device I/O buffer size (\(actualFrames) frames)")
    }
    if deviceID == expectedInputDeviceID { negotiatedInputFrames = Int(actualFrames) }
    if deviceID == expectedOutputDeviceID { negotiatedOutputFrames = Int(actualFrames) }
    var frames: UInt32 = max(4096, actualFrames, framesPerBuffer)
    try check(
      AudioUnitSetProperty(
        unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
        &frames, UInt32(MemoryLayout<UInt32>.size)
      ),
      "set maximum frames per slice"
    )
  }

  private func maximumFramesPerSlice(_ unit: AudioComponentInstance) throws -> UInt32 {
    var frames: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    try check(
      AudioUnitGetProperty(
        unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
        &frames, &size
      ),
      "query maximum frames per slice"
    )
    guard frames > 0, frames <= UInt32(StereoOutputBuffering.maximumSliceFrames) else {
      throw EngineError.setupFailed("Unsupported maximum render slice (\(frames) frames)")
    }
    return frames
  }

  /// Validates the route and returns the live input format. Device rates are not
  /// constrained to 48 kHz: the input follows the device and is converted internally,
  /// and AUHAL converts the stereo client format for the output device.
  private struct LiveInputFormat {
    /// Client width: at most the 16 bed slots the processor maps.
    let channels: Int
    /// Width the device itself exposes, which decides the installed bed layout.
    let deviceChannels: Int
    let rate: Double
  }

  private func validateDevices(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) throws
    -> LiveInputFormat
  {
    let devices = DeviceManager.allDevices()
    guard let output = devices.first(where: { $0.id == outputDeviceID }) else {
      throw EngineError.missingDevice
    }
    guard output.outputChannelCount >= 2 else {
      throw EngineError.setupFailed(
        "\(output.name) exposes \(output.outputChannelCount) output channel(s); a stereo output needs two."
      )
    }
    guard output.nominalSampleRate.isFinite, output.nominalSampleRate > 0 else {
      throw EngineError.setupFailed("\(output.name) reports no usable sample rate.")
    }
    let inputUID = devices.first(where: { $0.id == inputDeviceID })?.uid ?? ""
    guard DeviceManager.isSafeOutputRoute(output, inputUID: keepAliveOnly ? "" : inputUID) else {
      throw EngineError.setupFailed("Output route could feed back into the Downmix input")
    }
    expectedOutputInfo = output
    expectedInputUID = keepAliveOnly ? "" : inputUID
    guard !keepAliveOnly else {
      return LiveInputFormat(
        channels: inputChannels, deviceChannels: inputChannels, rate: Self.targetSampleRate)
    }

    guard let input = devices.first(where: { $0.id == inputDeviceID }) else {
      throw EngineError.missingDevice
    }
    // Query the HAL instead of the cached catalog: the width and rate can change
    // between a catalog refresh and Start.
    guard let live = DeviceManager.inputFormat(id: inputDeviceID) else {
      throw EngineError.setupFailed("Could not read the format of \(input.name).")
    }
    guard live.channels >= 2 else {
      throw EngineError.setupFailed(
        "\(input.name) exposes \(live.channels) input channel(s); Downmix needs at least two."
      )
    }
    guard live.rate.isFinite, InputRateConverter.supportedDeviceRates.contains(live.rate) else {
      throw EngineError.setupFailed(
        "\(input.name) reports \(Self.rateLabel(live.rate)); Downmix supports 8–768 kHz input."
      )
    }
    return LiveInputFormat(
      channels: min(InputChannelLayout.channelCount, live.channels),
      deviceChannels: live.channels, rate: live.rate)
  }

  private func streamFormat(channels: UInt32, sampleRate: Double = AudioEngine.targetSampleRate)
    -> AudioStreamBasicDescription
  {
    AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        | kAudioFormatFlagsNativeEndian,
      mBytesPerPacket: 4 * channels,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4 * channels,
      mChannelsPerFrame: channels,
      mBitsPerChannel: 32,
      mReserved: 0
    )
  }

  /// Storage for the widest block the input unit can hand us. Always the full bed width
  /// so a live width change can never read past the rendered frames before the
  /// processor applies its new channel count.
  private func allocateInputScratch() {
    inputData = [Float](
      repeating: 0, count: Int(maximumInputFrames) * InputChannelLayout.channelCount)
    inputRateConverter = InputRateConverter(
      deviceRate: inputDeviceRate, channelCount: inputChannels, outputRate: pipelineRate)
    inputRateConverter?.prime()
  }

  /// Allocates the device-rate and 48 kHz scratch storage for the current input format.
  /// Queue geometry rejects a device buffer/rate combination larger than one supported
  /// slice instead of trapping in `StereoOutputBuffering`.
  private func allocateInputBuffers() throws {
    allocateInputScratch()
    if let converter = inputRateConverter {
      maximumConvertedFrames = converter.outputCapacity(forInputFrames: Int(maximumInputFrames))
      guard maximumConvertedFrames <= StereoOutputBuffering.maximumSliceFrames else {
        throw EngineError.setupFailed(
          "The input rate and buffer size need more than \(maximumConvertedFrames) frames per slice"
        )
      }
      convertedInput = [Float](repeating: 0, count: maximumConvertedFrames * inputChannels)
      scratchStereo = [Float](repeating: 0, count: maximumConvertedFrames * 2)
    } else {
      maximumConvertedFrames = Int(maximumInputFrames)
      convertedInput = []
      scratchStereo = [Float](repeating: 0, count: Int(maximumInputFrames) * 2)
    }
  }

  /// Pipeline-rate frames produced for one device-rate callback.
  private func converterFrames(forDeviceFrames frames: Int) -> Int {
    inputRateConverter?.convertedFrames(forInputFrames: frames) ?? frames
  }

  /// Passthrough rate: the input device's rate when the output device can accept it,
  /// otherwise a 48/44.1 kHz fallback (the only case that still converts).
  private func resolvePipelineRate(inputRate: Double, outputDeviceID: AudioDeviceID) -> Double {
    if DeviceManager.isSampleRateAvailable(inputRate, id: outputDeviceID) { return inputRate }
    return Self.fallbackPipelineRate(deviceID: outputDeviceID)
  }

  private static func fallbackPipelineRate(deviceID: AudioDeviceID) -> Double {
    for candidate in [48_000.0, 44_100.0]
    where DeviceManager.isSampleRateAvailable(candidate, id: deviceID) {
      return candidate
    }
    let current = DeviceManager.sampleRate(id: deviceID)
    return DownmixProcessor.supportedSampleRates.contains(current) ? current : targetSampleRate
  }

  /// Asks the output device for `requested` and returns the rate the pipeline should use.
  /// A device that cannot take it falls back so the local path never converts silently.
  @discardableResult
  private func applyOutputSampleRate(_ requested: Double) -> Double {
    let deviceID = expectedOutputDeviceID
    guard deviceID != kAudioObjectUnknown else { return requested }
    guard DeviceManager.isSampleRateAvailable(requested, id: deviceID) else {
      let fallback = Self.fallbackPipelineRate(deviceID: deviceID)
      if lastOutputRateNotice != fallback {
        lastOutputRateNotice = fallback
        logger.notice(
          "Output device does not offer \(requested) Hz; rendering at \(fallback) Hz")
      }
      return fallback
    }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var settable: DarwinBoolean = false
    guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
      settable.boolValue
    else {
      let fallback = Self.fallbackPipelineRate(deviceID: deviceID)
      if lastOutputRateNotice != fallback {
        lastOutputRateNotice = fallback
        logger.warning("Output device rate is not settable; rendering at \(fallback) Hz")
      }
      return fallback
    }
    var value = requested
    let status = AudioObjectSetPropertyData(
      deviceID, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
    guard status == noErr else {
      let fallback = Self.fallbackPipelineRate(deviceID: deviceID)
      if lastOutputRateNotice != fallback {
        lastOutputRateNotice = fallback
        logger.warning(
          "Output device refused \(requested) Hz (\(status)); rendering at \(fallback) Hz")
      }
      return fallback
    }
    lastOutputRateNotice = requested
    return requested
  }

  private static func meterFrames(forSampleRate rate: Double) -> Int {
    max(4_800, Int((rate * 0.1).rounded()))
  }

  /// Reopens both units when the input format or the passthrough rate changes. The
  /// stereo mix must switch rate with the source, and the output client format must
  /// match the output device, so this is a full (brief) transport restart rather than
  /// an input-only reopen.
  private func reconfigurePipelineIfNeeded() throws {
    guard !keepAliveOnly, let input = inputUnit, let output = outputUnit else { return }
    guard let live = DeviceManager.inputFormat(id: expectedInputDeviceID) else {
      throw EngineError.setupFailed("The selected input device is unavailable")
    }
    let channels = min(InputChannelLayout.channelCount, live.channels)
    guard channels >= 2 else {
      throw EngineError.setupFailed(
        "The selected input now exposes \(live.channels) channel(s). Downmix needs at least two."
      )
    }
    guard InputRateConverter.supportedDeviceRates.contains(live.rate) else {
      throw EngineError.setupFailed(
        "The selected input changed to \(Self.rateLabel(live.rate)), which Downmix does not support."
      )
    }
    let desiredRate = resolvePipelineRate(
      inputRate: live.rate, outputDeviceID: expectedOutputDeviceID)
    let inputChanged = channels != inputChannels || live.rate != inputDeviceRate
    let pipelineChanged = abs(desiredRate - pipelineRate) > 0.5
    let liveOutputRate = DeviceManager.sampleRate(id: expectedOutputDeviceID)
    let outputDeviation = abs(liveOutputRate - pipelineRate) > 0.5
    guard inputChanged || pipelineChanged || outputDeviation else { return }

    // Even if restoring the nominal rate succeeds, replace the units: an AUHAL can
    // retain its old device-side clock/converter while reporting the new client rate.
    try reopenPipeline(inputRate: live.rate, channels: channels, output: output, input: input)
  }

  private func reopenPipeline(
    inputRate: Double, channels: Int, output: AudioComponentInstance,
    input: AudioComponentInstance
  ) throws {
    logger.notice(
      "Pipeline reopen: input \(inputRate) Hz / \(channels) ch, render \(self.pipelineRate) Hz")
    // Uninitialize + a new client ASBD is insufficient on real AUHAL: rate changes
    // can leave a reused unit with stale device-side conversion/timing and sustained
    // queue starvation despite matching rate properties. Dispose BOTH units before
    // replacing callback storage or changing the output rate, then attach fresh units
    // to the live devices.
    _ = AudioOutputUnitStop(input)
    _ = AudioUnitUninitialize(input)
    try check(AudioComponentInstanceDispose(input), "dispose input unit for rate change")
    inputUnit = nil
    _ = AudioOutputUnitStop(output)
    _ = AudioUnitUninitialize(output)
    try check(AudioComponentInstanceDispose(output), "dispose output unit for rate change")
    outputUnit = nil
    // Only the old generation can have rendered so far. Never clear a failure after
    // starting fresh callbacks: that could hide a genuine error in the new format.
    audioDiagnostics.clearStaleFormatFailure(kAudioUnitErr_CannotDoInCurrentContext)

    inputChannels = channels
    inputDeviceRate = inputRate
    pipelineRate = applyOutputSampleRate(
      resolvePipelineRate(inputRate: inputRate, outputDeviceID: expectedOutputDeviceID))
    configuration.inputChannelCount = channels
    configuration.sampleRate = pipelineRate
    meterPublishFrames = Self.meterFrames(forSampleRate: pipelineRate)
    negotiatedInputFrames = 0
    negotiatedOutputFrames = 0

    let newInput = try makeHALUnit()
    inputUnit = newInput
    try configureInputUnit(newInput, deviceID: expectedInputDeviceID)
    maximumInputFrames = try maximumFramesPerSlice(newInput)
    guard UInt64(maximumInputFrames) * UInt64(inputChannels) * 4 <= UInt64(UInt32.max)
    else {
      throw EngineError.setupFailed("Input slice exceeds the audio buffer byte limit")
    }
    let newOutput = try makeHALUnit()
    outputUnit = newOutput
    try configureOutputUnit(
      newOutput, deviceID: expectedOutputDeviceID, sampleRate: pipelineRate)
    maximumOutputFrames = try maximumFramesPerSlice(newOutput)
    guard Int(maximumInputFrames) >= negotiatedInputFrames,
      Int(maximumOutputFrames) >= negotiatedOutputFrames
    else {
      throw EngineError.setupFailed(
        "Audio unit maximum slice is smaller than the device I/O buffer")
    }
    try allocateInputBuffers()
    let buffering = StereoOutputBuffering(
      inputFrames: converterFrames(forDeviceFrames: negotiatedInputFrames),
      outputFrames: negotiatedOutputFrames,
      maximumInputFrames: maximumConvertedFrames,
      maximumOutputFrames: Int(maximumOutputFrames),
      sampleRate: pipelineRate
    )
    ring = FloatRingBuffer(capacity: buffering.ringCapacityFrames * 2)
    outputRenderer = StereoOutputRenderer(
      ring: ring, diagnostics: audioDiagnostics, maximumFrames: maximumOutputFrames,
      driftCorrection: true, targetFrames: buffering.targetFrames, sampleRate: pipelineRate
    )
    // Consumed by the first callback after the restart, before it processes samples.
    configurationMailbox.publish(DownmixProcessor.RealtimeConfiguration(configuration))
    // A Stop can close the gate while this tick reconfigures. Do not start units for a
    // cancelled run; the queued Stop command disposes them.
    guard renderGate?.isOpen == true else { return }
    try verifyRoutes()
    try startUnit(newOutput)
    try startUnit(newInput)
    publish(
      phase: .running,
      message: Self.runningMessage(inputRate: inputRate, renderRate: self.pipelineRate))
    logger.notice(
      "Pipeline reopened: input \(inputRate) Hz / \(channels) ch, render \(self.pipelineRate) Hz")
  }

  private static func rateLabel(_ rate: Double) -> String {
    guard rate.isFinite else { return "an unknown rate" }
    let kiloHertz = rate / 1_000
    let text =
      kiloHertz == kiloHertz.rounded()
      ? String(Int(kiloHertz)) : String(format: "%.1f", kiloHertz)
    return "\(text) kHz"
  }

  private static func runningMessage(inputRate: Double, renderRate: Double) -> String {
    if inputRate == renderRate {
      return renderRate == targetSampleRate
        ? "Stereo renderer running" : "Stereo renderer running · \(rateLabel(renderRate))"
    }
    return
      "Stereo renderer running · \(rateLabel(inputRate)) → \(rateLabel(renderRate)) (output limit)"
  }

  private func startUnit(_ unit: AudioComponentInstance) throws {
    try check(AudioOutputUnitStart(unit), "start audio unit")
  }

  private func stopInternal(notify: Bool) throws {
    dispatchPrecondition(condition: .onQueue(queue))
    dispatchPrecondition(condition: .notOnQueue(.main))
    renderGate?.close()
    meterTimer?.cancel()
    meterTimer = nil

    isRunning = false
    let inUnit = inputUnit
    let outUnit = outputUnit

    // Dispose both units before mutating anything reachable by a render callback.
    // Keep unit references, the ring and scratch storage alive until callbacks are quiescent.
    var disposalError: OSStatus = noErr
    if let inUnit {
      _ = AudioOutputUnitStop(inUnit)
      _ = AudioUnitUninitialize(inUnit)
      let result = AudioComponentInstanceDispose(inUnit)
      if result == noErr {
        inputUnit = nil
      } else {
        disposalError = result
      }
    }
    if let outUnit {
      _ = AudioOutputUnitStop(outUnit)
      _ = AudioUnitUninitialize(outUnit)
      let result = AudioComponentInstanceDispose(outUnit)
      if result == noErr {
        outputUnit = nil
      } else {
        disposalError = result
      }
    }
    // A failed disposal must not release storage still reachable by an audio unit.
    if disposalError != noErr { retainedForCallbacks = self }
    try check(disposalError, "dispose audio units")
    retainedForCallbacks = nil
    renderGate = nil
    expectedInputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    expectedOutputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    expectedOutputInfo = nil
    expectedInputUID = ""
    maximumInputFrames = 0
    maximumOutputFrames = 0
    maximumConvertedFrames = 0
    outputRenderer = nil
    ring?.clear()
    ring = nil
    inputData = []
    scratchStereo = []
    convertedInput = []
    inputRateConverter = nil
    inputChannels = InputChannelLayout.channelCount
    inputDeviceRate = Self.targetSampleRate
    pipelineRate = Self.targetSampleRate
    meterPublishFrames = 4_800
    lastOutputRateNotice = nil

    if inUnit != nil || outUnit != nil {
      logger.info("Audio units stopped and disposed")
    }
    if notify {
      publish(phase: .stopped, message: "Stereo renderer is idle", meters: .empty)
    }
  }

  private func check(_ status: OSStatus, _ label: String) throws {
    guard status == noErr else {
      throw EngineError.setupFailed("\(label) failed (\(status))")
    }
  }

  private func verifyRoutes() throws {
    guard let outputUnit else {
      throw EngineError.setupFailed("Output device is unavailable")
    }
    try verifyRoute(
      outputUnit, deviceID: expectedOutputDeviceID, label: "output", isInput: false)
    guard let expectedOutputInfo,
      DeviceManager.isSafeOutputRoute(expectedOutputInfo, inputUID: expectedInputUID)
    else {
      throw EngineError.setupFailed(
        "Output route is no longer safe. Downmix stopped to prevent feedback.")
    }
    if !keepAliveOnly {
      guard let inputUnit else {
        throw EngineError.setupFailed("Input device is unavailable")
      }
      try verifyRoute(inputUnit, deviceID: expectedInputDeviceID, label: "input", isInput: true)
    }
  }

  private func verifyRoute(
    _ unit: AudioComponentInstance, deviceID: AudioDeviceID, label: String, isInput: Bool
  ) throws {
    guard deviceID != kAudioObjectUnknown else {
      throw EngineError.setupFailed("Selected \(label) device is unavailable")
    }

    var aliveAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var isAlive: UInt32 = 0
    var aliveSize = UInt32(MemoryLayout<UInt32>.size)
    try check(
      AudioObjectGetPropertyData(
        deviceID,
        &aliveAddress,
        0,
        nil,
        &aliveSize,
        &isAlive
      ),
      "verify \(label) availability"
    )
    guard isAlive != 0 else {
      throw EngineError.setupFailed("The selected \(label) disconnected. Downmix stopped safely.")
    }

    var rateAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var rate = 0.0
    var rateSize = UInt32(MemoryLayout<Double>.size)
    try check(
      AudioObjectGetPropertyData(deviceID, &rateAddress, 0, nil, &rateSize, &rate),
      "verify \(label) sample rate"
    )
    // Any real device rate is usable: the input is converted to 48 kHz and AUHAL
    // converts the stereo client format for the output device. Only a device that
    // reports no usable rate is a failure.
    guard rate.isFinite, rate > 0 else {
      throw EngineError.setupFailed(
        "The selected \(label) reports no usable sample rate. Downmix stopped safely.")
    }

    let deviceScope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    // An input width change is a reconfiguration, not a failure; the reopen validates the
    // new width. The output has no such path, so its topology must stay usable.
    if isInput {
      guard DeviceManager.channelCount(id: deviceID, scope: deviceScope) >= 1 else {
        throw EngineError.setupFailed("The selected input no longer exposes any channels.")
      }
    } else {
      guard DeviceManager.channelCount(id: deviceID, scope: deviceScope) >= 2 else {
        throw EngineError.setupFailed(
          "The selected output channel topology changed; requires at least two channels. Downmix stopped safely."
        )
      }
    }

    // The live device rate and width are allowed to change; `reconfigurePipelineIfNeeded`
    // reopens instead of treating a player's rate switch as a failure. The
    // client format must still be the one this run installed.
    let expectedRate = isInput ? inputDeviceRate : pipelineRate
    let expectedChannels = isInput ? inputChannels : 2
    let bus: UInt32 = isInput ? 1 : 0
    for clientSide in [false, true] {
      let scope = (isInput == clientSide) ? kAudioUnitScope_Output : kAudioUnitScope_Input
      var format = AudioStreamBasicDescription()
      var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      try check(
        AudioUnitGetProperty(
          unit, kAudioUnitProperty_StreamFormat, scope, bus, &format, &formatSize),
        "verify \(label) \(clientSide ? "client" : "device") stream format")
      guard formatSize == MemoryLayout<AudioStreamBasicDescription>.size,
        format.mSampleRate.isFinite, format.mSampleRate > 0,
        format.mChannelsPerFrame > 0
      else {
        throw EngineError.setupFailed(
          "The selected \(label) stream format changed (channels/rate). Downmix stopped safely.")
      }
      if clientSide {
        let expected = streamFormat(
          channels: UInt32(expectedChannels), sampleRate: expectedRate)
        guard format.mFormatID == expected.mFormatID,
          format.mFormatFlags == expected.mFormatFlags,
          format.mSampleRate == expected.mSampleRate,
          format.mChannelsPerFrame == expected.mChannelsPerFrame,
          format.mBytesPerFrame == expected.mBytesPerFrame,
          format.mBytesPerPacket == expected.mBytesPerPacket,
          format.mFramesPerPacket == expected.mFramesPerPacket,
          format.mBitsPerChannel == expected.mBitsPerChannel
        else {
          throw EngineError.setupFailed(
            "The selected \(label) client buffer format changed. Downmix stopped safely.")
        }
      }
    }
    try verifyDeviceStreams(deviceID: deviceID, scope: deviceScope, label: label)

    var currentDevice = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    try check(
      AudioUnitGetProperty(
        unit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &currentDevice,
        &size
      ),
      "verify \(label) device"
    )
    guard currentDevice == deviceID else {
      throw EngineError.setupFailed(
        "The selected \(label) route changed. Downmix stopped safely."
      )
    }
  }

  private func verifyDeviceStreams(
    deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, label: String
  ) throws {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams, mScope: scope,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
      "verify \(label) streams")
    guard size > 0, Int(size).isMultiple(of: MemoryLayout<AudioStreamID>.size) else {
      throw EngineError.setupFailed("The selected \(label) stream list is invalid")
    }
    let expectedSize = size
    var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    try check(
      AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streams),
      "verify \(label) streams")
    guard size == expectedSize else {
      throw EngineError.setupFailed("The selected \(label) stream topology changed")
    }
    for stream in streams {
      for selector in [kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat] {
        address.mSelector = selector
        address.mScope = kAudioObjectPropertyScopeGlobal
        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
          AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format),
          "verify \(label) device stream format")
        guard size == MemoryLayout<AudioStreamBasicDescription>.size,
          format.mSampleRate.isFinite, format.mSampleRate > 0,
          format.mChannelsPerFrame > 0
        else {
          throw EngineError.setupFailed(
            "The selected \(label) device stream is no longer usable. Downmix stopped safely."
          )
        }
      }
    }
  }

  private func publish(phase: EnginePhase, message: String, meters: MeterSnapshot? = nil) {
    dispatchPrecondition(condition: .onQueue(queue))
    status.phase = phase
    status.message = message
    if let meters { status.meters = meters }
    // The layout certificate belongs to one live run; anything else reports no claim.
    if phase != .running && phase != .keepAlive { status.bedLayoutInstalled = nil }
    if phase == .running && !keepAliveOnly {
      status.inputSampleRate = inputDeviceRate
      status.inputChannelCount = inputChannels
      status.renderSampleRate = pipelineRate
    } else {
      status.inputSampleRate = nil
      status.inputChannelCount = nil
      status.renderSampleRate = nil
    }
    if phase == .running || phase == .keepAlive || phase == .error {
      status.diagnostics = diagnosticsSnapshot()
      // Failure counters remain inspectable, but stopped audio has no queued latency.
      if phase == .error {
        status.diagnostics.queuedFrames = 0
        status.diagnostics.isPriming = false
      }
    } else {
      status.diagnostics = .empty
    }
    onStatus?(status)
  }

  // MARK: - Callbacks

  private var inputData = [Float]()
  private var scratchStereo = [Float]()

  fileprivate func handleInput(
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    frameCount: UInt32
  ) -> OSStatus {
    guard renderGate?.isOpen == true, frameCount > 0 else { return noErr }
    guard frameCount <= maximumInputFrames else {
      audioDiagnostics.recordRejectedSlice(error: kAudioUnitErr_TooManyFramesToProcess)
      return kAudioUnitErr_TooManyFramesToProcess
    }
    guard let unit = inputUnit, let ring else { return noErr }

    let channels = inputChannels
    let samples = Int(frameCount) * channels
    guard samples <= inputData.count else {
      audioDiagnostics.recordRejectedSlice(error: kAudioUnitErr_TooManyFramesToProcess)
      return kAudioUnitErr_TooManyFramesToProcess
    }

    let renderStatus = inputData.withUnsafeMutableBytes { raw -> OSStatus in
      let buffer = AudioBuffer(
        mNumberChannels: UInt32(channels),
        mDataByteSize: UInt32(samples * MemoryLayout<Float>.size),
        mData: raw.baseAddress
      )
      var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
      return AudioUnitRender(unit, flags, timestamp, 1, frameCount, &bufferList)
    }
    guard renderGate?.isOpen == true else { return noErr }
    guard renderStatus == noErr else {
      audioDiagnostics.recordRenderError(renderStatus)
      return renderStatus
    }

    if let configuration = configurationMailbox.consumeLatest() {
      processor.apply(realtimeConfiguration: configuration)
    }

    // Device rate → 48 kHz DSP rate. No converter means the device already runs at 48 kHz.
    var processedFrames = Int(frameCount)
    if let converter = inputRateConverter {
      processedFrames = inputData.withUnsafeBufferPointer { inBuf in
        convertedInput.withUnsafeMutableBufferPointer { outBuf in
          converter.process(
            input: inBuf.baseAddress!, frameCount: Int(frameCount),
            output: outBuf.baseAddress!, capacity: maximumConvertedFrames)
        }
      }
      guard processedFrames > 0, processedFrames <= maximumConvertedFrames,
        processedFrames * 2 <= scratchStereo.count
      else { return noErr }
      convertedInput.withUnsafeBufferPointer { inBuf in
        scratchStereo.withUnsafeMutableBufferPointer { outBuf in
          processor.process(
            input: inBuf.baseAddress!, inputChannelCount: channels,
            output: outBuf.baseAddress!, frameCount: processedFrames)
        }
      }
    } else {
      guard processedFrames * 2 <= scratchStereo.count else {
        audioDiagnostics.recordRejectedSlice(error: kAudioUnitErr_TooManyFramesToProcess)
        return kAudioUnitErr_TooManyFramesToProcess
      }
      inputData.withUnsafeBufferPointer { inBuf in
        scratchStereo.withUnsafeMutableBufferPointer { outBuf in
          processor.process(
            input: inBuf.baseAddress!, inputChannelCount: channels,
            output: outBuf.baseAddress!, frameCount: processedFrames)
        }
      }
    }
    framesSinceMeterPublish += processedFrames
    if framesSinceMeterPublish >= meterPublishFrames {
      framesSinceMeterPublish %= meterPublishFrames
      let meters = processor.takeRealtimeMeterSnapshot()
      audioDiagnostics.recordClipping(left: meters.clipL, right: meters.clipR)
      meterMailbox.publish(meters)
    }

    // Explicit stereo alignment using the existing ring API. With one producer, writable
    // space can only grow between this snapshot and write(), so it cannot truncate to odd.
    let stereoSamples = processedFrames * 2
    let writable = min(stereoSamples, ring.availableToWrite)
    let alignedCount = writable - writable % 2
    if alignedCount > 0 {
      scratchStereo.withUnsafeBufferPointer { buf in
        _ = ring.write(buf.baseAddress!, count: alignedCount)
      }
    }
    audioDiagnostics.recordOverrun(frames: (stereoSamples - alignedCount) / 2)
    return noErr
  }

  fileprivate func handleOutput(
    frameCount: UInt32,
    bufferList: UnsafeMutablePointer<AudioBufferList>?
  ) -> OSStatus {
    guard let bufferList else {
      // A closed gate is cancellation, including late callbacks during disposal.
      guard renderGate?.isOpen == true else { return noErr }
      audioDiagnostics.recordRenderError(kAudioUnitErr_FormatNotSupported)
      return kAudioUnitErr_FormatNotSupported
    }
    guard renderGate?.isOpen == true, let outputRenderer else {
      StereoOutputRenderer.silence(UnsafeMutableAudioBufferListPointer(bufferList))
      return noErr
    }
    let result = outputRenderer.render(frameCount: frameCount, bufferList: bufferList)
    // Cover cancellation during this render too; already-submitted hardware frames are
    // unavoidable, but no subsequent callback drains stale ring contents.
    if renderGate?.isOpen != true {
      StereoOutputRenderer.silence(UnsafeMutableAudioBufferListPointer(bufferList))
      return noErr
    }
    return result
  }

  private func diagnosticsSnapshot() -> EngineDiagnostics {
    audioDiagnostics.snapshot(
      requested: Int(framesPerBuffer), input: negotiatedInputFrames,
      output: negotiatedOutputFrames, sampleRate: pipelineRate
    )
  }

  // MARK: - Meters

  private var meterTimer: DispatchSourceTimer?

  private func startMeterTimer() {
    meterTimer?.cancel()
    dispatchPrecondition(condition: .onQueue(queue))
    let timer = DispatchSource.makeTimerSource(queue: queue)
    // Watchdog/route queries and mailbox consumption stay off main with all HAL control.
    timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
    timer.setEventHandler { [weak self] in self?.pollStatus() }
    timer.resume()
    meterTimer = timer
  }

  private func pollStatus() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard isRunning else { return }
    do {
      try self.verifyRoutes()
      // A player or sample-rate switcher changed the format: replace both units so
      // device-side timing/conversion is rebuilt as well as the client ASBD.
      try self.reconfigurePipelineIfNeeded()
      if !self.keepAliveOnly {
        self.status.inputSampleRate = self.inputDeviceRate
        self.status.inputChannelCount = self.inputChannels
        self.status.renderSampleRate = self.pipelineRate
        self.status.message = Self.runningMessage(
          inputRate: self.inputDeviceRate, renderRate: self.pipelineRate)
      }
    } catch {
      self.logger.error("Audio route lost: \(error.localizedDescription)")
      do {
        try self.stopInternal(notify: false)
      } catch {
        self.logger.error("Route cleanup failed: \(error.localizedDescription)")
      }
      self.publish(phase: .error, message: error.localizedDescription, meters: .empty)
      return
    }

    let failure = self.audioDiagnostics.takePendingFailure()
    if failure != noErr {
      do { try self.stopInternal(notify: false) } catch {
        self.logger.error("Render cleanup failed: \(error.localizedDescription)")
      }
      self.publish(
        phase: .error,
        message:
          "Audio rendering failed (\(failure)). Check device format/buffer size and retry.",
        meters: .empty
      )
      return
    }
    if let meters = self.meterMailbox.consumeLatest() { self.latestMeterSnapshot = meters }
    var meters = self.keepAliveOnly ? MeterSnapshot.empty : self.latestMeterSnapshot.snapshot
    let clips = self.audioDiagnostics.takeClipping()
    meters.clipL = clips.left
    meters.clipR = clips.right
    self.status.meters = meters
    self.status.diagnostics = self.diagnosticsSnapshot()
    self.onStatus?(self.status)
  }
}

enum EngineError: LocalizedError {
  case setupFailed(String)
  case missingDevice

  var errorDescription: String? {
    switch self {
    case .setupFailed(let message): message
    case .missingDevice: "Select valid input and output devices."
    }
  }
}

// MARK: - C callbacks

private func inputRenderCallback(
  inRefCon: UnsafeMutableRawPointer,
  ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
  inTimeStamp: UnsafePointer<AudioTimeStamp>,
  inBusNumber: UInt32,
  inNumberFrames: UInt32,
  ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
  let engine = Unmanaged<AudioEngine>.fromOpaque(inRefCon).takeUnretainedValue()
  return engine.handleInput(
    flags: ioActionFlags, timestamp: inTimeStamp, frameCount: inNumberFrames)
}

private func outputRenderCallback(
  inRefCon: UnsafeMutableRawPointer,
  ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
  inTimeStamp: UnsafePointer<AudioTimeStamp>,
  inBusNumber: UInt32,
  inNumberFrames: UInt32,
  ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
  let engine = Unmanaged<AudioEngine>.fromOpaque(inRefCon).takeUnretainedValue()
  return engine.handleOutput(frameCount: inNumberFrames, bufferList: ioData)
}
