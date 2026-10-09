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

  private static func sampleRate(id: AudioDeviceID) -> Double {
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
