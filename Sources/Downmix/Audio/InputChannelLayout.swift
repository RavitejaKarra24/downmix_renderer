import CoreAudio
import Foundation

/// The 9.1.6 bed layout the selected input device must advertise to clients.
///
/// Players negotiate their output channel count from this device layout. CoreAudio
/// labels that no channel bitmap covers (`LeftTopMiddle`/`RightTopMiddle`,
/// `LeftTopRear`/`RightTopRear`) and `Unknown` labels cannot be converted, so
/// AVFoundation- and FFmpeg-based players abandon the layout and fall back to a
/// stereo stream: BlackHole then carries only L/R and every other bed input stays
/// silent. The labels below are the closest ones every client can convert, in the
/// bed order the processor expects.
enum InputChannelLayout {
  /// Channel count the bed layout describes. Other input widths are left untouched.
  static let channelCount = 16

  /// L, R, C, LFE, Ls, Rs, Lrs, Rrs, Lw, Rw, Ltf, Rtf, Ltm, Rtm, Ltr, Rtr.
  static let bedLabels: [AudioChannelLabel] = [
    kAudioChannelLabel_Left,
    kAudioChannelLabel_Right,
    kAudioChannelLabel_Center,
    kAudioChannelLabel_LFEScreen,
    kAudioChannelLabel_LeftSurround,
    kAudioChannelLabel_RightSurround,
    kAudioChannelLabel_RearSurroundLeft,
    kAudioChannelLabel_RearSurroundRight,
    kAudioChannelLabel_LeftWide,
    kAudioChannelLabel_RightWide,
    kAudioChannelLabel_VerticalHeightLeft,
    kAudioChannelLabel_VerticalHeightRight,
    // No convertible top-middle pair exists; top-centre labels keep the layout usable.
    kAudioChannelLabel_TopCenterSurround,
    kAudioChannelLabel_VerticalHeightCenter,
    // Top-rear doubles as the bed's top-rear pair.
    kAudioChannelLabel_TopBackLeft,
    kAudioChannelLabel_TopBackRight,
  ]

  private static let descriptionOffset = MemoryLayout<AudioChannelLayout>.offset(
    of: \.mChannelDescriptions)!
  private static let dataSize =
    descriptionOffset + channelCount * MemoryLayout<AudioChannelDescription>.size

  /// Byte payload for `kAudioDevicePropertyPreferredChannelLayout`.
  static func layoutData() -> Data {
    var data = Data(count: dataSize)
    data.withUnsafeMutableBytes { raw in
      guard let base = raw.baseAddress else { return }
      let layout = base.assumingMemoryBound(to: AudioChannelLayout.self)
      layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
      layout.pointee.mChannelBitmap = []
      layout.pointee.mNumberChannelDescriptions = UInt32(channelCount)
      let descriptions = base.advanced(by: descriptionOffset)
        .assumingMemoryBound(to: AudioChannelDescription.self)
      for (index, label) in bedLabels.enumerated() {
        descriptions[index] = AudioChannelDescription(
          mChannelLabel: label, mChannelFlags: [], mCoordinates: (0, 0, 0))
      }
    }
    return data
  }

  /// `nil` when the device reports another width, a tag-only layout or unreadable data.
  static func labels(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope)
    -> [AudioChannelLabel]?
  {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyPreferredChannelLayout, mScope: scope,
      mElement: kAudioObjectPropertyElementMain)
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: dataSize, alignment: MemoryLayout<AudioChannelLayout>.alignment)
    defer { raw.deallocate() }
    var size = UInt32(dataSize)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr,
      size == UInt32(dataSize)
    else { return nil }
    let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self).pointee
    guard layout.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions,
      layout.mNumberChannelDescriptions == UInt32(channelCount)
    else { return nil }
    let descriptions = raw.advanced(by: descriptionOffset)
      .assumingMemoryBound(to: AudioChannelDescription.self)
    return (0..<channelCount).map { descriptions[$0].mChannelLabel }
  }

  static func isInstalled(deviceID: AudioDeviceID) -> Bool {
    for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
      guard labels(deviceID: deviceID, scope: scope) == bedLabels else { return false }
    }
    return true
  }

  /// Installs the bed layout before the device is opened, so a player that reopens its
  /// stream negotiates every bed channel instead of a stereo fallback.
  /// Returns `nil` when the input width is not a 16-channel bed, `false` when the HAL
  /// refused the change (rendering still runs, but players may fall back to stereo).
  @discardableResult
  static func installIfNeeded(deviceID: AudioDeviceID, channelCount: Int) -> Bool? {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard channelCount == Self.channelCount else { return nil }
    let data = layoutData()
    var installed = true
    for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
      if labels(deviceID: deviceID, scope: scope) == bedLabels { continue }
      if !write(data, deviceID: deviceID, scope: scope) { installed = false }
    }
    return installed && isInstalled(deviceID: deviceID)
  }

  private static func write(
    _ data: Data, deviceID: AudioDeviceID, scope: AudioObjectPropertyScope
  ) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyPreferredChannelLayout, mScope: scope,
      mElement: kAudioObjectPropertyElementMain)
    var settable: DarwinBoolean = false
    guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
      settable.boolValue
    else { return false }
    let status = data.withUnsafeBytes { raw in
      AudioObjectSetPropertyData(
        deviceID, &address, 0, nil, UInt32(data.count), raw.baseAddress!)
    }
    return status == noErr
  }
}
