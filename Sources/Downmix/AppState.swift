import AVFoundation
import AppKit
import Foundation
import Observation
import SwiftUI

extension Notification.Name {
  static let downmixMetersDidChange = Notification.Name("com.local.downmix.metersDidChange")
}

final class MeterSource: @unchecked Sendable {
  private let lock = NSLock()
  private var value = MeterSnapshot.empty
  private var valueRevision: UInt64 = 0

  func update(_ snapshot: MeterSnapshot) {
    lock.lock()
    let changed = value != snapshot
    if changed {
      value = snapshot
      valueRevision &+= 1
    }
    lock.unlock()

    if changed {
      NotificationCenter.default.post(name: .downmixMetersDidChange, object: self)
    }
  }

  func snapshot() -> MeterSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func revision() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return valueRevision
  }
}

@MainActor
@Observable
final class AppState {
  var preferences: AppPreferences
  var inputDevices: [AudioDeviceInfo] = []
  var outputDevices: [AudioDeviceInfo] = []
  var selectedInputID: AudioDeviceID?
  var selectedOutputID: AudioDeviceID?
  var status = EngineStatus()
  let meterSource = MeterSource()
  var errorMessage: String?
  var showEQSheet = false
  var showAdvanced = false

  private let engine = AudioEngine()
  private var deviceListenerInstalled = false

  init() {
    preferences = .load()
    engine.setStatusHandler { [weak self] update in
      Task { @MainActor in
        guard let self else { return }
        if self.status.phase != update.phase || self.status.message != update.message {
          self.status.phase = update.phase
          self.status.message = update.message
        }
        self.meterSource.update(update.meters)
      }
    }
    refreshDevices()
    installDeviceListener()
    requestMicAccessIfNeeded()
  }

  var isRunning: Bool {
    status.phase == .running || status.phase == .starting
  }

  var isKeepingOutputAwake: Bool {
    status.phase == .keepAlive
  }

  var selectedLayout: LayoutPreset {
    get { LayoutPreset.named(preferences.layoutPresetName) }
    set {
      preferences.layoutPresetName = newValue.name
      persist()
    }
  }

  func refreshDevices() {
    inputDevices = DeviceManager.inputDevices()
    outputDevices = DeviceManager.outputDevices()

    if let preferred = DeviceManager.preferredInput(
      matchingName: preferences.inputDeviceName,
      uid: preferences.inputDeviceUID.isEmpty ? nil : preferences.inputDeviceUID
    ) {
      selectedInputID = preferred.id
      preferences.inputDeviceUID = preferred.uid
      preferences.inputDeviceName = preferred.name
    }

    if let preferred = DeviceManager.preferredOutput(
      matchingName: preferences.outputDeviceName,
      uid: preferences.outputDeviceUID.isEmpty ? nil : preferences.outputDeviceUID
    ) {
      selectedOutputID = preferred.id
      preferences.outputDeviceUID = preferred.uid
      preferences.outputDeviceName = preferred.name
    }
  }

  func selectInput(_ device: AudioDeviceInfo) {
    selectedInputID = device.id
    preferences.inputDeviceUID = device.uid
    preferences.inputDeviceName = device.name
    persist()
  }

  func selectOutput(_ device: AudioDeviceInfo) {
    selectedOutputID = device.id
    preferences.outputDeviceUID = device.uid
    preferences.outputDeviceName = device.name
    persist()
    if preferences.keepOutputAlive, !isRunning {
      startKeepAliveIfNeeded()
    }
  }

  func persist() {
    preferences.save()
    if isRunning {
      engine.updateConfiguration(makeConfiguration())
    }
  }

  func toggle() {
    if isRunning {
      stop()
    } else {
      start()
    }
  }

  func start() {
    errorMessage = nil
    guard let inputID = selectedInputID, let outputID = selectedOutputID else {
      errorMessage = "Select both an input device and an output device."
      return
    }
    guard let input = inputDevices.first(where: { $0.id == inputID }) else {
      errorMessage = "Selected input is unavailable."
      return
    }
    guard input.inputChannelCount >= 16 else {
      errorMessage = "Input must expose at least 16 channels (BlackHole 16ch configured as 9.1.6)."
      return
    }

    do {
      try engine.start(
        inputDeviceID: inputID,
        outputDeviceID: outputID,
        configuration: makeConfiguration(inputChannels: input.inputChannelCount),
        framesPerBuffer: preferences.framesPerBuffer,
        keepAliveOnly: false
      )
    } catch {
      errorMessage = error.localizedDescription
      status = EngineStatus(phase: .error, message: error.localizedDescription, meters: .empty)
    }
  }

  func stop() {
    engine.stop()
    if preferences.keepOutputAlive {
      startKeepAliveIfNeeded()
    }
  }

  func startKeepAliveIfNeeded() {
    guard preferences.keepOutputAlive, let outputID = selectedOutputID else { return }
    guard !isRunning else { return }
    do {
      try engine.start(
        inputDeviceID: outputID,
        outputDeviceID: outputID,
        configuration: makeConfiguration(),
        framesPerBuffer: preferences.framesPerBuffer,
        keepAliveOnly: true
      )
    } catch {
      // Keep-alive is best-effort.
      errorMessage = "Keep-alive failed: \(error.localizedDescription)"
    }
  }

  private func makeConfiguration(inputChannels: Int = 16) -> DownmixProcessor.Configuration {
    var config = DownmixProcessor.Configuration()
    config.channelMap = selectedLayout.map
    config.preampDb = preferences.preampDb
    config.lfeLowpass = preferences.lfeLowpass
    config.swapOutputs = preferences.swapOutputs
    config.globalPEQText = preferences.globalPEQText
    config.speakerPEQText = preferences.speakerPEQText
    config.inputChannelCount = inputChannels
    return config
  }

  private func requestMicAccessIfNeeded() {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized, .restricted, .denied:
      break
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { _ in }
    @unknown default:
      break
    }
  }

  private func installDeviceListener() {
    guard !deviceListenerInstalled else { return }
    deviceListenerInstalled = true
    // Lightweight: refresh when app becomes active rather than continuous polling.
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.refreshDevices()
      }
    }
  }
}
