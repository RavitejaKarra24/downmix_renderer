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
    !routeContainsDevice(
      deviceID: device.id,
      matchingUID: inputUID,
      rejectsBlackHole: true,
      visited: []
    )
  }

  static func preferredInput(matchingName name: String?, uid: String?) -> AudioDeviceInfo? {
    let devices = inputDevices()
    if let uid, let match = devices.first(where: { $0.uid == uid }) { return match }
    if let name, let match = devices.first(where: { namesMatch($0.name, name) }) { return match }
    return devices.first(where: {
      $0.name.localizedCaseInsensitiveContains("blackhole") && $0.inputChannelCount >= 16
    })
      ?? devices.first(where: { $0.inputChannelCount >= 16 })
  }

  static func preferredOutput(matchingName name: String?, uid: String?) -> AudioDeviceInfo? {
    let devices = outputDevices()
    if let uid, let match = devices.first(where: { $0.uid == uid }) { return match }
    if let name, let match = devices.first(where: { namesMatch($0.name, name) }) { return match }
    return devices.first(where: {
      $0.outputChannelCount == 2 && !$0.name.localizedCaseInsensitiveContains("blackhole")
    })
      ?? devices.first(where: { $0.outputChannelCount >= 2 })
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

  private static func routeContainsDevice(
    deviceID: AudioDeviceID,
    matchingUID inputUID: String,
    rejectsBlackHole: Bool,
    visited: Set<AudioDeviceID>
  ) -> Bool {
    guard !visited.contains(deviceID) else { return false }
    var visited = visited
    visited.insert(deviceID)

    let uid = stringProperty(id: deviceID, selector: kAudioDevicePropertyDeviceUID) ?? ""
    let name = stringProperty(id: deviceID, selector: kAudioObjectPropertyName) ?? ""
    if uid == inputUID
      || (rejectsBlackHole
        && (uid.localizedCaseInsensitiveContains("blackhole")
          || name.localizedCaseInsensitiveContains("blackhole")))
    {
      return true
    }

    var property = AudioObjectPropertyAddress(
      mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &property) else { return false }

    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &property, 0, nil, &dataSize) == noErr,
      dataSize > 0
    else {
      return false
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
      return false
    }
    return subdeviceIDs.contains {
      routeContainsDevice(
        deviceID: $0,
        matchingUID: inputUID,
        rejectsBlackHole: rejectsBlackHole,
        visited: visited
      )
    }
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

  private static func channelCount(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
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
    guard AudioObjectGetPropertyData(id, &property, 0, nil, &dataSize, raw) == noErr else {
      return 0
    }
    let bufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
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
