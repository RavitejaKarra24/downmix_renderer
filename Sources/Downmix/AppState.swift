import AVFoundation
import AppKit
import Foundation
import Observation
import SwiftUI

extension Notification.Name {
  static let downmixMetersDidChange = Notification.Name("com.local.downmix.metersDidChange")
}

extension AVAuthorizationStatus {
  /// Stable text for the diagnostic log.
  var diagnosticName: String {
    switch self {
    case .authorized: "authorized"
    case .denied: "denied"
    case .restricted: "restricted"
    case .notDetermined: "notDetermined"
    @unknown default: "unknown"
    }
  }
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
    case musicRate
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
  @ObservationIgnored private let log: any DiagnosticLogging
  @ObservationIgnored private let musicRateMonitor: (any MusicRateMonitoring)?
  @ObservationIgnored private var isMonitoringMusicRate = false
  @ObservationIgnored private var lastRequestedMusicRate: Double?
  /// Last rate Music reported for its current track, for the checklist and log.
  private(set) var detectedMusicRate: Double?
  private(set) var musicRateFailure: MusicRateFailure?
  @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
  @ObservationIgnored private var lastLoggedDevices: String?
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
    installListeners: Bool = true,
    log: any DiagnosticLogging = DownmixLog.shared,
    musicRateMonitor: (any MusicRateMonitoring)? = nil
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
    self.log = log
    self.musicRateMonitor = musicRateMonitor
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
    let inputChannels = input?.inputChannelCount ?? 0
    let inputReady = inputChannels >= 16
    let rateSupported =
      input.map { InputRateConverter.supportedDeviceRates.contains($0.nominalSampleRate) } ?? false
    let outputRateSupported =
      output.map { $0.nominalSampleRate.isFinite && $0.nominalSampleRate > 0 } ?? false
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
          guidance: input.map { device in
            inputReady
              ? "\(device.name) exposes \(device.inputChannelCount) input channels."
              : "\(device.name) exposes \(device.inputChannelCount) channels, so only that many bed slots are fed. BlackHole 16ch gives the full 9.1.6 bed."
          } ?? "Select or reconnect a multichannel input such as BlackHole 16ch."),
        SetupCheck(
          id: .inputRate, title: "Input format",
          status: rateSupported ? .verified : .needsAttention,
          guidance: input.map { device in
            rateSupported
              ? Self.inputRateGuidance(
                deviceRate: device.nominalSampleRate, renderRate: status.renderSampleRate)
              : "\(Self.rateText(device.nominalSampleRate)) is outside the supported 8–768 kHz band."
          } ?? "Select an input to read its sample rate."),
        SetupCheck(
          id: .outputRate, title: "Output format",
          status: outputRateSupported ? .verified : .needsAttention,
          guidance: output.map { device in
            guard outputRateSupported else {
              return "The selected output reports no usable sample rate."
            }
            let deviceText = Self.rateText(device.nominalSampleRate)
            guard let render = status.renderSampleRate else {
              return "\(deviceText): the stereo mix follows this rate while rendering."
            }
            return "\(deviceText): the stereo mix renders at \(Self.rateText(render))."
          } ?? "Select an output to read its sample rate."),
        musicRateSetupCheck(input: input),
        SetupCheck(
          id: .output, title: "Safe stereo output",
          status: outputReady ? .verified : .needsAttention,
          guidance: outputReady
            ? "Selected output has at least two channels and passes route safety checks."
            : "Select or reconnect a stereo output. Avoid BlackHole and aggregates containing the input."
        ),
        permissionCheck,
        speakerMappingCheck(isRunning ? status.bedLayoutInstalled : nil),
        SetupCheck(
          id: .systemOutput, title: "Playback routed to input", status: .manual,
          guidance:
            "Manually route your player or Mac sound output to the selected multichannel input. Downmix does not change or certify the system output route."
        ),
      ],
      canRequestPermission: authorization == .notDetermined
    )
  }

  /// Players read the input's device layout to choose their output channel count. This
  /// reports the layout installed for the live run, never a prompt-free manual claim.
  private func speakerMappingCheck(_ installed: Bool?) -> SetupCheck {
    switch installed {
    case .some(true):
      return SetupCheck(
        id: .speakerMapping, title: "9.1.6 speaker mapping", status: .verified,
        guidance:
          "The input advertises the 9.1.6 bed layout. Reopen a file that was already playing so the player re-negotiates every channel."
      )
    case .some(false):
      return SetupCheck(
        id: .speakerMapping, title: "9.1.6 speaker mapping", status: .needsAttention,
        guidance:
          "Downmix could not set the input's 9.1.6 bed layout. Set it in Audio MIDI Setup → Configure Speakers, then start again."
      )
    case .none:
      return SetupCheck(
        id: .speakerMapping, title: "9.1.6 speaker mapping", status: .manual,
        guidance:
          "Downmix installs the 9.1.6 bed layout on the input when rendering starts, so players deliver every bed channel instead of stereo."
      )
    }
  }

  /// Reports whether the input device is following Music's current track rate. This is
  /// opt-in: matching changes a system audio setting, so the app never hides it.
  private func musicRateSetupCheck(input: AudioDeviceInfo?) -> SetupCheck {
    let title = "Music rate matching"
    guard preferences.matchMusicSampleRate else {
      return SetupCheck(
        id: .musicRate, title: title, status: .manual,
        guidance:
          "Off. The input keeps the rate you set in Audio MIDI Setup; turn matching on to follow Music's track rate."
      )
    }
    if musicRateFailure == .automationDenied {
      return SetupCheck(
        id: .musicRate, title: title, status: .needsAttention,
        guidance:
          "Allow Downmix to control Music in System Settings → Privacy & Security → Automation, then start again."
      )
    }
    if case .scriptFailed(let code) = musicRateFailure {
      return SetupCheck(
        id: .musicRate, title: title, status: .manual,
        guidance:
          "Music did not report a rate for this track (AppleScript error \(code)). Files opened outside the Music library may not expose one; set the device rate in Audio MIDI Setup."
      )
    }
    guard let rate = detectedMusicRate else {
      return SetupCheck(
        id: .musicRate, title: title, status: .manual,
        guidance:
          "Play something in Music. Downmix matches the selected input to the current track; files opened outside Music may not report a rate."
      )
    }
    guard InputRateConverter.supportedDeviceRates.contains(rate) else {
      return SetupCheck(
        id: .musicRate, title: title, status: .needsAttention,
        guidance:
          "Music reports \(Self.rateText(rate)), outside the supported 8–768 kHz band.")
    }
    guard let input else {
      return SetupCheck(
        id: .musicRate, title: title, status: .manual,
        guidance: "Music reports \(Self.rateText(rate)). Select an input device to match it.")
    }
    if abs(input.nominalSampleRate - rate) <= 0.5 {
      return SetupCheck(
        id: .musicRate, title: title, status: .verified,
        guidance:
          "Music \(Self.rateText(rate)) · input \(Self.rateText(rate)). Downmix renders at the device rate."
      )
    }
    return SetupCheck(
      id: .musicRate, title: title, status: .manual,
      guidance:
        "Music \(Self.rateText(rate)) · input \(Self.rateText(input.nominalSampleRate)). Waiting for the device to switch."
    )
  }

  private static func rateText(_ rate: Double) -> String {
    guard rate.isFinite, rate > 0 else { return "No sample rate" }
    return "\(Int(rate.rounded())) Hz"
  }

  private static func inputRateGuidance(deviceRate: Double, renderRate: Double?) -> String {
    let deviceText = rateText(deviceRate)
    guard let renderRate else {
      return "\(deviceText): the stereo mix renders at this rate when the output supports it."
    }
    if abs(renderRate - deviceRate) <= 0.5 {
      return "\(deviceText) in, rendered at \(Self.rateText(renderRate)) with no conversion."
    }
    return
      "\(rateText(deviceRate)): the output device cannot accept it, so the mix renders at \(rateText(renderRate))."
  }

  /// Logs the saved configuration once at launch, before any device is opened.
  func logStartupSummary() {
    let system = ProcessInfo.processInfo.operatingSystemVersionString
    let authorization = permissionStatusProvider()
    log.log(
      .info, "startup",
      "macOS=\(system) permission=\(authorization.diagnosticName)"
        + " savedInput=\(preferences.inputDeviceName.isEmpty ? "-" : preferences.inputDeviceName)"
        + " savedOutput=\(preferences.outputDeviceName.isEmpty ? "-" : preferences.outputDeviceName)"
        + " layout=\(preferences.layoutPresetName) preampDb=\(preferences.preampDb)"
        + " frames=\(preferences.framesPerBuffer) keepAlive=\(preferences.keepOutputAlive)"
        + " autoStart=\(preferences.autoStart)")
  }

  private func logSelectedDevicesIfChanged(_ snapshot: DeviceCatalogSnapshot) {
    let input = snapshot.devices.first { $0.id == selectedInputID }
    let output = snapshot.devices.first { $0.id == selectedOutputID }
    let summary =
      "input=\(Self.deviceSummary(input)) output=\(Self.deviceSummary(output))"
    guard summary != lastLoggedDevices else { return }
    lastLoggedDevices = summary
    log.log(.info, "devices", "selected \(summary)")
  }

  private static func deviceSummary(_ device: AudioDeviceInfo?) -> String {
    guard let device else { return "none" }
    let rate = Int(device.nominalSampleRate.rounded())
    return "\(device.name)[\(device.id) \(device.inputChannelCount)in/"
      + "\(device.outputChannelCount)out \(rate)Hz]"
  }

  /// Starts/stops Music rate polling with the renderer and the preference. Safe to call
  /// on every status publication: the monitor ignores a redundant start.
  private func syncMusicRateMonitoring() {
    let shouldMonitor = preferences.matchMusicSampleRate && isRunning && !isKeepingOutputAwake
    guard shouldMonitor != isMonitoringMusicRate else { return }
    isMonitoringMusicRate = shouldMonitor
    guard shouldMonitor else {
      musicRateMonitor?.stop()
      detectedMusicRate = nil
      musicRateFailure = nil
      lastRequestedMusicRate = nil
      return
    }
    musicRateMonitor?.start { [weak self] observation in
      MainActor.assumeIsolated { self?.receiveMusicRate(observation) }
    }
  }

  private func receiveMusicRate(_ observation: MusicRateObservation) {
    switch observation {
    case .playing(let rate, let track):
      if detectedMusicRate != rate {
        log.log(
          .info, "music",
          "track=\(track.isEmpty ? "-" : track) reportedRate=\(Int(rate.rounded()))Hz")
      }
      detectedMusicRate = rate
      musicRateFailure = nil
      applyDetectedMusicRate(rate)
    case .idle:
      if detectedMusicRate != nil {
        log.log(.info, "music", "Music is not playing; leaving the input rate unchanged")
      }
      detectedMusicRate = nil
      musicRateFailure = nil
      lastRequestedMusicRate = nil
    case .failure(let failure):
      if musicRateFailure != failure {
        log.log(.warning, "music", "rate reading failed: \(Self.describe(failure))")
      }
      musicRateFailure = failure
    }
  }

  /// Requests the running input device's rate. The worker reopens the pipeline when the
  /// HAL applies it; the output device follows the source rate.
  private func applyDetectedMusicRate(_ rate: Double) {
    guard preferences.matchMusicSampleRate, status.phase == .running,
      let input = inputDevices.first(where: { $0.id == selectedInputID })
    else { return }
    guard InputRateConverter.supportedDeviceRates.contains(rate) else { return }
    if abs(input.nominalSampleRate - rate) <= 0.5 {
      lastRequestedMusicRate = nil
      return
    }
    guard lastRequestedMusicRate != rate else { return }
    lastRequestedMusicRate = rate
    engine.setInputSampleRate(rate)
    log.log(
      .info, "music",
      "requested input=\(Self.deviceSummary(input)) rate=\(Int(rate.rounded()))Hz")
  }

  private static func describe(_ failure: MusicRateFailure) -> String {
    switch failure {
    case .musicNotRunning: "Music is not running"
    case .automationDenied: "Automation permission to control Music was denied"
    case .scriptFailed(let code): "AppleScript error \(code)"
    }
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

    logSelectedDevicesIfChanged(snapshot)
    deviceMonitor?.watch(devices: [selectedInputID, selectedOutputID].compactMap { $0 })

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
    lastRequestedMusicRate = nil
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
    syncMusicRateMonitoring()
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
    // The bed is 16 channels wide, but a narrower device still renders the slots it has.
    // Rate is not a precondition: the engine follows the device rate and converts it.
    guard input.inputChannelCount >= 2 else {
      failAndStop(
        "Input must expose at least two channels. Select BlackHole 16ch (or a wider interface) and retry."
      )
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
    let previousPhase = status.phase
    let previousMessage = status.message
    defer { logTransition(previousPhase: previousPhase, previousMessage: previousMessage) }
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
    // Run-scoped certificates and the live input format belong to the worker's run and
    // drive the checklist/log. Assign only on change: a diagnostics-only publication
    // must not invalidate the observed transport status every UI tick.
    if status.bedLayoutInstalled != update.bedLayoutInstalled {
      status.bedLayoutInstalled = update.bedLayoutInstalled
    }
    if status.inputSampleRate != update.inputSampleRate {
      status.inputSampleRate = update.inputSampleRate
    }
    if status.inputChannelCount != update.inputChannelCount {
      status.inputChannelCount = update.inputChannelCount
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
    syncMusicRateMonitoring()
    if let rate = detectedMusicRate, status.phase == .running {
      applyDetectedMusicRate(rate)
    }
  }

  /// One log line per visible status transition, plus full failure counters.
  private func logTransition(previousPhase: EnginePhase, previousMessage: String) {
    guard status.phase != previousPhase || status.message != previousMessage else { return }
    switch status.phase {
    case .error:
      heartbeatTask?.cancel()
      heartbeatTask = nil
      log.logFailure(
        status.message,
        context:
          "run failed input=\(Self.deviceSummary(inputDevices.first { $0.id == selectedInputID }))"
          + " output=\(Self.deviceSummary(outputDevices.first { $0.id == selectedOutputID }))",
        diagnostics: diagnostics)
    case .running, .keepAlive:
      heartbeatTask?.cancel()
      heartbeatTask = Task { [weak self] in await self?.logHeartbeats() }
      log.log(
        .info, "engine",
        "phase=\(status.phase.rawValue) message=\(status.message)"
          + " inputRate=\(status.inputSampleRate.map { String(Int($0.rounded())) } ?? "-")"
          + " inputChannels=\(status.inputChannelCount.map(String.init) ?? "-")")
    case .stopped, .starting:
      if status.phase == .stopped {
        heartbeatTask?.cancel()
        heartbeatTask = nil
      }
      log.log(.info, "engine", "phase=\(status.phase.rawValue) message=\(status.message)")
    case .stopping:
      log.log(.info, "engine", "phase=stopping message=\(status.message)")
    }
  }

  /// A slow heartbeat means an abrupt stop still shows what the app was doing.
  private func logHeartbeats() async {
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: .seconds(20))
      } catch { return }
      guard isRunning || isKeepingOutputAwake else { return }
      log.log(
        .info, "heartbeat",
        "phase=\(status.phase.rawValue) input=\(Self.deviceSummary(inputDevices.first { $0.id == selectedInputID }))"
          + " output=\(Self.deviceSummary(outputDevices.first { $0.id == selectedOutputID }))"
          + " diagnostics=\(Self.diagnosticsSummary(diagnostics))")
    }
  }

  private static func diagnosticsSummary(_ diagnostics: EngineDiagnostics) -> String {
    "buffers=\(diagnostics.requestedBufferFrames)/\(diagnostics.inputBufferFrames)/\(diagnostics.outputBufferFrames)"
      + " underruns=\(diagnostics.underrunCount) overruns=\(diagnostics.overrunCount)"
      + " rejected=\(diagnostics.rejectedSliceCount) renderErrors=\(diagnostics.renderErrorCount)"
      + " queued=\(diagnostics.queuedFrames) ppm=\(diagnostics.correctionPPM)"
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
    syncMusicRateMonitoring()
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
      log.log(.warning, "preferences", "save failed: \(error.localizedDescription)")
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
            self.log.log(.info, "lifecycle", "application terminating")
            self.heartbeatTask?.cancel()
            self.flushPreferences()
            self.stopRenderer()
            DownmixLog.shared.endSession()
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
    heartbeatTask?.cancel()
  }
}
