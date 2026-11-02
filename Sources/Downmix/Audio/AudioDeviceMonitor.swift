import CoreAudio
import Foundation

/// Event-driven discovery; retains the exact blocks needed to remove the listeners.
/// The device list changes when hardware appears or disappears. Selected devices are
/// additionally watched for sample-rate and channel changes, because players and
/// sample-rate switchers reconfigure them while Downmix runs.
final class AudioDeviceMonitor {
  private static let watchedSelectors: [AudioObjectPropertySelector] = [
    kAudioDevicePropertyNominalSampleRate,
    kAudioDevicePropertyStreamConfiguration,
  ]

  private var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
  private var listener: AudioObjectPropertyListenerBlock?
  private var watchedDevices: [AudioDeviceID] = []
  private var watchedListeners: [(device: AudioDeviceID, block: AudioObjectPropertyListenerBlock)] =
    []
  private let onChange: @MainActor @Sendable () -> Void

  init(onChange: @escaping @MainActor @Sendable () -> Void) {
    self.onChange = onChange
    let block: AudioObjectPropertyListenerBlock = { [onChange] _, _ in
      Task { @MainActor in onChange() }
    }
    if AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, .main, block
    ) == noErr {
      listener = block
    }
  }

  /// Main thread only. Re-registers listeners only when the selection changes, so a
  /// rate-change refresh cannot churn its own listeners.
  func watch(devices: [AudioDeviceID]) {
    let selection = Array(Set(devices.filter { $0 != kAudioObjectUnknown })).sorted()
    guard selection != watchedDevices else { return }
    removeWatchedListeners()
    watchedDevices = selection
    for device in selection {
      for selector in Self.watchedSelectors {
        var address = AudioObjectPropertyAddress(
          mSelector: selector,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [onChange] _, _ in
          Task { @MainActor in onChange() }
        }
        if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
          watchedListeners.append((device, block))
        }
      }
    }
  }

  private func removeWatchedListeners() {
    for entry in watchedListeners {
      for selector in Self.watchedSelectors {
        var address = AudioObjectPropertyAddress(
          mSelector: selector,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(entry.device, &address, .main, entry.block)
      }
    }
    watchedListeners.removeAll()
    watchedDevices = []
  }

  deinit {
    if let listener {
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
      )
    }
    removeWatchedListeners()
  }
}
