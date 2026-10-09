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
  private var resetGeneration: UInt64 = 0

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

  /// Explicit transport reset, distinct from ordinary running silence. Native meters
  /// can use resetRevision() to clear retained peak holds and decay immediately.
  func reset() {
    lock.lock()
    value = .empty
    valueRevision &+= 1
    resetGeneration &+= 1
    lock.unlock()
    NotificationCenter.default.post(name: .downmixMetersDidChange, object: self)
  }

  func resetRevision() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return resetGeneration
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

/// NotificationCenter supports removing a token from any thread. Owning the token
/// separately keeps cleanup out of AppState's nonisolated deinit, without unsafe casts.
private final class NotificationObservation {
  private let token: NSObjectProtocol

  init(_ token: NSObjectProtocol) {
    self.token = token
  }

  deinit {
    NotificationCenter.default.removeObserver(token)
  }
}

struct SetupCheck: Identifiable, Equatable {
  enum ID: String {
    case input, inputRate, outputRate, output, authorization, speakerMapping, systemOutput
  }

  enum Status: String {
    case verified = "Verified"
    case needsAttention = "Needs attention"
    case permissionRequired = "Permission required"
    case manual = "Manual check"
  }

  let id: ID
  let title: String
  let status: Status
  let guidance: String
}

struct SetupChecklist: Equatable {
  let checks: [SetupCheck]
  let canRequestPermission: Bool
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
  private(set) var diagnostics = EngineDiagnostics.empty
  let meterSource = MeterSource()
  var errorMessage: String?
  private(set) var persistenceErrorMessage: String?
  var showAdvanced = false
  private var setupCheckRevision: UInt64 = 0

  @ObservationIgnored private let engine: any AudioEngineControlling
  @ObservationIgnored private let deviceCatalog: (() -> [AudioDeviceInfo])?
  @ObservationIgnored private let catalogProvider: DeviceCatalogProvider?
  @ObservationIgnored private var catalogSnapshot: DeviceCatalogSnapshot?
  @ObservationIgnored private var hasInitialCatalog = false
  @ObservationIgnored private var automaticStartRequested = false
  private enum CatalogIntent { case renderer, keepAlive, retry }
  @ObservationIgnored private var catalogIntent: CatalogIntent?
  @ObservationIgnored private let permissionStatusProvider: () -> AVAuthorizationStatus
  @ObservationIgnored private let permissionRequestProvider:
    (@escaping @Sendable (Bool) -> Void) -> Void
  @ObservationIgnored private let routeSafetyProvider: ((AudioDeviceInfo, String) -> Bool)?
  @ObservationIgnored private let preferenceWriter: (AppPreferences) throws -> Void
  @ObservationIgnored private var deviceMonitor: AudioDeviceMonitor?
  @ObservationIgnored private var notificationObservers: [NotificationObservation] = []
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private var permissionRequestID: UUID?
  @ObservationIgnored private var didHandleAutomaticStart = false
  @ObservationIgnored private var activeInputID: AudioDeviceID?
  @ObservationIgnored private var activeOutputID: AudioDeviceID?
  @ObservationIgnored private var activeFramesPerBuffer: Int?
  private var pendingKeepAlive = false

  init(
    engine: any AudioEngineControlling = AsyncAudioEngineController(),
    preferences: AppPreferences = .load(),
    deviceCatalog: (() -> [AudioDeviceInfo])? = nil,
    catalogProvider: DeviceCatalogProvider? = nil,
    permissionStatusProvider: @escaping () -> AVAuthorizationStatus = {
      AVCaptureDevice.authorizationStatus(for: .audio)
    },
    permissionRequestProvider: @escaping (@escaping @Sendable (Bool) -> Void) -> Void = {
      AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0)
    },
    routeSafetyProvider: ((AudioDeviceInfo, String) -> Bool)? = nil,
    preferenceWriter: @escaping (AppPreferences) throws -> Void = { try $0.save() },
    installListeners: Bool = true
  ) {
    self.engine = engine
    self.preferences = preferences
    // Explicit legacy fake closures retain synchronous behavior. The production
    // defaults always go through the serial immutable-snapshot bridge.
    self.deviceCatalog = deviceCatalog
    self.catalogProvider =
      deviceCatalog == nil
      ? (catalogProvider ?? (engine as? AsyncAudioEngineController)?.makeDeviceCatalogProvider()
        ?? DeviceCatalogProvider()) : nil
    self.permissionStatusProvider = permissionStatusProvider
    self.permissionRequestProvider = permissionRequestProvider
    self.routeSafetyProvider = routeSafetyProvider
    self.preferenceWriter = preferenceWriter
    engine.setStatusHandler { [weak self] update in
      // The UI bridge delivers logical intents synchronously and generation-filtered
      // worker snapshots on main, never from a render callback.
      MainActor.assumeIsolated {
        self?.receiveStatus(update)
      }
    }
    (engine as? any AudioFailureDiagnosticsControlling)?.setFinalDiagnosticsHandler {
      [weak self] final in
      self?.receiveFinalDiagnostics(final)
    }
    refreshDevices()
    if installListeners { self.installListeners() }
  }

  var isRunning: Bool {
    status.phase == .running || (status.phase == .starting && !pendingKeepAlive)
  }

  var isKeepingOutputAwake: Bool {
    status.phase == .keepAlive || (status.phase == .starting && pendingKeepAlive)
  }

  var selectedLayout: LayoutPreset {
    get { LayoutPreset.named(preferences.layoutPresetName) }
    set {
      preferences.layoutPresetName = newValue.name
      persist()
    }
  }

  /// Read-only checks of the selected route; never opens hardware or requests permission.
  var setupChecklist: SetupChecklist {
    // Authorization is external state. Explicit refresh/app activation rechecks it even
    // when the device catalog and selections have not changed.
    _ = setupCheckRevision
    let input = inputDevices.first { $0.id == selectedInputID }
    let output = outputDevices.first { $0.id == selectedOutputID }
    let authorization = permissionStatusProvider()
    let inputReady = (input?.inputChannelCount ?? 0) >= 16
    let outputReady =
      output.map {
        $0.outputChannelCount >= 2
          && cachedRouteSafety($0, input?.uid ?? preferences.inputDeviceUID)
      } ?? false
    let permissionCheck: SetupCheck
    switch authorization {
    case .authorized:
      permissionCheck = SetupCheck(
        id: .authorization, title: "Microphone access", status: .verified,
        guidance: "Downmix is allowed to receive input audio.")
    case .notDetermined:
      permissionCheck = SetupCheck(
        id: .authorization, title: "Microphone access", status: .permissionRequired,
        guidance: "Start to request access. No permission is requested until you choose Start.")
    case .denied, .restricted:
      permissionCheck = SetupCheck(
        id: .authorization, title: "Microphone access", status: .needsAttention,
        guidance: "Allow Downmix in System Settings → Privacy & Security → Microphone, then retry.")
    @unknown default:
      permissionCheck = SetupCheck(
        id: .authorization, title: "Microphone access", status: .needsAttention,
        guidance: "Check microphone access in System Settings, then retry.")
    }

    return SetupChecklist(
      checks: [
        SetupCheck(
          id: .input, title: "16-channel input",
          status: inputReady ? .verified : .needsAttention,
          guidance: inputReady
            ? input.map { "\($0.name) exposes \($0.inputChannelCount) input channels." } ?? ""
            : "Select or reconnect a 16-channel input such as BlackHole 16ch."),
        SetupCheck(
          id: .inputRate, title: "Input at 48 kHz",
          status: input?.nominalSampleRate == 48_000 ? .verified : .needsAttention,
          guidance: input?.nominalSampleRate == 48_000
            ? "Selected input reports 48,000 Hz."
            : "Select an input and set its format to 48,000 Hz in Audio MIDI Setup."),
        SetupCheck(
          id: .outputRate, title: "Output at 48 kHz",
          status: output?.nominalSampleRate == 48_000 ? .verified : .needsAttention,
          guidance: output?.nominalSampleRate == 48_000
            ? "Selected output reports 48,000 Hz."
            : "Select an output and set its format to 48,000 Hz in Audio MIDI Setup."),
        SetupCheck(
          id: .output, title: "Safe stereo output",
          status: outputReady ? .verified : .needsAttention,
          guidance: outputReady
            ? "Selected output has at least two channels and passes route safety checks."
            : "Select or reconnect a stereo output. Avoid BlackHole and aggregates containing the input."
        ),
        permissionCheck,
        SetupCheck(
          id: .speakerMapping, title: "9.1.6 speaker mapping", status: .manual,
          guidance:
            "In Audio MIDI Setup, configure the input speakers as 9.1.6 and verify channel order against the selected bed layout. Downmix cannot verify this automatically."
        ),
        SetupCheck(
          id: .systemOutput, title: "Playback routed to input", status: .manual,
          guidance:
            "Manually route your player or Mac sound output to the selected multichannel input. Downmix does not change or certify the system output route."
        ),
      ],
      canRequestPermission: authorization == .notDetermined
    )
  }

  func refreshDevices() {
    setupCheckRevision &+= 1
    if let deviceCatalog {
      let snapshot = DeviceCatalogSnapshot.capture(
        inputUID: preferences.inputDeviceUID, catalog: deviceCatalog,
        routeSafety: routeSafetyProvider ?? DeviceManager.isSafeOutputRoute)
      applyCatalog(snapshot)
    } else {
      catalogProvider?.refresh(inputUID: preferences.inputDeviceUID) { [weak self] snapshot in
        self?.applyCatalog(snapshot)
      }
    }
  }

  private func cachedRouteSafety(_ output: AudioDeviceInfo, _ inputUID: String) -> Bool {
    catalogSnapshot?.isSafeOutput(output, inputUID: inputUID) ?? false
  }

  private func routeIsSafe(_ output: AudioDeviceInfo, _ inputUID: String) -> Bool {
    // Synchronous injected fakes may change between commands; production reads cache.
    routeSafetyProvider?(output, inputUID) ?? cachedRouteSafety(output, inputUID)
  }

  private func applyCatalog(_ snapshot: DeviceCatalogSnapshot) {
    catalogSnapshot = snapshot
    hasInitialCatalog = true
    setupCheckRevision &+= 1
    let devices = snapshot.devices
    inputDevices = devices.filter(\.isInputCapable)
    outputDevices = devices.filter(\.isOutputCapable)
    selectedInputID =
      DeviceManager.preferredInput(
        matchingName: preferences.inputDeviceName,
        uid: preferences.inputDeviceUID.isEmpty ? nil : preferences.inputDeviceUID,
        devices: devices
      )?.id
    selectedOutputID =
      DeviceManager.preferredOutput(
        matchingName: preferences.outputDeviceName,
        uid: preferences.outputDeviceUID.isEmpty ? nil : preferences.outputDeviceUID,
        devices: devices,
        routeSafety: cachedRouteSafety
      )?.id

    // Capture initial defaults, but never erase a missing saved device's identity.
    if preferences.inputDeviceUID.isEmpty,
      let device = inputDevices.first(where: { $0.id == selectedInputID })
    {
      preferences.inputDeviceUID = device.uid
      preferences.inputDeviceName = device.name
    }
    if preferences.outputDeviceUID.isEmpty,
      let device = outputDevices.first(where: { $0.id == selectedOutputID })
    {
      preferences.outputDeviceUID = device.uid
      preferences.outputDeviceName = device.name
    }

    // While authorization is pending there is no active route to compare. An unrelated
    // hotplug event must not cancel the user's permission request.
    if permissionRequestID != nil {
      if selectedInputID == nil || selectedOutputID == nil {
        failAndStop("A selected audio device disconnected while waiting for permission.")
      }
      return
    }
    if catalogIntent == nil,
      (isRunning && activeInputID != selectedInputID)
        || ((isRunning || isKeepingOutputAwake) && activeOutputID != selectedOutputID)
    {
      failAndStop("A selected audio device disconnected. Reconnect it or choose another device.")
      return
    }
    if let intent = catalogIntent {
      catalogIntent = nil
      // Catalog waiting is logical intent, not an opened audio run.
      receiveStatus(EngineStatus(), isExplicitStop: true)
      switch intent {
      case .renderer: start()
      case .keepAlive: startKeepAliveIfNeeded()
      case .retry: startSavedRouteFromCatalog()
      }
    } else if automaticStartRequested {
      startAutomaticallyIfNeeded()
    }
  }

  func selectInput(_ device: AudioDeviceInfo) {
    guard device.id != selectedInputID || device.uid != preferences.inputDeviceUID else { return }
    let restart = isRunning
    if restart { stopRenderer() }
    selectedInputID = device.id
    preferences.inputDeviceUID = device.uid
    preferences.inputDeviceName = device.name
    persist()
    if restart { start() }
  }

  func selectOutput(_ device: AudioDeviceInfo) {
    guard device.id != selectedOutputID || device.uid != preferences.outputDeviceUID else { return }
    let restart = isRunning
    if restart || isKeepingOutputAwake { stopRenderer() }
    selectedOutputID = device.id
    preferences.outputDeviceUID = device.uid
    preferences.outputDeviceName = device.name
    persist()
    if restart {
      start()
    } else {
      startKeepAliveIfNeeded()
    }
  }

  func persist() {
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(250))
      } catch { return }
      guard !Task.isCancelled else { return }
      self?.savePreferencesNow()
    }
    // A catalog-waiting command has no opened route yet. Preferences still save,
    // and its eventual start reads the latest values; never bypass the pending rescan.
    guard catalogIntent == nil else { return }
    if isRunning, permissionRequestID == nil {
      if activeFramesPerBuffer != preferences.framesPerBuffer {
        stopRenderer()
        start()
      } else {
        engine.updateConfiguration(makeConfiguration())
      }
    } else if isKeepingOutputAwake, activeFramesPerBuffer != preferences.framesPerBuffer {
      stopRenderer()
      startKeepAliveIfNeeded()
    }
  }

  func toggle() {
    if isRunning { stop() } else { start() }
  }

  func startAutomaticallyIfNeeded() {
    guard !didHandleAutomaticStart else { return }
    automaticStartRequested = true
    guard hasInitialCatalog else { return }
    automaticStartRequested = false
    didHandleAutomaticStart = true
    if preferences.autoStart { start() } else { startKeepAliveIfNeeded() }
  }

  var canRetrySavedRoute: Bool {
    permissionRequestID == nil
      && (status.phase == .stopped || status.phase == .error || status.phase == .keepAlive)
  }

  /// An explicit recovery attempt uses saved identities, never another available device.
  func retrySavedRoute() {
    guard canRetrySavedRoute else { return }
    if catalogProvider != nil {
      // Retire an existing output-only run before the asynchronous rescan so its
      // periodic statuses cannot replace the newer renderer/retry intent.
      stopRenderer()
      catalogIntent = .retry
      pendingKeepAlive = false
      receiveStatus(EngineStatus(phase: .starting, message: "Checking saved audio route…"))
      refreshDevices()
      return
    }
    refreshDevices()
    startSavedRouteFromCatalog()
  }

  private func startSavedRouteFromCatalog() {
    let inputUID = preferences.inputDeviceUID
    let outputUID = preferences.outputDeviceUID
    guard !inputUID.isEmpty, !outputUID.isEmpty,
      let input = inputDevices.first(where: { $0.uid == inputUID }),
      let output = outputDevices.first(where: { $0.uid == outputUID })
    else {
      failAndStop(
        "The saved audio route is unavailable. Reconnect the saved devices or choose new devices.")
      return
    }
    selectedInputID = input.id
    selectedOutputID = output.id
    start()
  }

  func promptStart() {
    start()
  }

  func start() {
    guard !isRunning, permissionRequestID == nil, status.phase != .stopping else { return }
    // Even preflight errors belong to this new command, not an old cleanup run.
    (engine as? any AudioFailureDiagnosticsControlling)?.invalidateFailureDiagnostics()
    automaticStartRequested = false
    didHandleAutomaticStart = true
    errorMessage = nil
    if !hasInitialCatalog {
      catalogIntent = .renderer
      pendingKeepAlive = false
      receiveStatus(EngineStatus(phase: .starting, message: "Checking audio devices…"))
      return
    }
    catalogIntent = nil
    guard let inputID = selectedInputID, let outputID = selectedOutputID else {
      failAndStop(
        "Select both an input device and an output device. A saved device may be disconnected.")
      return
    }
    guard let input = inputDevices.first(where: { $0.id == inputID }),
      let output = outputDevices.first(where: { $0.id == outputID })
    else {
      failAndStop("Selected audio devices are unavailable. Refresh or reconnect them.")
      return
    }
    guard input.inputChannelCount >= 16 else {
      failAndStop("Input must expose at least 16 channels (BlackHole 16ch configured as 9.1.6).")
      return
    }
    guard output.outputChannelCount >= 2 else {
      failAndStop("Output must expose at least two channels for stereo rendering.")
      return
    }
    guard routeIsSafe(output, input.uid) else {
      failAndStop(
        "Output cannot be BlackHole or an aggregate route that contains the Downmix input.")
      return
    }

    switch permissionStatusProvider() {
    case .denied, .restricted:
      failAndStop(
        "Allow Downmix microphone access in System Settings → Privacy & Security → Microphone, then retry."
      )
      return
    case .notDetermined:
      stopRenderer()
      let requestID = UUID()
      permissionRequestID = requestID
      receiveStatus(EngineStatus(phase: .starting, message: "Waiting for microphone permission…"))
      permissionRequestProvider { [weak self] granted in
        Task { @MainActor in
          guard let self, self.permissionRequestID == requestID else { return }
          self.permissionRequestID = nil
          if granted {
            self.receiveStatus(EngineStatus())
            self.start()
          } else {
            self.failAndStop(
              "Microphone access is required to receive BlackHole audio. Enable it in System Settings."
            )
          }
        }
      }
      return
    case .authorized:
      break
    @unknown default:
      failAndStop("Microphone authorization is unavailable. Check System Settings and retry.")
      return
    }

    pendingKeepAlive = false
    do {
      try engine.start(
        inputDeviceID: inputID,
        outputDeviceID: outputID,
        configuration: makeConfiguration(inputChannels: input.inputChannelCount),
        framesPerBuffer: preferences.framesPerBuffer,
        keepAliveOnly: false
      )
      // A synchronous fatal status must not be overwritten with an active route.
      guard status.phase != .error else { return }
      activeInputID = inputID
      activeOutputID = outputID
      activeFramesPerBuffer = preferences.framesPerBuffer
    } catch {
      failAndStop(error.localizedDescription)
    }
  }

  func stop() {
    stopRenderer()
    startKeepAliveIfNeeded()
  }

  func startKeepAliveIfNeeded() {
    guard preferences.keepOutputAlive, !isRunning else { return }
    automaticStartRequested = false
    didHandleAutomaticStart = true
    if !hasInitialCatalog {
      catalogIntent = .keepAlive
      pendingKeepAlive = true
      receiveStatus(EngineStatus(phase: .starting, message: "Checking output device…"))
      return
    }
    guard
      let outputID = selectedOutputID,
      let output = outputDevices.first(where: { $0.id == outputID })
    else { return }
    guard routeIsSafe(output, preferences.inputDeviceUID) else {
      failAndStop("Choose a safe physical output before enabling keep-alive.")
      return
    }
    if isKeepingOutputAwake, activeOutputID == outputID,
      activeFramesPerBuffer == preferences.framesPerBuffer
    {
      return
    }
    // Output-only warmup is not renderer intent and requires no active input route.
    pendingKeepAlive = true
    do {
      try engine.start(
        inputDeviceID: outputID,
        outputDeviceID: outputID,
        configuration: makeConfiguration(),
        framesPerBuffer: preferences.framesPerBuffer,
        keepAliveOnly: true
      )
      guard status.phase != .error else { return }
      activeInputID = nil
      activeOutputID = outputID
      activeFramesPerBuffer = preferences.framesPerBuffer
    } catch {
      failAndStop("Keep-alive failed: \(error.localizedDescription)")
    }
  }

  private func receiveStatus(_ update: EngineStatus, isExplicitStop: Bool = false) {
    // Cleanup is not a new UI intent. A delayed stop acknowledgement must not
    // cancel a newer permission request or erase a locally preserved failure.
    // Explicit Stop clears these intents synchronously in stopRenderer().
    if update.phase == .stopped, !isExplicitStop,
      permissionRequestID != nil || catalogIntent != nil || status.phase == .error
    {
      return
    }
    if update.phase != .starting { pendingKeepAlive = false }
    if status.phase != update.phase || status.message != update.message {
      status.phase = update.phase
      status.message = update.message
    }
    let isInactive = update.phase == .stopped || update.phase == .error
    var nextDiagnostics = update.phase == .stopped ? EngineDiagnostics.empty : update.diagnostics
    // Keep final failure counts available for diagnosis, without suggesting audio is queued
    // or a route remains active after the error. A new start resets the per-run counters.
    if update.phase == .error {
      nextDiagnostics.queuedFrames = 0
      nextDiagnostics.isPriming = false
    }
    if diagnostics != nextDiagnostics {
      diagnostics = nextDiagnostics
    }
    if isInactive { meterSource.reset() } else { meterSource.update(update.meters) }
    if isInactive {
      permissionRequestID = nil
      activeInputID = nil
      activeOutputID = nil
      activeFramesPerBuffer = nil
    }
    if update.phase == .error {
      catalogIntent = nil
      automaticStartRequested = false
      didHandleAutomaticStart = true
      errorMessage = update.message
    }
  }

  private func stopRenderer(preservingFailureDiagnostics: Bool = false) {
    catalogIntent = nil
    automaticStartRequested = false
    didHandleAutomaticStart = true
    pendingKeepAlive = false
    permissionRequestID = nil
    receiveStatus(EngineStatus(), isExplicitStop: true)
    if preservingFailureDiagnostics, let bridge = engine as? any AudioFailureDiagnosticsControlling
    {
      bridge.stopPreservingFailureDiagnostics()
    } else {
      engine.stop()
    }
    activeInputID = nil
    activeOutputID = nil
    activeFramesPerBuffer = nil
  }

  private func failAndStop(_ message: String) {
    // stop() publishes an empty stopped snapshot. Preserve the last observed failure/run
    // counters before cleanup, including the backend's error-publication-plus-throw path.
    var failureDiagnostics = diagnostics
    failureDiagnostics.queuedFrames = 0
    failureDiagnostics.isPriming = false
    stopRenderer(preservingFailureDiagnostics: true)
    receiveStatus(EngineStatus(phase: .error, message: message, diagnostics: failureDiagnostics))
  }

  /// A cleanup snapshot enriches ONLY the current local failure. It cannot replace
  /// its message/phase, cancel permission, publish meters, or revive an active route.
  private func receiveFinalDiagnostics(_ final: EngineDiagnostics) {
    guard status.phase == .error, permissionRequestID == nil, final != .empty else { return }
    var merged = final
    // A queued error and a cleanup read may arrive in either order; cumulative
    // per-run counters never go backwards, even for injectable workers.
    merged.underrunCount = max(diagnostics.underrunCount, final.underrunCount)
    merged.overrunCount = max(diagnostics.overrunCount, final.overrunCount)
    merged.rejectedSliceCount = max(diagnostics.rejectedSliceCount, final.rejectedSliceCount)
    merged.renderErrorCount = max(diagnostics.renderErrorCount, final.renderErrorCount)
    merged.underrunFrames = max(diagnostics.underrunFrames, final.underrunFrames)
    merged.overrunFrames = max(diagnostics.overrunFrames, final.overrunFrames)
    merged.rebufferCount = max(diagnostics.rebufferCount, final.rebufferCount)
    merged.queuedFrames = 0
    merged.isPriming = false
    if diagnostics != merged { diagnostics = merged }
  }

  private func makeConfiguration(inputChannels: Int? = nil) -> DownmixProcessor.Configuration {
    var config = DownmixProcessor.Configuration()
    config.channelMap = selectedLayout.map
    config.preampDb = preferences.preampDb
    config.lfeLowpass = preferences.lfeLowpass
    config.swapOutputs = preferences.swapOutputs
    config.inputChannelCount =
      inputChannels
      ?? inputDevices.first(where: { $0.id == selectedInputID })?.inputChannelCount ?? 16
    return config
  }

  /// Flush pending edits before termination (also usable without notification observers).
  func flushPreferences() {
    saveTask?.cancel()
    saveTask = nil
    savePreferencesNow()
  }

  func retrySavePreferences() {
    flushPreferences()
  }

  func dismissPersistenceError() {
    persistenceErrorMessage = nil
  }

  private func savePreferencesNow() {
    do {
      try preferenceWriter(preferences)
      persistenceErrorMessage = nil
    } catch {
      persistenceErrorMessage = "Could not save settings: \(error.localizedDescription)"
    }
  }

  private func installListeners() {
    deviceMonitor = AudioDeviceMonitor { [weak self] in self?.refreshDevices() }
    for name in [
      NSApplication.didBecomeActiveNotification, NSApplication.willTerminateNotification,
    ] {
      let observer = NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) {
        [weak self] notification in
        let isTerminating = notification.name == NSApplication.willTerminateNotification
        MainActor.assumeIsolated {
          guard let self else { return }
          if isTerminating {
            self.flushPreferences()
            self.stopRenderer()
          } else {
            self.refreshDevices()
          }
        }
      }
      notificationObservers.append(NotificationObservation(observer))
    }
  }

  deinit {
    saveTask?.cancel()
  }
}
