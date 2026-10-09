import CoreAudio
import Foundation

/// Event-driven discovery; retains the exact block needed to remove the listener.
final class AudioDeviceMonitor {
  private var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
  private var listener: AudioObjectPropertyListenerBlock?

  init(onChange: @escaping @MainActor @Sendable () -> Void) {
    let block: AudioObjectPropertyListenerBlock = { _, _ in
      Task { @MainActor in onChange() }
    }
    if AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, .main, block
    ) == noErr {
      listener = block
    }
  }

  deinit {
    if let listener {
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
      )
    }
  }
}
