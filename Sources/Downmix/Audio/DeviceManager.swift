import CoreAudio
import Foundation

enum DeviceManager {
  static func allDevices() -> [AudioDeviceInfo] {
    let ids = deviceIDs()
    return ids.compactMap(makeDeviceInfo(id:))
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  static func inputDevices() -> [AudioDeviceInfo] {
    allDevices().filter(\.isInputCapable)
  }

  static func outputDevices() -> [AudioDeviceInfo] {
    allDevices().filter(\.isOutputCapable)
  }

  static func device(uid: String) -> AudioDeviceInfo? {
    allDevices().first { $0.uid == uid }
  }

  static func isSafeOutputRoute(_ device: AudioDeviceInfo, inputUID: String) -> Bool {
    let inputID: AudioDeviceID?
    if inputUID.isEmpty {
      inputID = nil
    } else {
      guard let resolved = deviceID(uid: inputUID) else { return false }
      inputID = resolved
    }
    return isSafeRoute(outputID: device.id, inputID: inputID, readNode: routeNode)
  }

  static func preferredInput(
    matchingName name: String?, uid: String?, devices catalog: [AudioDeviceInfo]? = nil
  ) -> AudioDeviceInfo? {
    let devices = (catalog ?? allDevices()).filter(\.isInputCapable)
    if let uid, !uid.isEmpty { return devices.first(where: { $0.uid == uid }) }
    if let name, !name.isEmpty {
      return devices.first(where: { namesMatch($0.name, name) })
    }
    return devices.first(where: {
      $0.name.localizedCaseInsensitiveContains("blackhole") && $0.inputChannelCount >= 16
    })
      ?? devices.first(where: { $0.inputChannelCount >= 16 })
  }

  static func preferredOutput(
    matchingName name: String?, uid: String?, devices catalog: [AudioDeviceInfo]? = nil,
    routeSafety: (AudioDeviceInfo, String) -> Bool = isSafeOutputRoute
  ) -> AudioDeviceInfo? {
    let devices = (catalog ?? allDevices()).filter(\.isOutputCapable)
    if let uid, !uid.isEmpty { return devices.first(where: { $0.uid == uid }) }
    if let name, !name.isEmpty {
      return devices.first(where: { namesMatch($0.name, name) })
    }
    return devices.first(where: {
      $0.outputChannelCount == 2 && routeSafety($0, "")
    })
      ?? devices.first(where: { $0.outputChannelCount >= 2 && routeSafety($0, "") })
  }

  private static func namesMatch(_ a: String, _ b: String) -> Bool {
    normalize(a) == normalize(b)
  }

  private static func normalize(_ name: String) -> String {
    name
      .lowercased()
      .replacingOccurrences(of: #"\s*\(unavailable\)\s*$"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func deviceID(uid: String) -> AudioDeviceID? {
    // UID translation avoids enumerating the full device list for every safety
    // certificate and every watchdog tick. The qualifier is a CFString pointer.
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var qualifier = uid as CFString
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let result = withUnsafePointer(to: &qualifier) { pointer in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
    }
    guard result == noErr, size == MemoryLayout<AudioDeviceID>.size,
      id != kAudioObjectUnknown
    else { return nil }
    return id
  }

  private static func deviceIDs() -> [AudioDeviceID] {
    var property = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &dataSize) == noErr
    else {
      return []
    }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &dataSize, &ids) == noErr
    else {
      return []
    }
    return ids
  }

  private static func makeDeviceInfo(id: AudioDeviceID) -> AudioDeviceInfo? {
    let name = stringProperty(id: id, selector: kAudioObjectPropertyName) ?? "Device \(id)"
    let uid = stringProperty(id: id, selector: kAudioDevicePropertyDeviceUID) ?? "\(id)"
    let inputs = channelCount(id: id, scope: kAudioDevicePropertyScopeInput)
    let outputs = channelCount(id: id, scope: kAudioDevicePropertyScopeOutput)
    if inputs == 0 && outputs == 0 { return nil }
    let rate = sampleRate(id: id)
    return AudioDeviceInfo(
      id: id,
      name: name,
      uid: uid,
      inputChannelCount: inputs,
      outputChannelCount: outputs,
      nominalSampleRate: rate
    )
  }

  struct RouteNode {
    let uid: String
    let name: String
    let children: [AudioDeviceID]
  }

  /// Resolve BOTH graphs, including roots and intermediate aggregates. A nil node,
  /// empty identity or cycle cannot certify safety. Shared DAG children are not cycles.
  static func isSafeRoute(
    outputID: AudioDeviceID, inputID: AudioDeviceID?,
    readNode: (AudioDeviceID) -> RouteNode?
  ) -> Bool {
    func resolve(_ id: AudioDeviceID, path: Set<AudioDeviceID>, rejectBlackHole: Bool)
      -> (ids: Set<AudioDeviceID>, uids: Set<String>)?
    {
      guard path.count < 256, !path.contains(id), let node = readNode(id), !node.uid.isEmpty,
        !node.name.isEmpty
      else { return nil }
      if rejectBlackHole,
        node.uid.localizedCaseInsensitiveContains("blackhole")
          || node.name.localizedCaseInsensitiveContains("blackhole")
      {
        return nil
      }
      var ids: Set<AudioDeviceID> = [id]
      var uids: Set<String> = [node.uid]
      for child in node.children {
        guard
          let graph = resolve(
            child, path: path.union([id]), rejectBlackHole: rejectBlackHole)
        else { return nil }
        ids.formUnion(graph.ids)
        uids.formUnion(graph.uids)
      }
      return (ids, uids)
    }
    guard let output = resolve(outputID, path: [], rejectBlackHole: true) else { return false }
    guard let inputID else { return true }
    guard let input = resolve(inputID, path: [], rejectBlackHole: false) else { return false }
    return output.ids.isDisjoint(with: input.ids) && output.uids.isDisjoint(with: input.uids)
  }

  private static func routeNode(deviceID: AudioDeviceID) -> RouteNode? {
    guard let uid = stringProperty(id: deviceID, selector: kAudioDevicePropertyDeviceUID),
      let name = stringProperty(id: deviceID, selector: kAudioObjectPropertyName)
    else { return nil }

    var property = AudioObjectPropertyAddress(
      mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &property) else {
      // An aggregate with an unavailable subdevice property is not a known leaf.
      var classAddress = property
      classAddress.mSelector = kAudioObjectPropertyClass
      var objectClass: AudioClassID = 0
      var size = UInt32(MemoryLayout<AudioClassID>.size)
      guard
        AudioObjectGetPropertyData(deviceID, &classAddress, 0, nil, &size, &objectClass)
          == noErr, size == MemoryLayout<AudioClassID>.size,
        objectClass != kAudioAggregateDeviceClassID
      else { return nil }
      return RouteNode(uid: uid, name: name, children: [])
    }

    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &property, 0, nil, &dataSize) == noErr,
      dataSize > 0, Int(dataSize).isMultiple(of: MemoryLayout<AudioDeviceID>.size)
    else {
      return nil
    }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var subdeviceIDs = [AudioDeviceID](repeating: 0, count: count)
    guard
      AudioObjectGetPropertyData(
        deviceID,
        &property,
        0,
        nil,
        &dataSize,
        &subdeviceIDs
      ) == noErr
    else {
      return nil
    }
    guard Int(dataSize) == count * MemoryLayout<AudioDeviceID>.size else { return nil }
    return RouteNode(uid: uid, name: name, children: subdeviceIDs)
  }

  private static func stringProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector)
    -> String?
  {
    var property = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &dataSize) == noErr else {
      return nil
    }

    if selector == kAudioObjectPropertyName || selector == kAudioDevicePropertyDeviceUID {
      // CFString
      var cfValue: CFString?
      var size = UInt32(MemoryLayout<CFString?>.size)
      let status = withUnsafeMutablePointer(to: &cfValue) { pointer in
        AudioObjectGetPropertyData(id, &property, 0, nil, &size, pointer)
      }
      guard status == noErr, let cfValue else { return nil }
      return cfValue as String
    }

    return nil
  }

  struct InputFormat: Sendable {
    let channels: Int
    let rate: Double
  }

  /// Nominal rates the device advertises. `nil` when the property is unreadable.
  static func availableNominalRates(id: AudioDeviceID) -> [AudioValueRange]? {
    var property = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr, size > 0,
      Int(size).isMultiple(of: MemoryLayout<AudioValueRange>.size)
    else { return nil }
    let count = Int(size) / MemoryLayout<AudioValueRange>.size
    var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
    guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &ranges) == noErr,
      Int(size) == count * MemoryLayout<AudioValueRange>.size
    else { return nil }
    return ranges
  }

  /// Bit depth and sample kind of an output device's physical (DAC-side) format.
  struct PhysicalFormat: Equatable, Sendable {
    let sampleRate: Double
    let bits: Int
    let isFloat: Bool

    init(sampleRate: Double, bits: Int, isFloat: Bool) {
      self.sampleRate = sampleRate
      self.bits = bits
      self.isFloat = isFloat
    }

    init(_ format: AudioStreamBasicDescription) {
      sampleRate = format.mSampleRate
      bits = Int(format.mBitsPerChannel)
      isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
    }

    var label: String { "\(bits)-bit \(isFloat ? "float" : "integer")" }
  }

  /// The deepest linear-PCM physical format offered at `rate` for `channels` channels.
  /// Downmix delivers a 32-bit float mix (gain, filtering and clock correction already
  /// applied), so the deepest DAC format keeps all of it. At equal depth an integer
  /// format wins: it is the DAC's native word.
  static func deepestPhysicalFormat(
    in available: [AudioStreamRangedDescription], rate: Double, channels: UInt32
  ) -> AudioStreamBasicDescription? {
    physicalFormat(in: available, rate: rate, channels: channels, preferredBits: nil)
  }

  /// With `preferredBits` (the source's own bit depth), the exact depth when offered,
  /// else the nearest deeper one, else the deepest. Without it, the deepest.
  static func physicalFormat(
    in available: [AudioStreamRangedDescription], rate: Double, channels: UInt32,
    preferredBits: Int?
  ) -> AudioStreamBasicDescription? {
    let candidates = available.compactMap { ranged -> AudioStreamBasicDescription? in
      var format = ranged.mFormat
      guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel > 0,
        format.mBitsPerChannel <= 64, format.mChannelsPerFrame == channels
      else { return nil }
      if format.mSampleRate == 0 {
        // A ranged entry: valid for any rate inside its range.
        guard rate >= ranged.mSampleRateRange.mMinimum - 0.5,
          rate <= ranged.mSampleRateRange.mMaximum + 0.5
        else { return nil }
        format.mSampleRate = rate
      } else if abs(format.mSampleRate - rate) > 0.5 {
        return nil
      }
      return format
    }
    func isInteger(_ format: AudioStreamBasicDescription) -> Int {
      format.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? 0 : 1
    }
    let deepest = candidates.max {
      ($0.mBitsPerChannel, isInteger($0)) < ($1.mBitsPerChannel, isInteger($1))
    }
    guard let preferredBits, preferredBits > 0 else { return deepest }
    let deepEnough = candidates.filter { Int($0.mBitsPerChannel) >= preferredBits }
    // Shallowest format that still holds every source bit; integer wins a tie.
    return deepEnough.min {
      ($0.mBitsPerChannel, -isInteger($0)) < ($1.mBitsPerChannel, -isInteger($1))
    } ?? deepest
  }

  /// Moves every output stream of `deviceID` to the physical format chosen for `rate`
  /// and `preferredBits` (see `physicalFormat(in:rate:channels:preferredBits:)`). Best
  /// effort: a refusal leaves the device as it was. Returns the first stream's format.
  static func applyOutputFormat(
    deviceID: AudioDeviceID, rate: Double, preferredBits: Int?
  ) -> PhysicalFormat? {
    var property = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &property, 0, nil, &size) == noErr, size > 0,
      Int(size).isMultiple(of: MemoryLayout<AudioStreamID>.size)
    else { return nil }
    var streams = [AudioStreamID](
      repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    guard AudioObjectGetPropertyData(deviceID, &property, 0, nil, &size, &streams) == noErr
    else { return nil }
    var result: PhysicalFormat?
    for stream in streams.prefix(Int(size) / MemoryLayout<AudioStreamID>.size) {
      guard var current = physicalFormat(stream: stream) else { continue }
      if let chosen = physicalFormat(
        in: availablePhysicalFormats(stream: stream), rate: rate,
        channels: current.mChannelsPerFrame, preferredBits: preferredBits),
        PhysicalFormat(chosen).bits != PhysicalFormat(current).bits
          || PhysicalFormat(chosen).isFloat != PhysicalFormat(current).isFloat
      {
        var address = AudioObjectPropertyAddress(
          mSelector: kAudioStreamPropertyPhysicalFormat,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        )
        var settable: DarwinBoolean = false
        var format = chosen
        if AudioObjectIsPropertySettable(stream, &address, &settable) == noErr,
          settable.boolValue,
          AudioObjectSetPropertyData(
            stream, &address, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &format) == noErr,
          let updated = physicalFormat(stream: stream)
        {
          current = updated
        }
      }
      if result == nil { result = PhysicalFormat(current) }
    }
    return result
  }

  static func physicalFormat(stream: AudioStreamID) -> AudioStreamBasicDescription? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioStreamPropertyPhysicalFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format) == noErr,
      size == MemoryLayout<AudioStreamBasicDescription>.size, format.mChannelsPerFrame > 0
    else { return nil }
    return format
  }

  static func availablePhysicalFormats(stream: AudioStreamID) -> [AudioStreamRangedDescription] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let stride = MemoryLayout<AudioStreamRangedDescription>.size
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(stream, &address, 0, nil, &size) == noErr, size > 0,
      Int(size).isMultiple(of: stride)
    else { return [] }
    var formats = [AudioStreamRangedDescription](
      repeating: AudioStreamRangedDescription(), count: Int(size) / stride)
    guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &formats) == noErr else {
      return []
    }
    return Array(formats.prefix(Int(size) / stride))
  }

  /// Near-exact match: a device that offers 96 kHz reports it as a point or a small range.
  static func isSampleRateAvailable(_ rate: Double, id: AudioDeviceID) -> Bool {
    guard let ranges = availableNominalRates(id: id) else { return true }
    return ranges.contains { range in
      rate >= range.mMinimum - 0.5 && rate <= range.mMaximum + 0.5
    }
  }

  /// Live input width and nominal rate. Unlike the cached catalog these are read at the
  /// moment of use, because players and sample-rate switchers change them while running.
  static func inputFormat(id: AudioDeviceID) -> InputFormat? {
    let channels = channelCount(id: id, scope: kAudioDevicePropertyScopeInput)
    let rate = sampleRate(id: id)
    guard channels > 0, rate.isFinite, rate > 0 else { return nil }
    return InputFormat(channels: channels, rate: rate)
  }

  static func channelCount(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var property = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &dataSize) == noErr, dataSize > 0
    else {
      return 0
    }
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let capacity = Int(dataSize)
    let headerSize = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
    guard AudioObjectGetPropertyData(id, &property, 0, nil, &dataSize, raw) == noErr,
      Int(dataSize) <= capacity, Int(dataSize) >= headerSize
    else { return 0 }
    let bufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    guard
      Int(bufferList.pointee.mNumberBuffers)
        <= (Int(dataSize) - headerSize) / MemoryLayout<AudioBuffer>.stride
    else { return 0 }
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    var total = 0
    for buffer in buffers {
      total += Int(buffer.mNumberChannels)
    }
    return total
  }

  static func sampleRate(id: AudioDeviceID) -> Double {
    var property = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var rate = 0.0
    var size = UInt32(MemoryLayout<Double>.size)
    guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &rate) == noErr else {
      return 0
    }
    return rate
  }
}
