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
}

/// Dual-device Core Audio engine: multi-channel input → DSP → stereo output.
final class AudioEngine: @unchecked Sendable {
  static let targetSampleRate: Double = 48_000

  private let logger = Logger(subsystem: "com.local.downmix", category: "AudioEngine")
  private let stateLock = NSLock()

  private var inputUnit: AudioComponentInstance?
  private var outputUnit: AudioComponentInstance?
  private var ring: FloatRingBuffer?
  private var processor = DownmixProcessor()
  private var configuration = DownmixProcessor.Configuration()
  private var inputChannels = 16
  private var framesPerBuffer: UInt32 = 128
  private var isRunning = false
  private var keepAliveOnly = false

  private var status = EngineStatus()
  private var onStatus: ((EngineStatus) -> Void)?

  func setStatusHandler(_ handler: @escaping (EngineStatus) -> Void) {
    onStatus = handler
  }

  var currentStatus: EngineStatus {
    stateLock.lock()
    defer { stateLock.unlock() }
    return status
  }

  func start(
    inputDeviceID: AudioDeviceID,
    outputDeviceID: AudioDeviceID,
    configuration: DownmixProcessor.Configuration,
    framesPerBuffer: Int,
    keepAliveOnly: Bool = false
  ) throws {
    try stopInternal(notify: false)

    logger.info(
      "Start requested: input=\(inputDeviceID), output=\(outputDeviceID), frames=\(framesPerBuffer), keepAlive=\(keepAliveOnly)"
    )
    publish(phase: .starting, message: "Opening audio devices…")

    self.configuration = configuration
    self.framesPerBuffer = UInt32(max(32, framesPerBuffer))
    self.keepAliveOnly = keepAliveOnly
    self.inputChannels = max(configuration.inputChannelCount, 16)

    var localProcessor = DownmixProcessor()
    localProcessor.apply(configuration: configuration)
    processor = localProcessor

    // ~100ms of stereo at 48k for buffer between devices
    let ringCapacity = Int(Self.targetSampleRate * 0.1) * 2
    ring = FloatRingBuffer(capacity: ringCapacity)

    if !keepAliveOnly {
      inputUnit = try makeHALUnit()
      try configureInputUnit(inputUnit!, deviceID: inputDeviceID)
    }

    outputUnit = try makeHALUnit()
    try configureOutputUnit(outputUnit!, deviceID: outputDeviceID)

    if let inputUnit {
      try startUnit(inputUnit)
    }
    try startUnit(outputUnit!)

    stateLock.lock()
    isRunning = true
    stateLock.unlock()

    publish(
      phase: keepAliveOnly ? .keepAlive : .running,
      message: keepAliveOnly ? "Output keep-alive running" : "Stereo renderer running"
    )
    if !keepAliveOnly {
      startMeterTimer()
    }
  }

  func updateConfiguration(_ configuration: DownmixProcessor.Configuration) {
    stateLock.lock()
    self.configuration = configuration
    processor.apply(configuration: configuration)
    stateLock.unlock()
  }

  func stop() {
    logger.info("Stop requested")
    try? stopInternal(notify: true)
  }

  deinit {
    logger.info("AudioEngine deinitialized")
    try? stopInternal(notify: false)
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

    var bufferFrames = framesPerBuffer
    try check(
      AudioUnitSetProperty(
        unit,
        kAudioDevicePropertyBufferFrameSize,
        kAudioUnitScope_Global,
        0,
        &bufferFrames,
        UInt32(MemoryLayout<UInt32>.size)
      ),
      "set input buffer frame size"
    )

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

    var bufferFrames = framesPerBuffer
    try check(
      AudioUnitSetProperty(
        unit,
        kAudioDevicePropertyBufferFrameSize,
        kAudioUnitScope_Global,
        0,
        &bufferFrames,
        UInt32(MemoryLayout<UInt32>.size)
      ),
      "set output buffer frame size"
    )

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

    try check(AudioUnitInitialize(unit), "initialize output unit")
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
    meterTimer?.cancel()
    meterTimer = nil

    stateLock.lock()
    isRunning = false
    let inUnit = inputUnit
    let outUnit = outputUnit
    inputUnit = nil
    outputUnit = nil
    stateLock.unlock()

    if let inUnit {
      AudioOutputUnitStop(inUnit)
      AudioUnitUninitialize(inUnit)
      AudioComponentInstanceDispose(inUnit)
    }
    if let outUnit {
      AudioOutputUnitStop(outUnit)
      AudioUnitUninitialize(outUnit)
      AudioComponentInstanceDispose(outUnit)
    }
    ring?.clear()
    ring = nil

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

  private func publish(phase: EnginePhase, message: String, meters: MeterSnapshot? = nil) {
    stateLock.lock()
    status.phase = phase
    status.message = message
    if let meters {
      status.meters = meters
    }
    let snapshot = status
    stateLock.unlock()
    onStatus?(snapshot)
  }

  // MARK: - Callbacks

  private var inputData = [Float]()
  private var scratchStereo = [Float]()

  fileprivate func handleInput(
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    frameCount: UInt32
  ) -> OSStatus {
    guard let unit = inputUnit, let ring else { return noErr }

    let channels = inputChannels
    let samples = Int(frameCount) * channels
    if inputData.count < samples {
      inputData = [Float](repeating: 0, count: samples)
    }

    let stereoSamples = Int(frameCount) * 2
    if scratchStereo.count < stereoSamples {
      scratchStereo = [Float](repeating: 0, count: stereoSamples)
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
    guard renderStatus == noErr else { return renderStatus }

    stateLock.lock()
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
    stateLock.unlock()

    scratchStereo.withUnsafeBufferPointer { buf in
      _ = ring.write(buf.baseAddress!, count: stereoSamples)
    }
    return noErr
  }

  fileprivate func handleOutput(
    frameCount: UInt32,
    bufferList: UnsafeMutablePointer<AudioBufferList>
  ) -> OSStatus {
    let abl = UnsafeMutableAudioBufferListPointer(bufferList)
    guard let first = abl.first, let data = first.mData else { return noErr }

    let out = data.bindMemory(to: Float.self, capacity: Int(frameCount) * 2)
    let needed = Int(frameCount) * 2

    if keepAliveOnly {
      out.update(repeating: 0, count: needed)
      return noErr
    }

    guard let ring else {
      out.update(repeating: 0, count: needed)
      return noErr
    }

    let read = ring.read(into: out, count: needed)
    if read < needed {
      out.advanced(by: read).update(repeating: 0, count: needed - read)
    }
    return noErr
  }

  // MARK: - Meters

  private var meterTimer: DispatchSourceTimer?

  private func startMeterTimer() {
    meterTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    // The native meter view redraws without invalidating SwiftUI layout.
    timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      self.stateLock.lock()
      guard self.isRunning else {
        self.stateLock.unlock()
        return
      }
      let meters = self.processor.takeMeterSnapshot()
      let phase = self.status.phase
      let message = self.status.message
      self.status.meters = meters
      self.stateLock.unlock()
      self.onStatus?(EngineStatus(phase: phase, message: message, meters: meters))
    }
    timer.resume()
    meterTimer = timer
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
  guard let ioData else { return noErr }
  let engine = Unmanaged<AudioEngine>.fromOpaque(inRefCon).takeUnretainedValue()
  return engine.handleOutput(frameCount: inNumberFrames, bufferList: ioData)
}
