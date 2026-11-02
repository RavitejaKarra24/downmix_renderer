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

/// A running decoder-log monitor and the client/generation it reports for.
private struct DecoderMonitorSlot {
  let source: AudioPlaybackSource
  let monitor: any DecoderRateMonitoring
  let generation: UInt64
}

/// A running open-file monitor and the client/generation it reports for.
private struct SourceFileMonitorSlot {
  let source: AudioPlaybackSource
  let monitor: any SourceFileMonitoring
  let generation: UInt64
}

@MainActor
@Observable
final class AppState {
  /// Each monitor polls unified logs about once a second; bound the total work.
  static let maximumDecoderMonitors = 6
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
  @ObservationIgnored private let audioSourceMonitor: (any AudioSourceMonitoring)?
  @ObservationIgnored private let makeDecoderRateMonitor:
    (@MainActor () -> any DecoderRateMonitoring)?
  /// One decoder-log monitor per routed client: evidence is per client, not exclusive.
  @ObservationIgnored private var decoderMonitors: [Int32: DecoderMonitorSlot] = [:]
  @ObservationIgnored private var decoderObservationGeneration: UInt64 = 0
  private(set) var decoderRates: [Int32: DecoderRateObservation] = [:]
  private var decoderEvidencePIDs: Set<Int32> = []
  @ObservationIgnored private let makeSourceFileMonitor:
    (@MainActor () -> any SourceFileMonitoring)?
  /// One open-file reader per routed client (local players: Kew, Elmedia, VLC…).
  @ObservationIgnored private var sourceFileMonitors: [Int32: SourceFileMonitorSlot] = [:]
  @ObservationIgnored private var sourceFileGeneration: UInt64 = 0
  private(set) var sourceFiles: [Int32: SourceFileObservation] = [:]
  /// Last source bit depth sent to the engine this run (outer nil: nothing sent yet).
  @ObservationIgnored private var sentOutputBitDepth: Int??
  private var musicIsIdle = false
  @ObservationIgnored private let rateMatchDelay: Duration
  @ObservationIgnored private var sourceMonitoringInput: AudioDeviceID?
  @ObservationIgnored private var sourceMonitorGeneration: UInt64 = 0
  @ObservationIgnored private var musicObservationGeneration: UInt64 = 0
  @ObservationIgnored private var rateMatchTask: Task<Void, Never>?
  @ObservationIgnored private var rateRequestGate: AudioRateRequest?
  @ObservationIgnored private var pendingRateDecision: SampleRateDecision?
  private(set) var audioSources = AudioSourceObservation(isAvailable: false)
  @ObservationIgnored private var isMonitoringMusicRate = false
  @ObservationIgnored private var lastRequestedRateDecision: SampleRateDecision?
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
    musicRateMonitor: (any MusicRateMonitoring)? = nil,
    audioSourceMonitor: (any AudioSourceMonitoring)? = nil,
    decoderRateMonitorFactory: (@MainActor () -> any DecoderRateMonitoring)? = nil,
    sourceFileMonitorFactory: (@MainActor () -> any SourceFileMonitoring)? = nil,
    rateMatchDelay: Duration = .milliseconds(1500)
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
    self.audioSourceMonitor = audioSourceMonitor
    self.makeDecoderRateMonitor = decoderRateMonitorFactory
    self.makeSourceFileMonitor = sourceFileMonitorFactory
    self.rateMatchDelay = rateMatchDelay
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
              return
                "\(deviceText): the stereo mix follows this rate while rendering, at the deepest bit depth the device offers."
            }
            let depth = status.outputPhysicalFormat.map { ", \($0.label) at the DAC" } ?? ""
            return "\(deviceText): the stereo mix renders at \(Self.rateText(render))\(depth)."
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
            "For any player, browser, YouTube Music or Spotify: set Mac Sound output (or the app\'s own output) to the selected input, and choose your physical DAC as Downmix output. Downmix never changes the default route. Original file/stream rate may be unavailable."
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

  private var rateDecision: SampleRateDecision {
    SampleRateDecision.resolve(
      preferences: preferences, sources: audioSources,
      musicRate: detectedMusicRate, musicFailure: musicRateFailure,
      decoderRates: decoderRates, decoderEvidencePIDs: decoderEvidencePIDs,
      sourceFiles: sourceFiles,
      musicIsIdle: musicIsIdle)
  }

  var playbackSourceSummary: String {
    guard status.phase == .running else { return "Not monitoring while stopped" }
    guard audioSources.isAvailable else { return "Audio-client discovery unavailable" }
    guard !audioSources.sources.isEmpty else { return "No active client on the selected input" }
    return audioSources.sources.map(\.name).joined(separator: ", ")
  }

  var reportedSourceRateText: String {
    if case .matching(let rate, let evidence) = rateDecision {
      if case .file(let pid, _) = evidence, let format = sourceFiles[pid]?.format {
        return "\(evidence.label): \(format.summary)"
      }
      let depth = sourceBitDepth.map { ", \($0)-bit" } ?? ""
      return "\(evidence.label): \(Self.rateText(rate))\(depth)"
    }
    if case .conflictingRates(let rates) = rateDecision {
      return "Conflicting claims: " + rates.map { Self.rateText($0) }.joined(separator: " / ")
    }
    return "Unknown — nothing claimed a rate"
  }

  var capturedRateText: String {
    guard status.phase == .running, let rate = status.inputSampleRate else {
      return "Not capturing"
    }
    return Self.rateText(rate)
  }

  var renderRateText: String {
    guard status.phase == .running, let rate = status.renderSampleRate else {
      return "Not rendering"
    }
    return Self.rateText(rate)
  }

  var dacRateText: String {
    if status.phase == .running, let format = status.outputPhysicalFormat {
      return "\(Self.rateText(format.sampleRate)), \(format.label)"
    }
    return outputDevices.first { $0.id == selectedOutputID }.map {
      "\(Self.rateText($0.nominalSampleRate)) (device snapshot)"
    } ?? "No selected output"
  }

  var sampleRateSummary: String {
    if preferences.sampleRateMode == .automatic, status.phase != .running {
      return
        "Automatic: source detection starts with the renderer. The input rate is unchanged while stopped."
    }
    switch rateDecision {
    case .followingInput:
      return "Follow input: every routed app is processed at the input device's rate."
    case .fixed(let rate):
      return
        "Fixed \(Self.rateText(rate)); applies while rendering if the input accepts it. The output follows or reports its limit."
    case .matching(let rate, let evidence):
      return
        "Auto: \(evidence.label) claims \(Self.rateText(rate)); applying after a short settling delay."
    case .conflictingRates(let rates):
      return
        "Auto: clients disagree (\(rates.map { Self.rateText($0) }.joined(separator: " vs "))). Holding the current rate instead of picking one."
    case .decoderLogsUnavailable:
      return "Auto: decoder logs are unavailable. Keeping the input rate; no app-default guesses."
    case .discoveryUnavailable:
      return
        "Auto: source rate unknown because audio-client discovery is unavailable. Keeping the current input rate."
    case .awaitingSource:
      return
        "Auto: waiting for an audio client routed to the selected input. Keeping the current rate."
    case .multipleSources:
      return
        "Auto: \u{201C}\(playbackSourceSummary)\u{201D} are routed but none claims a rate. Save a rate for the playing app below."
    case .unknownSource:
      return
        "Auto: no rate claimed yet. Save a rate for the playing app below; nothing is guessed."
    case .awaitingMetadata:
      return
        "Auto: Music is paused or has not reported a usable track rate. Keeping the current input rate."
    case .automationDenied:
      return
        "Allow Music metadata access in System Settings → Privacy & Security → Automation, or use Follow input / Fixed."
    case .invalidRate:
      return
        "The requested rate is outside the supported 8–768 kHz band. Keeping the current input rate."
    }
  }

  var rateConversionSummary: String {
    guard status.phase == .running, let capture = status.inputSampleRate,
      let render = status.renderSampleRate
    else { return "Start to inspect the captured PCM → DSP → DAC path." }
    if abs(capture - render) > 0.5 {
      return
        "Output limit: captured \(Self.rateText(capture)) is converted to \(Self.rateText(render))."
    }
    if let output = outputDevices.first(where: { $0.id == selectedOutputID }),
      abs(output.nominalSampleRate - render) > 0.5
    {
      return "Output rate is settling or differs from the DSP rate; check the selected DAC."
    }
    if let source = rateDecision.sourceRate {
      if abs(source - capture) > 0.5 {
        return
          "Source evidence reports \(Self.rateText(source)), but capture is \(Self.rateText(capture)); upstream conversion may already have occurred."
      }
      return
        "Reported source, capture and DSP rates match. Downmix/gain and adaptive clock correction still alter samples."
    }
    return
      "Source rate unknown: upstream conversion cannot be determined. DSP follows captured PCM; adaptive clock correction remains active."
  }

  private func musicRateSetupCheck(input: AudioDeviceInfo?) -> SetupCheck {
    let checkStatus: SetupCheck.Status
    switch rateDecision {
    case .automationDenied, .invalidRate, .conflictingRates: checkStatus = .needsAttention
    case .fixed(let rate), .matching(let rate, _):
      let actual = status.phase == .running ? status.inputSampleRate : input?.nominalSampleRate
      checkStatus = actual.map { abs($0 - rate) <= 0.5 } == true ? .verified : .manual
    default: checkStatus = .manual
    }
    return SetupCheck(
      id: .musicRate, title: "Sample-rate policy", status: checkStatus,
      guidance: sampleRateSummary)
  }

  private static func rateText(_ rate: Double) -> String {
    guard rate.isFinite, rate > 0, rate < Double(Int.max) else { return "No usable sample rate" }
    return "\(Int(rate.rounded())) Hz"
  }

  private static func inputRateGuidance(deviceRate: Double, renderRate: Double?) -> String {
    let deviceText = rateText(deviceRate)
    guard let renderRate else {
      return "\(deviceText): the stereo mix renders at this rate when the output supports it."
    }
    if abs(renderRate - deviceRate) <= 0.5 {
      return
        "\(deviceText) in and rendered at the same nominal rate; adaptive clock correction remains active."
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

  /// Audio-client discovery is independent of rate mode. Metadata is read only for
  /// a supported, exclusive routed client, never for unrelated background Music.
  private func syncMusicRateMonitoring() {
    let desiredInput = status.phase == .running && !isKeepingOutputAwake ? selectedInputID : nil
    if sourceMonitoringInput != desiredInput {
      audioSourceMonitor?.stop()
      sourceMonitorGeneration &+= 1
      sourceMonitoringInput = desiredInput
      audioSources = AudioSourceObservation(isAvailable: false)
      cancelRateMatch()
      if let desiredInput {
        let generation = sourceMonitorGeneration
        audioSourceMonitor?.start(inputDeviceID: desiredInput) { [weak self] observation in
          MainActor.assumeIsolated {
            guard let self, self.sourceMonitorGeneration == generation,
              self.sourceMonitoringInput == desiredInput
            else { return }
            self.receiveAudioSources(observation)
          }
        }
      }
    }
    syncDecoderMonitoring(monitoring: desiredInput != nil)
    syncSourceFileMonitoring(monitoring: desiredInput != nil)
    let shouldMonitor =
      preferences.sampleRateMode == .automatic && preferences.matchMusicSampleRate
      && audioSources.sources.contains {
        $0.bundleIdentifier == SampleRateDecision.musicBundleIdentifier
      }
    guard shouldMonitor != isMonitoringMusicRate else { return }
    isMonitoringMusicRate = shouldMonitor
    musicObservationGeneration &+= 1
    guard shouldMonitor else {
      musicRateMonitor?.stop()
      detectedMusicRate = nil
      musicRateFailure = nil
      musicIsIdle = false
      return
    }
    musicIsIdle = false
    let generation = musicObservationGeneration
    musicRateMonitor?.start { [weak self] observation in
      MainActor.assumeIsolated {
        guard let self, self.musicObservationGeneration == generation,
          self.isMonitoringMusicRate
        else { return }
        self.receiveMusicRate(observation)
      }
    }
  }

  /// Decoder logs are read for every routed client in Automatic mode (bounded), so a
  /// silent second client no longer hides a playing client's decoder evidence.
  private func syncDecoderMonitoring(monitoring: Bool) {
    let desired: [AudioPlaybackSource] =
      monitoring && preferences.sampleRateMode == .automatic && audioSources.isAvailable
      ? Array(audioSources.sources.prefix(Self.maximumDecoderMonitors)) : []
    var desiredByPID: [Int32: AudioPlaybackSource] = [:]
    for source in desired where desiredByPID[source.id] == nil {
      desiredByPID[source.id] = source
    }
    for (pid, slot) in decoderMonitors where desiredByPID[pid] != slot.source {
      slot.monitor.stop()
      decoderMonitors[pid] = nil
      decoderRates[pid] = nil
      decoderEvidencePIDs.remove(pid)
    }
    // Observations for clients that are gone must not linger.
    decoderRates = decoderRates.filter { decoderMonitors[$0.key] != nil }
    decoderEvidencePIDs.formIntersection(decoderMonitors.keys)
    guard let makeDecoderRateMonitor else { return }
    for source in desired where decoderMonitors[source.id] == nil {
      decoderObservationGeneration &+= 1
      let generation = decoderObservationGeneration
      let monitor = makeDecoderRateMonitor()
      decoderMonitors[source.id] = DecoderMonitorSlot(
        source: source, monitor: monitor, generation: generation)
      monitor.start(source: source) { [weak self] observation in
        MainActor.assumeIsolated {
          guard let self, let slot = self.decoderMonitors[source.id],
            slot.generation == generation, slot.source == source
          else { return }
          self.receiveDecoderRate(observation, from: source)
        }
      }
    }
  }

  /// Open-file readers follow the same per-client lifecycle as decoder-log readers.
  private func syncSourceFileMonitoring(monitoring: Bool) {
    let desired: [AudioPlaybackSource] =
      monitoring && preferences.sampleRateMode == .automatic && audioSources.isAvailable
      ? Array(audioSources.sources.prefix(Self.maximumDecoderMonitors)) : []
    var desiredByPID: [Int32: AudioPlaybackSource] = [:]
    for source in desired where desiredByPID[source.id] == nil {
      desiredByPID[source.id] = source
    }
    for (pid, slot) in sourceFileMonitors where desiredByPID[pid] != slot.source {
      slot.monitor.stop()
      sourceFileMonitors[pid] = nil
      sourceFiles[pid] = nil
    }
    sourceFiles = sourceFiles.filter { sourceFileMonitors[$0.key] != nil }
    guard let makeSourceFileMonitor else { return }
    for source in desired where sourceFileMonitors[source.id] == nil {
      sourceFileGeneration &+= 1
      let generation = sourceFileGeneration
      let monitor = makeSourceFileMonitor()
      sourceFileMonitors[source.id] = SourceFileMonitorSlot(
        source: source, monitor: monitor, generation: generation)
      monitor.start(source: source) { [weak self] observation in
        MainActor.assumeIsolated {
          guard let self, let slot = self.sourceFileMonitors[source.id],
            slot.generation == generation, slot.source == source
          else { return }
          self.receiveSourceFile(observation, from: source)
        }
      }
    }
  }

  private func receiveSourceFile(
    _ observation: SourceFileObservation, from source: AudioPlaybackSource
  ) {
    guard observation.sourcePID == source.id, sourceFiles[source.id] != observation else {
      return
    }
    sourceFiles[source.id] = observation
    if let format = observation.format {
      // The file name stays local to this log; full paths are never recorded.
      log.log(
        .info, "source-file",
        "app=\(source.name) pid=\(source.id) format=\(format.summary)\(observation.isIdle ? " idle" : "")"
      )
    } else if observation.isAmbiguous {
      log.log(.info, "source-file", "app=\(source.name) pid=\(source.id) ambiguous open files")
    }
    applyRatePolicy()
  }

  private func receiveDecoderRate(
    _ observation: DecoderRateObservation, from source: AudioPlaybackSource
  ) {
    // A record attributed to any other PID cannot speak for this client.
    guard observation.sourcePID == source.id else { return }
    decoderRates[source.id] = observation
    if observation.isAvailable, let date = observation.date,
      DecoderInputRateParser.isFresh(date, now: Date())
    {
      decoderEvidencePIDs.insert(source.id)
      if let rate = observation.sampleRate, InputRateConverter.supportedDeviceRates.contains(rate) {
        log.log(
          .info, "decoder-rate",
          "app=\(source.name) pid=\(source.id) inputRate=\(Int(rate.rounded()))Hz evidenceDate=\(date.timeIntervalSince1970)"
        )
      }
    }
    applyRatePolicy()
  }

  private func receiveAudioSources(_ observation: AudioSourceObservation) {
    guard audioSources != observation else { return }
    audioSources = observation
    if preferences.sampleRateMode == .automatic {
      cancelRateMatch()
    }
    // A new PID/client set invalidates even a previously supported adapter's metadata.
    if isMonitoringMusicRate {
      isMonitoringMusicRate = false
      musicObservationGeneration &+= 1
      musicRateMonitor?.stop()
      detectedMusicRate = nil
      musicRateFailure = nil
    }
    log.log(
      .info, "sources",
      "discovery=\(observation.isAvailable) clients=\(observation.sources.map(\.name).joined(separator: ", "))"
    )
    syncMusicRateMonitoring()
    applyRatePolicy()
  }

  private func receiveMusicRate(_ observation: MusicRateObservation) {
    switch observation {
    case .playing(let rate, let track):
      musicIsIdle = false
      if detectedMusicRate != rate {
        log.log(
          .info, "music",
          "track=\(track.isEmpty ? "-" : track) reportedRate=\(Self.rateText(rate))")
      }
      detectedMusicRate = rate
      musicRateFailure = nil
    case .idle:
      musicIsIdle = true
      // A pause ends Music's playback episode; other clients keep their evidence.
      for source in audioSources.sources
      where source.bundleIdentifier == SampleRateDecision.musicBundleIdentifier {
        decoderRates[source.id] = nil
        decoderEvidencePIDs.remove(source.id)
      }
      detectedMusicRate = nil
      musicRateFailure = nil
    case .metadataUnavailable:
      musicIsIdle = false
      detectedMusicRate = nil
      musicRateFailure = nil
    // Missing metadata is not a new playback episode; retain decoder precedence.
    case .failure(let failure):
      musicIsIdle = false
      if musicRateFailure != failure {
        log.log(.warning, "music", "rate reading failed: \(Self.describe(failure))")
      }
      detectedMusicRate = nil
      musicRateFailure = failure
    }
    applyRatePolicy()
  }

  var routedApps: [AudioPlaybackSource] { audioSources.sources }

  /// Apps currently routed to the input, with any saved declaration.
  var routedAppRows: [(source: AudioPlaybackSource, savedRate: Double?)] {
    audioSources.sources.map {
      ($0, preferences.appRateProfiles[SampleRateDecision.profileKey(for: $0)])
    }
  }

  /// The live captured input rate, offered as a one-click declaration for a routed app
  /// ("this app plays at the rate the device is at now"). Nil while stopped or when the
  /// device sits at a rate that cannot be saved.
  var currentRateForProfile: Double? {
    guard status.phase == .running, let live = status.inputSampleRate else { return nil }
    return AppPreferences.selectableSampleRates.first { abs($0 - live) <= 0.5 }
  }

  func saveCurrentRateProfile(for key: String) {
    guard let rate = currentRateForProfile else { return }
    saveRateProfile(rate, for: key)
  }

  /// Profiles use the same bounds as persistence, so a saved rate never vanishes on reload.
  func saveRateProfile(_ rate: Double, for key: String) {
    guard AppPreferences.selectableSampleRates.contains(rate),
      !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key.count <= 256
    else { return }
    preferences.appRateProfiles[key] = rate
    cancelRateMatch()
    persist()
    applyRatePolicy()
  }

  func removeRateProfile(for key: String) {
    guard preferences.appRateProfiles.removeValue(forKey: key) != nil else { return }
    cancelRateMatch()
    persist()
    applyRatePolicy()
  }

  func rateSettingsChanged() {
    cancelRateMatch()
    persist()
    applyRatePolicy()
  }

  private func cancelRateMatch() {
    rateRequestGate?.close()
    rateRequestGate = nil
    lastRequestedRateDecision = nil
    rateMatchTask?.cancel()
    rateMatchTask = nil
    pendingRateDecision = nil
  }

  /// Both Auto and explicit Fixed use the existing serialized HAL request/rebuild
  /// path. Unknown/multiple sources hold the device rate, not an assumed 48 kHz.
  /// Source bit depth stated by the evidence that won the rate decision, if any.
  var sourceBitDepth: Int? {
    guard case .matching(_, let evidence) = rateDecision else { return nil }
    switch evidence {
    case .decoder(let pid): return decoderRates[pid]?.bitDepth
    case .file(let pid, _): return sourceFiles[pid]?.format?.bitDepth
    case .profile, .music: return nil
    }
  }

  /// Tells the engine which bit depth the DAC should run at: the winning source's own
  /// depth in Match-source mode (deepest when unknown or lossy), the deepest otherwise.
  /// While Auto holds the rate, the depth is held too, so a gap between tracks does not
  /// flip the DAC's format.
  private func syncOutputBitDepth() {
    guard status.phase == .running, !isKeepingOutputAwake else {
      sentOutputBitDepth = nil
      return
    }
    let desired: Int?
    switch rateDecision {
    case .matching:
      desired = preferences.outputBitDepthMode == .matchSource ? sourceBitDepth : nil
    case .fixed, .followingInput:
      desired = nil
    default:
      guard preferences.outputBitDepthMode == .deepest else { return }
      desired = nil
    }
    guard sentOutputBitDepth != .some(desired) else { return }
    sentOutputBitDepth = .some(desired)
    engine.setOutputBitDepth(desired)
    log.log(
      .info, "output-format",
      "requestedBitDepth=\(desired.map { "\($0)-bit (source)" } ?? "deepest")")
  }

  private func applyRatePolicy() {
    syncOutputBitDepth()
    let decision = rateDecision
    guard status.phase == .running, let rate = decision.requestedRate,
      InputRateConverter.supportedDeviceRates.contains(rate),
      let input = inputDevices.first(where: { $0.id == selectedInputID })
    else {
      cancelRateMatch()
      return
    }
    let liveRate = status.inputSampleRate ?? input.nominalSampleRate
    if abs(liveRate - rate) <= 0.5 {
      cancelRateMatch()
      return
    }
    if lastRequestedRateDecision == decision, rateRequestGate?.isOpen == true { return }
    guard pendingRateDecision != decision else { return }
    cancelRateMatch()
    pendingRateDecision = decision
    if rateMatchDelay == .zero {
      requestInputRate(rate, decision: decision)
      return
    }
    rateMatchTask = Task { [weak self] in
      guard let delay = self?.rateMatchDelay else { return }
      do { try await Task.sleep(for: delay) } catch { return }
      guard !Task.isCancelled else { return }
      self?.requestInputRate(rate, decision: decision)
    }
  }

  private func requestInputRate(_ rate: Double, decision: SampleRateDecision) {
    guard status.phase == .running, rateDecision == decision,
      pendingRateDecision == decision,
      let input = inputDevices.first(where: { $0.id == selectedInputID })
    else { return }
    pendingRateDecision = nil
    lastRequestedRateDecision = decision
    let expiration: Date?
    if case .matching(_, let evidence) = rateDecision, case .decoder(let pid) = evidence,
      let date = decoderRates[pid]?.date
    {
      expiration = date.addingTimeInterval(DecoderInputRateParser.maximumAge)
    } else {
      expiration = nil
    }
    let requestGate = AudioRateRequest(expiresAt: expiration)
    rateRequestGate = requestGate
    engine.setInputSampleRate(rate, requestGate: requestGate)
    log.log(
      .info, "rate-policy",
      "mode=\(preferences.sampleRateMode.rawValue) input=\(Self.deviceSummary(input)) requestedRate=\(Int(rate.rounded()))Hz"
    )
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
    cancelRateMatch()
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
    applyRatePolicy()
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
    if status.renderSampleRate != update.renderSampleRate {
      status.renderSampleRate = update.renderSampleRate
    }
    if status.outputPhysicalFormat != update.outputPhysicalFormat {
      if let format = update.outputPhysicalFormat {
        log.log(
          .info, "output-format",
          "dac=\(Int(format.sampleRate.rounded()))Hz \(format.label)")
      }
      status.outputPhysicalFormat = update.outputPhysicalFormat
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
    applyRatePolicy()
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
