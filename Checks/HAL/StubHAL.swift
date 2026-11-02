import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// All graph/unit state is confined to the engine check queue. Render hooks alone
/// are protected by a Mutex, because the quiescence check uses a callback thread.
/// These local API shadows never forward to system HAL or open hardware units.
final class StubHAL: @unchecked Sendable {
  struct Device {
    var uid: String
    var name: String
    var inputChannels = 0
    var outputChannels = 0
    var rate = 48_000.0
    var alive: UInt32 = 1
    var children: [AudioDeviceID]?
    var unreadable = false
    var physicalRate = 48_000.0
    var virtualRate = 48_000.0
    var availableRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
    /// Output-stream physical integer depth and the depths offered at every rate.
    var physicalBits: UInt32 = 16
    var availableBits: [UInt32] = [16, 24, 32]
    var physicalFormatSettable = true
    var physicalFormatWrites = 0
  }
  struct Unit {
    var device: AudioDeviceID = 0
    var maximum: UInt32 = 4096
    var client = AudioStreamBasicDescription()
    var callback = AURenderCallbackStruct()
    var isInput = false
    var started = false
    // Adversarial driver model: a device-side rate cache survives uninitialize even
    // though property queries report fresh rates. Only rebinding/recreation clears it.
    var boundDeviceRate = 0.0
  }
  var devices: [AudioDeviceID: Device] = [:]
  var units: [AudioComponentInstance: Unit] = [:]
  /// Device preferred channel layouts as label lists, per scope. Absent means the
  /// device reports a layout this width cannot describe.
  var layouts: [AudioDeviceID: [AudioObjectPropertyScope: [AudioChannelLabel]]] = [:]
  var layoutSettable = true
  var layoutWriteFailures = 0
  var layoutWrites = 0
  var disposalFailures = 0
  var initializeFailure: OSStatus = noErr
  var disposalProbe: (() -> Void)?
  var stopProbe: (() -> Void)?
  var disposalCount = 0
  var nextUnit = 1
  /// Per-channel sample value returned by input renders, mirroring what a player
  /// writes into BlackHole. `nil` renders silence.
  var inputValues: [Float]?
  let renderHook = Mutex<(@Sendable () -> Void)?>(nil)

  func reset() {
    precondition(units.isEmpty)
    devices = [
      101: Device(uid: "capture", name: "Capture", inputChannels: 16),
      201: Device(uid: "speakers", name: "Speakers", outputChannels: 2),
    ]
    disposalFailures = 0
    initializeFailure = noErr
    disposalProbe = nil
    stopProbe = nil
    disposalCount = 0
    layouts = [:]
    layoutSettable = true
    layoutWriteFailures = 0
    layoutWrites = 0
    inputValues = nil
    renderHook.withLock { $0 = nil }
  }

  func inputCallback(frames: UInt32) -> OSStatus {
    let unit = units.values.first { $0.isInput }!
    var flags: AudioUnitRenderActionFlags = []
    var timestamp = AudioTimeStamp()
    return unit.callback.inputProc!(
      unit.callback.inputProcRefCon!, &flags, &timestamp, 1, frames, nil)
  }

  /// Pump valid stereo output at an independently modelled device cadence. If a unit
  /// retains its old device-side conversion ratio, matching ASBDs alone will not save it.
  func clockedOutputCallback(deviceFrames: UInt32) -> [Float] {
    let unit = units.values.first { !$0.isInput }!
    let frames = UInt32(
      (Double(deviceFrames) * unit.client.mSampleRate / unit.boundDeviceRate).rounded())
    var samples = [Float](repeating: 0, count: Int(frames) * 2)
    var flags: AudioUnitRenderActionFlags = []
    var timestamp = AudioTimeStamp()
    samples.withUnsafeMutableBytes { raw in
      var list = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
      precondition(
        unit.callback.inputProc!(
          unit.callback.inputProcRefCon!, &flags, &timestamp, 0, frames, &list)
          == noErr)
    }
    return samples
  }

  func outputCallback(nilData: Bool = true) -> OSStatus {
    let unit = units.values.first { !$0.isInput }!
    var flags: AudioUnitRenderActionFlags = []
    var timestamp = AudioTimeStamp()
    precondition(nilData)
    return unit.callback.inputProc!(unit.callback.inputProcRefCon!, &flags, &timestamp, 0, 32, nil)
  }
}

let stubHAL = StubHAL()

// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioComponentFindNext(
  _ previous: AudioComponent?, _ description: UnsafePointer<AudioComponentDescription>
) -> AudioComponent? { AudioComponent(bitPattern: 1) }

// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioComponentInstanceNew(
  _ component: AudioComponent, _ result: UnsafeMutablePointer<AudioComponentInstance?>
) -> OSStatus {
  let unit = AudioComponentInstance(bitPattern: stubHAL.nextUnit)!
  stubHAL.nextUnit += 1
  stubHAL.units[unit] = StubHAL.Unit()
  result.pointee = unit
  return noErr
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioComponentInstanceDispose(_ unit: AudioComponentInstance) -> OSStatus {
  stubHAL.disposalProbe?()
  if stubHAL.disposalFailures > 0 {
    stubHAL.disposalFailures -= 1
    return kAudioUnitErr_CannotDoInCurrentContext
  }
  stubHAL.units.removeValue(forKey: unit)
  stubHAL.disposalCount += 1
  return noErr
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioUnitInitialize(_ unit: AudioUnit) -> OSStatus { stubHAL.initializeFailure }
// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioUnitUninitialize(_ unit: AudioUnit) -> OSStatus { noErr }
// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioOutputUnitStart(_ unit: AudioUnit) -> OSStatus {
  stubHAL.units[unit]!.started = true
  return noErr
}
// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioOutputUnitStop(_ unit: AudioUnit) -> OSStatus {
  stubHAL.stopProbe?()
  stubHAL.units[unit]!.started = false
  return noErr
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioUnitSetProperty(
  _ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
  _ bus: AudioUnitElement, _ data: UnsafeRawPointer, _ size: UInt32
) -> OSStatus {
  switch property {
  case kAudioOutputUnitProperty_CurrentDevice:
    let deviceID = data.load(as: AudioDeviceID.self)
    stubHAL.units[unit]!.device = deviceID
    stubHAL.units[unit]!.boundDeviceRate = stubHAL.devices[deviceID]!.rate
  case kAudioUnitProperty_StreamFormat:
    stubHAL.units[unit]!.client = data.load(as: AudioStreamBasicDescription.self)
    stubHAL.units[unit]!.isInput = bus == 1
  case kAudioUnitProperty_MaximumFramesPerSlice:
    stubHAL.units[unit]!.maximum = data.load(as: UInt32.self)
  case kAudioOutputUnitProperty_SetInputCallback, kAudioUnitProperty_SetRenderCallback:
    stubHAL.units[unit]!.callback = data.load(as: AURenderCallbackStruct.self)
  case kAudioOutputUnitProperty_EnableIO: break
  default: preconditionFailure("Unexpected unit property \(property)")
  }
  return noErr
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioUnitGetProperty(
  _ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
  _ bus: AudioUnitElement, _ data: UnsafeMutableRawPointer, _ size: UnsafeMutablePointer<UInt32>
) -> OSStatus {
  let state = stubHAL.units[unit]!
  switch property {
  case kAudioOutputUnitProperty_CurrentDevice:
    data.storeBytes(of: state.device, as: AudioDeviceID.self)
  case kAudioUnitProperty_MaximumFramesPerSlice: data.storeBytes(of: state.maximum, as: UInt32.self)
  case kAudioUnitProperty_StreamFormat:
    var format = state.client
    let client =
      (state.isInput && scope == kAudioUnitScope_Output)
      || (!state.isInput && scope == kAudioUnitScope_Input)
    if !client {
      // AUHAL's device side always tracks the live device, including live rate changes.
      let device = stubHAL.devices[state.device]!
      format.mSampleRate = device.rate
      format.mChannelsPerFrame = UInt32(
        state.isInput ? device.inputChannels : device.outputChannels)
    }
    data.storeBytes(of: format, as: AudioStreamBasicDescription.self)
  default: preconditionFailure("Unexpected unit query \(property)")
  }
  return noErr
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioUnitRender(
  _ unit: AudioUnit, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
  _ timestamp: UnsafePointer<AudioTimeStamp>, _ bus: AudioUnitElement, _ frames: UInt32,
  _ data: UnsafeMutablePointer<AudioBufferList>
) -> OSStatus {
  let hook = stubHAL.renderHook.withLock { $0 }
  hook?()
  let unit = stubHAL.units[unit]!
  let device = stubHAL.devices[unit.device]!
  if unit.isInput {
    // Measured AUHAL behaviour: a virtual input cannot convert rates, so a client
    // format whose rate differs from the live device fails every render.
    guard unit.client.mSampleRate == device.rate else {
      return kAudioUnitErr_CannotDoInCurrentContext
    }
  }
  for buffer in UnsafeMutableAudioBufferListPointer(data) {
    guard let pointer = buffer.mData else { continue }
    let samples = pointer.assumingMemoryBound(to: Float.self)
    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
    let channels = max(1, Int(buffer.mNumberChannels))
    if unit.isInput, let values = stubHAL.inputValues, !values.isEmpty {
      for index in 0..<count {
        samples[index] = values[min(values.count - 1, index % channels)]
      }
    } else {
      memset(pointer, 0, Int(buffer.mDataByteSize))
    }
  }
  return noErr
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioObjectHasProperty(
  _ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>
) -> Bool {
  precondition(address.pointee.mSelector == kAudioAggregateDevicePropertyActiveSubDeviceList)
  return stubHAL.devices[id]?.children != nil
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioObjectIsPropertySettable(
  _ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
  _ settable: UnsafeMutablePointer<DarwinBoolean>
) -> OSStatus {
  switch address.pointee.mSelector {
  case kAudioDevicePropertyBufferFrameSize:
    settable.pointee = false
  case kAudioDevicePropertyNominalSampleRate:
    settable.pointee = true
  case kAudioDevicePropertyPreferredChannelLayout:
    settable.pointee = DarwinBoolean(stubHAL.layoutSettable)
  case kAudioStreamPropertyPhysicalFormat:
    settable.pointee = DarwinBoolean(stubHAL.devices[id / 10]?.physicalFormatSettable ?? false)
  default:
    preconditionFailure("Unexpected settable query \(address.pointee.mSelector)")
  }
  return noErr
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioObjectSetPropertyData(
  _ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
  _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?, _ size: UInt32, _ data: UnsafeRawPointer
) -> OSStatus {
  if address.pointee.mSelector == kAudioDevicePropertyNominalSampleRate {
    guard var device = stubHAL.devices[id] else { return kAudioHardwareBadObjectError }
    let requested = data.load(as: Double.self)
    guard device.availableRates.contains(requested) else {
      return kAudioDeviceUnsupportedFormatError
    }
    device.rate = requested
    stubHAL.devices[id] = device
    return noErr
  }
  if address.pointee.mSelector == kAudioStreamPropertyPhysicalFormat {
    guard var device = stubHAL.devices[id / 10], id % 10 == 2 else {
      preconditionFailure("Physical format writes target output streams only")
    }
    let format = data.load(as: AudioStreamBasicDescription.self)
    precondition(size == MemoryLayout<AudioStreamBasicDescription>.size)
    precondition(format.mChannelsPerFrame == UInt32(device.outputChannels))
    guard device.availableBits.contains(format.mBitsPerChannel),
      format.mSampleRate == device.rate
    else { return kAudioDeviceUnsupportedFormatError }
    device.physicalBits = format.mBitsPerChannel
    device.physicalFormatWrites += 1
    stubHAL.devices[id / 10] = device
    return noErr
  }
  guard address.pointee.mSelector == kAudioDevicePropertyPreferredChannelLayout else {
    preconditionFailure("Checks must not mutate other device properties")
  }
  stubHAL.layoutWrites += 1
  if stubHAL.layoutWriteFailures > 0 {
    stubHAL.layoutWriteFailures -= 1
    return kAudioHardwareUnsupportedOperationError
  }
  let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
  let layout = data.assumingMemoryBound(to: AudioChannelLayout.self).pointee
  precondition(layout.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions)
  let count = Int(layout.mNumberChannelDescriptions)
  precondition(size == offset + count * MemoryLayout<AudioChannelDescription>.size)
  let descriptions = data.advanced(by: offset)
    .assumingMemoryBound(to: AudioChannelDescription.self)
  stubHAL.layouts[id, default: [:]][address.pointee.mScope] =
    (0..<count).map { descriptions[$0].mChannelLabel }
  return noErr
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioObjectGetPropertyDataSize(
  _ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
  _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>
) -> OSStatus {
  if stubHAL.devices[id]?.unreadable == true { return kAudioHardwareBadObjectError }
  switch address.pointee.mSelector {
  case kAudioHardwarePropertyDevices: size.pointee = UInt32(stubHAL.devices.count * 4)
  case kAudioObjectPropertyName, kAudioDevicePropertyDeviceUID:
    size.pointee = UInt32(MemoryLayout<CFString?>.size)
  case kAudioDevicePropertyStreamConfiguration:
    size.pointee = UInt32(MemoryLayout<AudioBufferList>.size)
  case kAudioAggregateDevicePropertyActiveSubDeviceList:
    size.pointee = UInt32((stubHAL.devices[id]?.children?.count ?? 0) * 4)
  case kAudioDevicePropertyAvailableNominalSampleRates:
    size.pointee = UInt32(
      (stubHAL.devices[id]?.availableRates.count ?? 0) * MemoryLayout<AudioValueRange>.size)
  case kAudioDevicePropertyStreams: size.pointee = 4
  case kAudioStreamPropertyAvailablePhysicalFormats:
    let device = stubHAL.devices[id / 10]!
    let count = id % 10 == 2 ? device.availableBits.count : 0
    size.pointee = UInt32(count * MemoryLayout<AudioStreamRangedDescription>.size)
  default: preconditionFailure("Unexpected size query \(address.pointee.mSelector)")
  }
  return noErr
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioObjectGetPropertyData(
  _ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
  _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>,
  _ data: UnsafeMutableRawPointer
) -> OSStatus {
  if stubHAL.devices[id]?.unreadable == true { return kAudioHardwareBadObjectError }
  let selector = address.pointee.mSelector
  if selector == kAudioHardwarePropertyTranslateUIDToDevice {
    precondition(qualifierSize == MemoryLayout<CFString>.size && qualifier != nil)
    let uid = qualifier!.load(as: CFString.self) as String
    let resolved = stubHAL.devices.first { $0.value.uid == uid }?.key ?? kAudioObjectUnknown
    data.storeBytes(of: resolved, as: AudioDeviceID.self)
    size.pointee = UInt32(MemoryLayout<AudioDeviceID>.size)
    return noErr
  }
  if selector == kAudioHardwarePropertyDevices {
    for (index, deviceID) in stubHAL.devices.keys.sorted().enumerated() {
      data.storeBytes(of: deviceID, toByteOffset: index * 4, as: AudioDeviceID.self)
    }
    return noErr
  }
  if selector == kAudioStreamPropertyVirtualFormat || selector == kAudioStreamPropertyPhysicalFormat
  {
    // Stream IDs encode direction and device; never collide with device IDs.
    let device = stubHAL.devices[id / 10]!
    var format = AudioStreamBasicDescription()
    format.mSampleRate =
      selector == kAudioStreamPropertyVirtualFormat
      ? device.virtualRate : device.physicalRate
    format.mChannelsPerFrame = UInt32(id % 10 == 1 ? device.inputChannels : device.outputChannels)
    if id % 10 == 2 && selector == kAudioStreamPropertyPhysicalFormat {
      format = stubIntegerFormat(
        rate: device.physicalRate, channels: format.mChannelsPerFrame, bits: device.physicalBits)
    }
    data.storeBytes(of: format, as: AudioStreamBasicDescription.self)
    return noErr
  }
  if selector == kAudioStreamPropertyAvailablePhysicalFormats {
    let device = stubHAL.devices[id / 10]!
    for (index, bits) in device.availableBits.enumerated() {
      // Ranged entries (rate 0) valid for every rate the device offers.
      let ranged = AudioStreamRangedDescription(
        mFormat: stubIntegerFormat(rate: 0, channels: UInt32(device.outputChannels), bits: bits),
        mSampleRateRange: AudioValueRange(
          mMinimum: device.availableRates.min() ?? 0, mMaximum: device.availableRates.max() ?? 0))
      data.storeBytes(
        of: ranged, toByteOffset: index * MemoryLayout<AudioStreamRangedDescription>.size,
        as: AudioStreamRangedDescription.self)
    }
    return noErr
  }
  guard let device = stubHAL.devices[id] else { return kAudioHardwareBadObjectError }
  switch selector {
  case kAudioObjectPropertyName, kAudioDevicePropertyDeviceUID:
    let string = (selector == kAudioObjectPropertyName ? device.name : device.uid) as CFString
    data.assumingMemoryBound(to: CFString?.self).pointee = string
  case kAudioObjectPropertyClass:
    data.storeBytes(
      of: device.children == nil ? kAudioDeviceClassID : kAudioAggregateDeviceClassID,
      as: AudioClassID.self)
  case kAudioDevicePropertyStreamConfiguration:
    let channels =
      address.pointee.mScope == kAudioDevicePropertyScopeInput
      ? device.inputChannels : device.outputChannels
    data.storeBytes(
      of: AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: 0, mData: nil)),
      as: AudioBufferList.self)
  case kAudioDevicePropertyNominalSampleRate: data.storeBytes(of: device.rate, as: Double.self)
  case kAudioDevicePropertyAvailableNominalSampleRates:
    for (index, value) in device.availableRates.enumerated() {
      let range = AudioValueRange(mMinimum: value, mMaximum: value)
      data.storeBytes(
        of: range, toByteOffset: index * MemoryLayout<AudioValueRange>.size,
        as: AudioValueRange.self)
    }
  case kAudioDevicePropertyDeviceIsAlive: data.storeBytes(of: device.alive, as: UInt32.self)
  case kAudioDevicePropertyBufferFrameSize: data.storeBytes(of: UInt32(128), as: UInt32.self)
  case kAudioDevicePropertyPreferredChannelLayout:
    guard let labels = stubHAL.layouts[id]?[address.pointee.mScope] else {
      return kAudioHardwareBadPropertySizeError
    }
    let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
    let payload = offset + labels.count * MemoryLayout<AudioChannelDescription>.size
    guard size.pointee >= UInt32(payload) else { return kAudioHardwareBadPropertySizeError }
    let layout = data.assumingMemoryBound(to: AudioChannelLayout.self)
    layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
    layout.pointee.mChannelBitmap = []
    layout.pointee.mNumberChannelDescriptions = UInt32(labels.count)
    let descriptions = data.advanced(by: offset)
      .assumingMemoryBound(to: AudioChannelDescription.self)
    for (index, label) in labels.enumerated() {
      descriptions[index] = AudioChannelDescription(
        mChannelLabel: label, mChannelFlags: [], mCoordinates: (0, 0, 0))
    }
    size.pointee = UInt32(payload)
  case kAudioAggregateDevicePropertyActiveSubDeviceList:
    for (index, child) in device.children!.enumerated() {
      data.storeBytes(of: child, toByteOffset: index * 4, as: AudioDeviceID.self)
    }
  case kAudioDevicePropertyStreams:
    let direction: UInt32 = address.pointee.mScope == kAudioDevicePropertyScopeInput ? 1 : 2
    data.storeBytes(of: id * 10 + direction, as: AudioStreamID.self)
  default: preconditionFailure("Unexpected device query \(selector)")
  }
  return noErr
}

func stubIntegerFormat(rate: Double, channels: UInt32, bits: UInt32) -> AudioStreamBasicDescription
{
  let bytes = bits / 8
  return AudioStreamBasicDescription(
    mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
    mBytesPerPacket: bytes * channels, mFramesPerPacket: 1, mBytesPerFrame: bytes * channels,
    mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
}
