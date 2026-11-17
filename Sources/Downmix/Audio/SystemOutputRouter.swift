import CoreAudio
import Foundation

/// Reads and changes the Mac's default output device (System Settings → Sound → Output).
/// Implemented by `SystemOutputRouter`; checks inject their own.
@MainActor
protocol SystemOutputRouting: AnyObject {
  func defaultOutputUID() -> String?
  /// Returns false when the device is missing or Core Audio refuses the change.
  func setDefaultOutput(uid: String) -> Bool
  /// Names of other apps reading the device right now (another renderer such as Sfera).
  func otherRenderers(uid: String) -> [String]
  /// The change Downmix made, kept on disk so a crash or forced quit can still be undone
  /// on the next launch.
  var pendingRestore: SystemOutputRestore? { get set }
}

/// The default output before Downmix routed it, and the device it routed to.
struct SystemOutputRestore: Codable, Equatable, Sendable {
  let previousUID: String
  let routedUID: String
}

/// Players such as Music only see the device macOS hands them. If the default output is
/// the DAC itself, Music renders Dolby Atmos to a 2-channel device as stereo and Downmix
/// receives nothing. Routing the default output to Downmix's input (BlackHole) while the
/// renderer runs is what lets players deliver the multichannel bed.
@MainActor
final class SystemOutputRouter: SystemOutputRouting {
  private static let restoreKey = "systemOutputRestore"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var pendingRestore: SystemOutputRestore? {
    get {
      defaults.data(forKey: Self.restoreKey).flatMap {
        try? JSONDecoder().decode(SystemOutputRestore.self, from: $0)
      }
    }
    set {
      if let newValue, let data = try? JSONEncoder().encode(newValue) {
        defaults.set(data, forKey: Self.restoreKey)
      } else {
        defaults.removeObject(forKey: Self.restoreKey)
      }
    }
  }

  func defaultOutputUID() -> String? {
    var address = Self.defaultOutputAddress
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
      id != kAudioObjectUnknown
    else { return nil }
    return DeviceManager.uid(id: id)
  }

  func setDefaultOutput(uid: String) -> Bool {
    guard var id = DeviceManager.deviceID(uid: uid) else { return false }
    var address = Self.defaultOutputAddress
    return AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
      UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
  }

  func otherRenderers(uid: String) -> [String] {
    guard let id = DeviceManager.deviceID(uid: uid) else { return [] }
    return AudioSourceMonitor.renderers(of: id)?.map(\.name) ?? []
  }

  private static let defaultOutputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
}
