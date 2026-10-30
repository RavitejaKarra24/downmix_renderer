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
  }
  struct Unit {
    var device: AudioDeviceID = 0
    var maximum: UInt32 = 4096
    var client = AudioStreamBasicDescription()
    var callback = AURenderCallbackStruct()
    var isInput = false
    var hardwareRate = 48_000.0
    var started = false
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
    renderHook.withLock { $0 = nil }
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
    stubHAL.units[unit]!.device = data.load(as: AudioDeviceID.self)
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
      format.mSampleRate = state.hardwareRate
      let device = stubHAL.devices[state.device]!
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
  for buffer in UnsafeMutableAudioBufferListPointer(data) {
    if let pointer = buffer.mData { memset(pointer, 0, Int(buffer.mDataByteSize)) }
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
  case kAudioDevicePropertyPreferredChannelLayout:
    settable.pointee = DarwinBoolean(stubHAL.layoutSettable)
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
  case kAudioDevicePropertyStreams: size.pointee = 4
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
    data.storeBytes(of: format, as: AudioStreamBasicDescription.self)
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
