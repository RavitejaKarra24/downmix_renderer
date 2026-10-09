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
  private var inputChannels = 16
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
      self.inputChannels = max(configuration.inputChannelCount, 16)
      try validateDevices(inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID)

      // Do not retain a copied processor at startup: its delay arrays must be uniquely
      // owned before callbacks begin, otherwise the first write could trigger COW allocation.
      processor = DownmixProcessor()
      processor.apply(configuration: configuration)

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
        inputData = [Float](repeating: 0, count: Int(maximumInputFrames) * inputChannels)
        scratchStereo = [Float](repeating: 0, count: Int(maximumInputFrames) * 2)
      }

      let unit = try makeHALUnit()
      outputUnit = unit
      expectedOutputDeviceID = outputDeviceID
      try configureOutputUnit(unit, deviceID: outputDeviceID)
      maximumOutputFrames = try maximumFramesPerSlice(unit)
      guard Int(maximumInputFrames) >= negotiatedInputFrames,
        Int(maximumOutputFrames) >= negotiatedOutputFrames
      else {
        throw EngineError.setupFailed(
          "Audio unit maximum slice is smaller than the device I/O buffer")
      }
      let buffering = StereoOutputBuffering(
        inputFrames: negotiatedInputFrames, outputFrames: negotiatedOutputFrames,
        maximumInputFrames: Int(maximumInputFrames), maximumOutputFrames: Int(maximumOutputFrames)
      )
      ring = keepAliveOnly ? nil : FloatRingBuffer(capacity: buffering.ringCapacityFrames * 2)
      outputRenderer = StereoOutputRenderer(
        ring: ring, diagnostics: audioDiagnostics, maximumFrames: maximumOutputFrames,
        driftCorrection: !keepAliveOnly, targetFrames: buffering.targetFrames
      )
      try verifyRoutes()

      if let inputUnit {
        try startUnit(inputUnit)
      }
      try startUnit(unit)

      // Cancellation may arrive during a blocking initialize or UnitStart. Never reopen
      // the gate; dispose on this same queue immediately after setup returns.
      guard self.renderGate?.isOpen == true else {
        try stopInternal(notify: false)
        return
      }
      isRunning = true

      publish(
        phase: keepAliveOnly ? .keepAlive : .running,
        message: keepAliveOnly ? "Output keep-alive running" : "Stereo renderer running"
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
    configurationMailbox.publish(DownmixProcessor.RealtimeConfiguration(configuration))
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

    var asbd = streamFormat(channels: UInt32(inputChannels))
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

  private func configureOutputUnit(_ unit: AudioComponentInstance, deviceID: AudioDeviceID) throws {
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

    var asbd = streamFormat(channels: 2)
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

  private func validateDevices(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) throws {
    let devices = DeviceManager.allDevices()
    guard let output = devices.first(where: { $0.id == outputDeviceID }) else {
      throw EngineError.missingDevice
    }
    guard output.outputChannelCount >= 2, output.nominalSampleRate == Self.targetSampleRate else {
      throw EngineError.setupFailed("Output must expose at least two channels at 48 kHz")
    }
    let inputUID = devices.first(where: { $0.id == inputDeviceID })?.uid ?? ""
    guard DeviceManager.isSafeOutputRoute(output, inputUID: keepAliveOnly ? "" : inputUID) else {
      throw EngineError.setupFailed("Output route could feed back into the Downmix input")
    }
    expectedOutputInfo = output
    expectedInputUID = keepAliveOnly ? "" : inputUID
    if !keepAliveOnly {
      guard let input = devices.first(where: { $0.id == inputDeviceID }) else {
        throw EngineError.missingDevice
      }
      guard input.inputChannelCount >= inputChannels,
        input.nominalSampleRate == Self.targetSampleRate
      else {
        throw EngineError.setupFailed(
          "Input must expose at least \(inputChannels) channels at 48 kHz")
      }
    }
  }

  private func streamFormat(channels: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
      mSampleRate: Self.targetSampleRate,
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
    outputRenderer = nil
    ring?.clear()
    ring = nil
    inputData = []
    scratchStereo = []

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
    guard rate == Self.targetSampleRate else {
      throw EngineError.setupFailed(
        "The selected \(label) is no longer at 48 kHz. Downmix stopped safely.")
    }

    let deviceScope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    let requiredChannels = isInput ? inputChannels : 2
    guard DeviceManager.channelCount(id: deviceID, scope: deviceScope) >= requiredChannels else {
      throw EngineError.setupFailed(
        "The selected \(label) channel topology changed; requires at least \(requiredChannels) channels. Downmix stopped safely."
      )
    }

    // Nominal rate alone does not certify the formats actually used by HAL.
    // Check the device-side unit format AND the exact callback/client memory layout.
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
        format.mSampleRate == Self.targetSampleRate,
        format.mChannelsPerFrame >= requiredChannels
      else {
        throw EngineError.setupFailed(
          "The selected \(label) stream format changed (channels/rate). Downmix stopped safely.")
      }
      if clientSide {
        let expected = streamFormat(channels: UInt32(requiredChannels))
        guard format.mFormatID == expected.mFormatID,
          format.mFormatFlags == expected.mFormatFlags,
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
          format.mSampleRate == Self.targetSampleRate, format.mChannelsPerFrame > 0
        else {
          throw EngineError.setupFailed(
            "The selected \(label) device stream is no longer compatible with 48 kHz. Downmix stopped safely."
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
    let stereoSamples = Int(frameCount) * 2
    guard samples <= inputData.count, stereoSamples <= scratchStereo.count else {
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
    inputData.withUnsafeBufferPointer { inBuf in
      scratchStereo.withUnsafeMutableBufferPointer { outBuf in
        processor.process(
          input: inBuf.baseAddress!,
          inputChannelCount: channels,
          output: outBuf.baseAddress!,
          frameCount: Int(frameCount)
        )
      }
    }
    framesSinceMeterPublish += Int(frameCount)
    if framesSinceMeterPublish >= 4800 {
      framesSinceMeterPublish %= 4800
      let meters = processor.takeRealtimeMeterSnapshot()
      audioDiagnostics.recordClipping(left: meters.clipL, right: meters.clipR)
      meterMailbox.publish(meters)
    }

    // Explicit stereo alignment using the existing ring API. With one producer, writable
    // space can only grow between this snapshot and write(), so it cannot truncate to odd.
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
      requested: Int(framesPerBuffer), input: negotiatedInputFrames, output: negotiatedOutputFrames
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
