import AudioToolbox
import CoreAudio
import Foundation

let checkQueue = DispatchQueue(label: "Downmix.HALChecks")

func require(_ value: @autoclosure () -> Bool, _ message: String) {
  precondition(value(), message)
}

func startEngine(keepAlive: Bool = false, channels: Int = 16, gate: AudioRenderGate? = nil) throws
  -> AudioEngine
{
  let engine = AudioEngine(queue: checkQueue)
  var config = DownmixProcessor.Configuration()
  config.inputChannelCount = channels
  try engine.start(
    inputDeviceID: 101, outputDeviceID: 201, configuration: config,
    framesPerBuffer: 128, keepAliveOnly: keepAlive, renderGate: gate)
  engine.checkCancelTimer()  // Deterministic tick, not elapsed-time scheduling.
  require(engine.currentStatus.phase == (keepAlive ? .keepAlive : .running), "Actual engine starts")
  return engine
}

func routeChecks() {
  stubHAL.reset()
  let output = DeviceManager.allDevices().first { $0.id == 201 }!
  func safe(_ input: String = "capture") -> Bool {
    DeviceManager.isSafeOutputRoute(output, inputUID: input)
  }
  require(safe(), "Disjoint leaf devices are safe")
  require(!safe("speakers"), "Identical roots are unsafe")
  require(!safe("missing"), "Unresolved input fails closed")
  stubHAL.devices[101]!.children = [201]
  require(!safe(), "Input aggregate containing direct output is unsafe")
  stubHAL.devices[101]!.children = [301]
  stubHAL.devices[301] = .init(uid: "shared", name: "Shared", outputChannels: 2)
  stubHAL.devices[201]!.children = [301]
  require(!safe(), "Overlapping input/output aggregates are unsafe")
  stubHAL.devices[101]!.children = nil
  require(safe(), "Disjoint aggregate is safe")
  stubHAL.devices[301]!.children = [201]
  require(!safe(), "Output cycle fails closed")
  stubHAL.devices[301]!.children = nil
  stubHAL.devices[101]!.children = [101]
  require(!safe(), "Input cycle fails closed")
  stubHAL.devices[101]!.children = nil
  stubHAL.devices[301]!.unreadable = true
  require(!safe(), "Unreadable output child fails closed")
  stubHAL.devices[301]!.unreadable = false
  stubHAL.devices[101]!.unreadable = true
  require(!safe(), "Unreadable input fails closed")
  stubHAL.devices[101]!.unreadable = false
  stubHAL.devices[301]!.name = "BlackHole 2ch"
  require(!safe(""), "BlackHole child rejected even during keep-alive")
  stubHAL.devices[301]!.name = "Shared"
  stubHAL.devices[301]!.uid = "BlackHole-output"
  require(!safe(), "BlackHole UID rejected")
  stubHAL.devices[301]!.uid = "shared"
  stubHAL.devices[201]!.children = [301, 302]
  stubHAL.devices[302] = .init(uid: "branch", name: "Branch", children: [301])
  require(safe(), "Shared child in acyclic DAG is not a cycle")
  stubHAL.devices[101]!.uid = "shared"
  require(!safe("shared"), "UID aliases overlap even with different object IDs")
  stubHAL.reset()
  stubHAL.devices[101]!.name = "BlackHole 16ch"
  require(safe(), "BlackHole INPUT alone is allowed")

  let catalog = DeviceManager.allDevices()
  require(
    DeviceManager.preferredInput(matchingName: "Absent", uid: nil, devices: catalog) == nil,
    "Name-only missing input must not fall back")
  require(
    DeviceManager.preferredOutput(matchingName: "Absent", uid: "", devices: catalog) == nil,
    "Name-only missing output must not fall back")
  require(
    DeviceManager.preferredInput(matchingName: "BlackHole 16ch", uid: "missing", devices: catalog)
      == nil, "UID remains authoritative")
  require(
    DeviceManager.preferredOutput(
      matchingName: " Speakers (Unavailable) ", uid: nil, devices: catalog)?
      .id == 201, "Legacy name normalization still matches")
  require(
    DeviceManager.preferredInput(matchingName: "", uid: nil, devices: catalog)?.id == 101,
    "Default input only with no saved identity")
  require(
    DeviceManager.preferredOutput(matchingName: nil, uid: nil, devices: catalog)?.id == 201,
    "Default output only with no saved identity")
  print("PASS: two-graph route safety and saved-name resolution")
}

func unsafeStartChecks() {
  let cases: [(String, () -> Void)] = [
    ("input aggregate contains direct output", { stubHAL.devices[101]!.children = [201] }),
    (
      "overlapping aggregates",
      {
        stubHAL.devices[301] = .init(uid: "shared", name: "Shared", outputChannels: 2)
        stubHAL.devices[101]!.children = [301]
        stubHAL.devices[201]!.children = [301]
      }
    ),
    ("BlackHole output", { stubHAL.devices[201]!.name = "BlackHole 2ch" }),
    ("cyclic input", { stubHAL.devices[101]!.children = [101] }),
    ("empty aggregate", { stubHAL.devices[201]!.children = [] }),
  ]
  for (label, mutate) in cases {
    stubHAL.reset()
    mutate()
    let engine = AudioEngine(queue: checkQueue)
    do {
      try engine.start(
        inputDeviceID: 101, outputDeviceID: 201, configuration: .init(), framesPerBuffer: 128)
      preconditionFailure("Unsafe start succeeded: \(label)")
    } catch {
      require(engine.currentStatus.phase == .error, "Unsafe start publishes error: \(label)")
      require(stubHAL.units.isEmpty && stubHAL.disposalCount == 0, "Rejected BEFORE unit creation")
    }
  }
  print("PASS: actual-engine unsafe routes rejected before HAL unit creation")
}

func watchdogChecks() throws {
  let cases: [(String, () -> Void)] = [
    ("input below two channels", { stubHAL.devices[101]!.inputChannels = 1 }),
    ("output channels", { stubHAL.devices[201]!.outputChannels = 1 }),
    (
      "input client channels",
      {
        let unit = stubHAL.units.first { $0.value.isInput }!.key
        stubHAL.units[unit]!.client.mChannelsPerFrame = 8
      }
    ),
    (
      "output client rate",
      {
        let unit = stubHAL.units.first { !$0.value.isInput }!.key
        stubHAL.units[unit]!.client.mSampleRate = 44_100
      }
    ),
    (
      "output client layout",
      {
        let unit = stubHAL.units.first { !$0.value.isInput }!.key
        stubHAL.units[unit]!.client.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
      }
    ),
    ("input physical stream rate", { stubHAL.devices[101]!.physicalRate = 0 }),
    ("output virtual stream rate", { stubHAL.devices[201]!.virtualRate = .nan }),
    ("output disconnect", { stubHAL.devices[201]!.alive = 0 }),
    (
      "selected unit device",
      {
        let unit = stubHAL.units.first { !$0.value.isInput }!.key
        stubHAL.units[unit]!.device = 101
      }
    ),
    ("input aggregate overlap introduced", { stubHAL.devices[101]!.children = [201] }),
  ]
  for (label, mutate) in cases {
    stubHAL.reset()
    let engine = try startEngine()
    engine.checkWatchdogTick()
    require(engine.currentStatus.phase == .running, "Stable watchdog stays running")
    mutate()
    engine.checkWatchdogTick()
    require(engine.currentStatus.phase == .error, "Watchdog stops: \(label)")
    require(!engine.currentStatus.message.isEmpty, "Clear failure message")
    require(engine.currentStatus.meters == .empty, "Stopped meters cleared")
    require(stubHAL.units.isEmpty && stubHAL.disposalCount == 2, "Both units disposed: \(label)")
    require(!engine.checkStorageAllocated, "Storage released after disposal")
  }
  for (label, mutate) in cases where label.hasPrefix("output") {
    stubHAL.reset()
    let engine = try startEngine(keepAlive: true)
    mutate()
    engine.checkWatchdogTick()
    require(engine.currentStatus.phase == .error, "Keep-alive watchdog stops: \(label)")
    require(stubHAL.units.isEmpty && stubHAL.disposalCount == 1, "Keep-alive unit disposed")
  }
  stubHAL.reset()
  stubHAL.devices[101]!.inputChannels = 32
  let wider = try startEngine(channels: 32)
  require(
    wider.checkInputChannels == InputChannelLayout.channelCount,
    "A wider device is read through the 16 bed slots only")
  stubHAL.devices[101]!.inputChannels = 16
  wider.checkWatchdogTick()
  require(
    wider.currentStatus.phase == .running,
    "Narrowing back to the bed width needs no restart")
  wider.stop()
  stubHAL.reset()
  let compatible = try startEngine()
  stubHAL.devices[101]!.inputChannels = 32
  stubHAL.devices[201]!.outputChannels = 4
  compatible.checkWatchdogTick()
  require(compatible.currentStatus.phase == .running, "Compatible wider hardware need not stop")
  compatible.stop()
  print("PASS: actual-engine deterministic running/keep-alive topology and stream watchdog")
}

func nilOutputChecks() throws {
  for keepAlive in [false, true] {
    stubHAL.reset()
    let engine = try startEngine(keepAlive: keepAlive)
    require(
      stubHAL.outputCallback() == kAudioUnitErr_FormatNotSupported,
      "Open gate nil ioData reports a format failure through actual registered callback")
    engine.checkWatchdogTick()
    require(engine.currentStatus.phase == .error, "Nil output stops via watchdog")
    require(engine.currentStatus.diagnostics.renderErrorCount == 1, "Failure counter preserved")
    require(engine.currentStatus.diagnostics.queuedFrames == 0, "No stale failure latency")
    require(stubHAL.units.isEmpty, "Nil output cleans up")

    stubHAL.reset()
    let stoppedBeforeWatchdog = try startEngine(keepAlive: keepAlive)
    require(
      stubHAL.outputCallback() == kAudioUnitErr_FormatNotSupported,
      "Callback failure recorded before the next UI/watchdog sample")
    require(
      stoppedBeforeWatchdog.currentStatus.diagnostics.renderErrorCount == 0,
      "Published status intentionally remains at UI cadence")
    stoppedBeforeWatchdog.stop()
    require(
      stoppedBeforeWatchdog.finalDiagnostics.renderErrorCount == 1
        && stoppedBeforeWatchdog.finalDiagnostics.queuedFrames == 0,
      "Fresh final atomic counters survive cleanup even without watchdog publication")

    stubHAL.reset()
    let gate = AudioRenderGate()
    let cancelled = try startEngine(keepAlive: keepAlive, gate: gate)
    gate.close()
    require(stubHAL.outputCallback() == noErr, "Cancelled nil callback is not a failure")
    cancelled.checkWatchdogTick()
    require(
      cancelled.currentStatus.diagnostics.renderErrorCount == 0, "No cancellation error count")
    cancelled.stop()
  }
  print("PASS: actual output callback nil-data failure and cancellation")
}

/// Immutable callback registration, retained while an in-flight callback completes.
final class CallbackRegistration: @unchecked Sendable {
  let callback: AURenderCallbackStruct
  init(_ callback: AURenderCallbackStruct) { self.callback = callback }
  func input() {
    var flags: AudioUnitRenderActionFlags = []
    var timestamp = AudioTimeStamp()
    require(
      callback.inputProc!(callback.inputProcRefCon!, &flags, &timestamp, 1, 32, nil) == noErr,
      "In-flight cancelled input returns success")
  }
}

final class WeakEngine {
  weak var value: AudioEngine?
  init(_ value: AudioEngine?) { self.value = value }
}

func cleanupChecks() throws {
  stubHAL.reset()
  stubHAL.initializeFailure = kAudioUnitErr_FailedInitialization
  let failed = AudioEngine(queue: checkQueue)
  do {
    try failed.start(
      inputDeviceID: 101, outputDeviceID: 201, configuration: .init(), framesPerBuffer: 128)
    preconditionFailure("Failed initialize should throw")
  } catch {
    require(failed.currentStatus.phase == .error, "Failed setup publishes error")
    require(stubHAL.units.isEmpty && stubHAL.disposalCount == 1, "Partial setup disposed")
  }

  for keepAlive in [false, true] {
    stubHAL.reset()
    var owner: AudioEngine? = try startEngine(keepAlive: keepAlive)
    let weakEngine = WeakEngine(owner)
    stubHAL.disposalFailures = 1
    stubHAL.disposalProbe = {
      require(weakEngine.value?.checkStorageAllocated == true, "Storage lives DURING disposal")
    }
    owner!.stop()
    require(owner!.currentStatus.phase == .error, "Failed disposal surfaces error")
    require(stubHAL.units.count == 1, "Successfully disposed unit is not retained")
    require(owner!.checkStorageAllocated, "Failed disposal retains callback storage")
    owner = nil
    require(weakEngine.value != nil, "Failed disposal retains engine after owner releases")
    let late = stubHAL.units.values.first!.callback
    var flags: AudioUnitRenderActionFlags = []
    var timestamp = AudioTimeStamp()
    require(
      late.inputProc!(late.inputProcRefCon!, &flags, &timestamp, 1, 32, nil) == noErr,
      "Late callback to retained refCon sees closed gate")
    var recovered = weakEngine.value
    recovered!.stop()
    require(stubHAL.units.isEmpty, "Retry disposal succeeds")
    require(!recovered!.checkStorageAllocated, "Retry releases storage after quiescence")
    stubHAL.disposalProbe = nil
    recovered = nil
    require(weakEngine.value == nil, "Successful retry breaks retention cycle")
  }

  stubHAL.reset()
  let inFlight = try startEngine()
  let entered = DispatchSemaphore(value: 0)
  let resume = DispatchSemaphore(value: 0)
  let group = DispatchGroup()
  stubHAL.renderHook.withLock { hook in
    hook = {
      entered.signal()
      require(resume.wait(timeout: .now() + 5) == .success, "Render resumed by stop")
    }
  }
  let registration = CallbackRegistration(stubHAL.units.values.first { $0.isInput }!.callback)
  group.enter()
  DispatchQueue.global().async {
    registration.input()
    group.leave()
  }
  require(entered.wait(timeout: .now() + 5) == .success, "Actual input callback entered render")
  stubHAL.stopProbe = {
    require(inFlight.checkStorageAllocated, "Storage lives while callback is in flight")
    resume.signal()
    require(group.wait(timeout: .now() + 5) == .success, "Stop establishes callback quiescence")
  }
  stubHAL.disposalProbe = {
    require(inFlight.checkStorageAllocated, "Storage survives through disposal after callback exit")
  }
  inFlight.stop()
  require(!inFlight.checkStorageAllocated && stubHAL.units.isEmpty, "Post-quiescence storage freed")
  stubHAL.stopProbe = nil
  stubHAL.disposalProbe = nil
  stubHAL.renderHook.withLock { $0 = nil }
  print(
    "PASS: actual-engine failed setup/disposal, retained refCon and in-flight quiescence lifetime")
}

func bedLayoutChecks() throws {
  stubHAL.reset()
  let engine = try startEngine()
  require(
    engine.currentStatus.bedLayoutInstalled == true,
    "Running engine certifies the installed bed layout")
  for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
    require(
      stubHAL.layouts[101]?[scope] == InputChannelLayout.bedLabels,
      "Bed labels installed for scope \(scope)")
  }
  require(stubHAL.layoutWrites == 2, "One layout write per scope")
  require(
    InputChannelLayout.bedLabels.first == kAudioChannelLabel_Left
      && InputChannelLayout.bedLabels[3] == kAudioChannelLabel_LFEScreen
      && InputChannelLayout.bedLabels.count == 16,
    "Bed label order matches the 9.1.6 processor order")
  engine.stop()
  require(engine.currentStatus.bedLayoutInstalled == nil, "Stopped run claims no layout")

  stubHAL.devices[101]!.inputChannels = 16
  stubHAL.layouts[101] = [
    kAudioObjectPropertyScopeOutput: InputChannelLayout.bedLabels,
    kAudioObjectPropertyScopeInput: InputChannelLayout.bedLabels,
  ]
  let compatible = try startEngine()
  require(stubHAL.layoutWrites == 2, "A convertible layout is never rewritten")
  require(compatible.currentStatus.bedLayoutInstalled == true, "Compatible layout verified")
  compatible.stop()

  stubHAL.reset()
  stubHAL.devices[101]!.inputChannels = 32
  let wide = try startEngine(channels: 32)
  require(
    wide.currentStatus.bedLayoutInstalled == nil && stubHAL.layoutWrites == 0,
    "A non-16-channel input keeps its own layout and makes no claim")
  wide.stop()

  stubHAL.reset()
  stubHAL.layoutWriteFailures = 4
  let refused = try startEngine()
  require(
    refused.currentStatus.phase == .running && refused.currentStatus.bedLayoutInstalled == false,
    "A refused layout never stops rendering")
  refused.stop()
  print("PASS: actual-engine bed layout install, idempotence, width and refusal reporting")
}

/// The reported bug: Apple Music (through a sample-rate switcher) moves the input
/// device between 44.1, 48 and 96 kHz, and players pick their own content width.
/// Neither may stop the renderer any more.
func deviceRateAndWidthChecks() throws {
  stubHAL.reset()
  stubHAL.devices[101]!.rate = 44_100
  let engine = try startEngine()
  require(engine.checkInputRate == 44_100, "Input follows the device rate")
  require(
    !engine.checkHasRateConverter, "Passthrough needs no converter when the output matches")
  require(engine.currentStatus.inputSampleRate == 44_100, "Status reports the live input rate")
  require(
    engine.currentStatus.renderSampleRate == 44_100,
    "The DSP and output render at the input rate")
  require(
    engine.currentStatus.message.contains("44.1 kHz"),
    "Status names the render rate: \(engine.currentStatus.message)")
  require(
    engine.currentStatus.bedLayoutInstalled == true,
    "Bed layout still installs at the device's own rate")
  var inputUnit = stubHAL.units.values.first { $0.isInput }!
  var outputUnit = stubHAL.units.values.first { !$0.isInput }!
  require(inputUnit.client.mSampleRate == 44_100, "Input unit opens at the device rate")
  require(inputUnit.client.mChannelsPerFrame == 16, "Input unit opens the full bed width")
  require(outputUnit.client.mSampleRate == 44_100, "Output client follows the render rate")
  require(stubHAL.devices[201]!.rate == 44_100, "The output device is set to match")

  // Feed a known per-channel signal; the meters prove the passthrough path reaches the DSP.
  stubHAL.inputValues = (0..<16).map { 0.1 / Float($0 + 1) }
  for _ in 0..<12 { require(stubHAL.inputCallback(frames: 512) == noErr, "44100 input renders") }
  engine.checkWatchdogTick()
  require(
    abs(engine.currentStatus.meters.inputPeaksDb[0] - 20 * log10(0.1)) < 1,
    "Passthrough input reaches the bed meters")

  // Live rate change, as Music matching or a switcher does at a track boundary. A stale
  // client can fail one render before the watchdog reopens; that error must not stop it.
  let originalUnits = Set(stubHAL.units.keys)
  stubHAL.devices[101]!.rate = 96_000
  require(
    stubHAL.inputCallback(frames: 512) == kAudioUnitErr_CannotDoInCurrentContext,
    "A stale client rate fails the render like real AUHAL")
  engine.checkWatchdogTick()
  require(engine.currentStatus.phase == .running, "Live rate change keeps rendering")
  require(
    engine.currentStatus.diagnostics.renderErrorCount == 1,
    "The transient render error is counted but does not stop the run")
  require(engine.checkInputRate == 96_000, "Engine follows the new rate")
  require(!engine.checkHasRateConverter, "96 kHz is passthrough, not converted")
  require(engine.currentStatus.renderSampleRate == 96_000, "Render rate follows the source")
  inputUnit = stubHAL.units.values.first { $0.isInput }!
  outputUnit = stubHAL.units.values.first { !$0.isInput }!
  require(inputUnit.client.mSampleRate == 96_000, "Input unit reopens at 96 kHz")
  require(outputUnit.client.mSampleRate == 96_000, "Output client reopens at 96 kHz")
  require(stubHAL.devices[201]!.rate == 96_000, "Output device follows the source rate")
  require(stubHAL.disposalCount == 2, "Both old units disposed before replacing transport")
  require(
    originalUnits.isDisjoint(with: stubHAL.units.keys),
    "Fresh units discard stale device-side clocks/converters, not just client formats")
  for _ in 0..<24 { require(stubHAL.inputCallback(frames: 512) == noErr, "96000 input renders") }
  engine.checkWatchdogTick()
  require(
    abs(engine.currentStatus.meters.inputPeaksDb[0] - 20 * log10(0.1)) < 1,
    "Audio still reaches the meters after the rate change")

  let unitsAt96k = Set(stubHAL.units.keys)
  stubHAL.devices[101]!.rate = 48_000
  engine.checkWatchdogTick()
  require(
    unitsAt96k.isDisjoint(with: stubHAL.units.keys), "Returning to 48 kHz also replaces both units")
  require(
    engine.currentStatus.phase == .running && !engine.checkHasRateConverter,
    "Back at 48 kHz the pipeline stays passthrough")
  require(
    stubHAL.devices[201]!.rate == 48_000 && abs(engine.checkInputRate - 48_000) < 0.5,
    "Both devices follow the source rate")

  // A narrower input keeps rendering the slots it has instead of stopping.
  stubHAL.devices[101]!.inputChannels = 8
  engine.checkWatchdogTick()
  require(
    engine.currentStatus.phase == .running && engine.checkInputChannels == 8,
    "Narrower input reopens at its own width")
  require(
    stubHAL.units.values.first { $0.isInput }!.client.mChannelsPerFrame == 8,
    "Input client width follows the device")
  require(engine.currentStatus.inputChannelCount == 8, "Status reports the live width")
  for _ in 0..<12 { require(stubHAL.inputCallback(frames: 512) == noErr, "8ch input renders") }
  engine.checkWatchdogTick()
  require(
    abs(engine.currentStatus.meters.inputPeaksDb[5] - 20 * log10(0.1 / 6)) < 1,
    "Remaining bed slots still meter")

  stubHAL.devices[101]!.inputChannels = 32
  engine.checkWatchdogTick()
  require(
    engine.currentStatus.phase == .running && engine.checkInputChannels == 16,
    "Wider input clamps to the 16 bed slots")

  stubHAL.devices[101]!.inputChannels = 1
  engine.checkWatchdogTick()
  require(engine.currentStatus.phase == .error, "One input channel stops with a clear message")
  require(engine.currentStatus.message.contains("at least two"), "Message names the minimum")
  require(stubHAL.units.isEmpty && stubHAL.disposalCount == 10, "All replaced units disposed")

  stubHAL.reset()
  stubHAL.devices[101]!.rate = 1_000
  let unsupported = AudioEngine(queue: checkQueue)
  do {
    try unsupported.start(
      inputDeviceID: 101, outputDeviceID: 201, configuration: .init(), framesPerBuffer: 128)
    preconditionFailure("An out-of-range input rate must be refused")
  } catch {
    require(
      unsupported.currentStatus.message.contains("8–768 kHz"),
      "Refusal names the supported band")
    require(stubHAL.units.isEmpty, "Refused rates create no unit")
  }

  // The DAC's rate list is the limit: without 96 kHz it falls back and says so.
  stubHAL.reset()
  stubHAL.devices[101]!.rate = 96_000
  stubHAL.devices[201]!.availableRates = [44_100, 48_000]
  let limited = try startEngine()
  require(
    limited.currentStatus.phase == .running && limited.checkHasRateConverter,
    "A limited output converts the source to its own rate")
  require(
    limited.checkInputRate == 96_000 && limited.currentStatus.renderSampleRate == 48_000,
    "The source stays 96 kHz and the render falls back to 48 kHz")
  require(
    limited.currentStatus.message.contains("output limit"),
    "The status names the output limit: \(limited.currentStatus.message)")
  require(
    stubHAL.units.values.first { !$0.isInput }!.client.mSampleRate == 48_000,
    "The fallback output client is 48 kHz")
  limited.stop()

  // A limited output while starting at 44.1 kHz: input converted to the 48 kHz fallback.
  stubHAL.reset()
  stubHAL.devices[101]!.rate = 44_100
  stubHAL.devices[201]!.availableRates = [48_000]
  let converted = try startEngine()
  require(
    converted.currentStatus.renderSampleRate == 48_000 && converted.checkHasRateConverter,
    "A 48 kHz-only output converts the 44.1 kHz source")
  for _ in 0..<12 { require(stubHAL.inputCallback(frames: 512) == noErr, "fallback renders") }
  converted.checkWatchdogTick()
  require(converted.currentStatus.phase == .running, "Fallback keeps rendering")
  converted.stop()

  // An output rate changed elsewhere is restored to the passthrough rate.
  stubHAL.reset()
  let restored = try startEngine()
  require(stubHAL.devices[201]!.rate == 48_000, "Output starts at the source rate")
  let unitsBeforeOutputDrift = Set(stubHAL.units.keys)
  stubHAL.devices[201]!.rate = 44_100
  restored.checkWatchdogTick()
  require(
    unitsBeforeOutputDrift.isDisjoint(with: stubHAL.units.keys),
    "Output-rate restoration rebuilds device-side timing even if the client rate stays 48 kHz")
  require(
    restored.currentStatus.phase == .running && stubHAL.devices[201]!.rate == 48_000,
    "A drifted output rate is restored instead of stopping")
  restored.stop()
  require(restored.currentStatus.inputSampleRate == nil, "Stopped status clears the rate")

  stubHAL.reset()
  stubHAL.devices[201]!.rate = 44_100
  let keepAlive = try startEngine(keepAlive: true)
  require(keepAlive.currentStatus.phase == .keepAlive, "Keep-alive accepts any output rate")
  require(
    stubHAL.units.values.first { !$0.isInput }!.client.mSampleRate == 44_100,
    "Keep-alive keeps the output device rate")
  keepAlive.stop()
  print(
    "PASS: actual-engine passthrough rate/width reopen, output matching, limits and keep-alive")
}

/// A fresh client ASBD is not sufficient when an AUHAL/driver retains device-side
/// conversion state. Pump valid output buffers as well as input, including repeated
/// returns to 48 kHz, and assert sustained delivery rather than just matching metadata.
func rateTransitionDeliveryChecks() throws {
  stubHAL.reset()
  stubHAL.devices[101]!.rate = 44_100
  let engine = try startEngine()
  stubHAL.inputValues = [0.05, 0.05] + [Float](repeating: 0, count: 14)
  for rate in [44_100.0, 48_000, 44_100, 48_000, 96_000, 48_000] {
    engine.checkRequestInputRate(rate)
    engine.checkWatchdogTick()
    for _ in 0..<3_000 {
      require(stubHAL.inputCallback(frames: 128) == noErr, "Clocked input renders")
      _ = stubHAL.clockedOutputCallback(deviceFrames: 128)
    }
    let samples = stubHAL.clockedOutputCallback(deviceFrames: 128)
    engine.checkWatchdogTick()
    require(engine.currentStatus.phase == .running, "Clocked pipeline stays running")
    require(
      engine.currentStatus.diagnostics.underrunCount == 0, "No sustained starvation at \(rate)")
    require(engine.currentStatus.diagnostics.overrunCount == 0, "No producer overflow at \(rate)")
    require(
      samples.allSatisfy { $0.isFinite && $0 > 0.01 && $0 < 0.1 },
      "Stereo signal reaches every output sample at \(rate), without silence or clipping")
  }
  engine.stop()

  for failure in ["disposal", "retained-disposal", "initialize", "cancel"] {
    stubHAL.reset()
    let gate = AudioRenderGate()
    let engine = try startEngine(gate: gate)
    let nextUnit = stubHAL.nextUnit
    if failure == "disposal" { stubHAL.disposalFailures = 1 }
    if failure == "retained-disposal" { stubHAL.disposalFailures = 3 }
    if failure == "initialize" { stubHAL.initializeFailure = kAudioUnitErr_FailedInitialization }
    if failure == "cancel" { stubHAL.disposalProbe = { gate.close() } }
    engine.checkRequestInputRate(44_100)
    engine.checkWatchdogTick()
    if failure == "cancel" {
      require(stubHAL.units.values.allSatisfy { !$0.started }, "Cancelled replacement never starts")
      require(!gate.isOpen, "Replacement never reopens the one-way cancellation gate")
      engine.stop()
    } else {
      require(engine.currentStatus.phase == .error, "Failed replacement stops safely: \(failure)")
      if failure == "retained-disposal" {
        require(stubHAL.units.count == 2, "Failed disposal retains both old units")
        require(engine.checkStorageAllocated, "Callback storage retained until disposal succeeds")
        require(stubHAL.nextUnit == nextUnit, "No fresh units while old callbacks remain reachable")
        require(!gate.isOpen, "Failed replacement mutes late callbacks")
        engine.stop()  // Retry disposal, now successful.
      }
      require(stubHAL.units.isEmpty, "Failed replacement cleans up: \(failure)")
      require(!engine.checkStorageAllocated, "Storage released after disposal: \(failure)")
      if failure == "disposal" {
        require(stubHAL.nextUnit == nextUnit, "No new unit or storage before old disposal succeeds")
      }
    }
  }
  print("PASS: clocked rate-transition signal delivery and replacement failure/cancellation")
}

/// Matching the input device to a Music track rate is best-effort: the device is only
/// changed while rendering, only to an advertised rate, and never for keep-alive.
func inputRateRequestChecks() throws {
  stubHAL.reset()
  let engine = try startEngine()
  require(stubHAL.devices[101]!.rate == 48_000, "Starts at the device rate")
  engine.checkRequestInputRate(96_000)
  require(stubHAL.devices[101]!.rate == 96_000, "The requested rate reaches the device")
  engine.checkWatchdogTick()
  require(engine.currentStatus.phase == .running, "A rate request keeps rendering")
  require(engine.checkInputRate == 96_000, "The input reopens at the requested rate")
  require(
    stubHAL.units.values.first { $0.isInput }!.client.mSampleRate == 96_000,
    "The input client format follows the requested rate")
  require(
    stubHAL.devices[201]!.rate == 96_000
      && stubHAL.units.values.first { !$0.isInput }!.client.mSampleRate == 96_000,
    "The output device and client follow the matched rate")
  require(
    abs((engine.currentStatus.inputSampleRate ?? 0) - 96_000) < 0.5,
    "Status reports the matched rate")
  require(!engine.checkHasRateConverter, "Matching at 96 kHz is passthrough")

  engine.checkRequestInputRate(128_000)
  require(stubHAL.devices[101]!.rate == 96_000, "An unavailable rate is never applied")
  engine.checkWatchdogTick()
  require(engine.currentStatus.phase == .running, "A refused rate does not stop the run")

  engine.checkRequestInputRate(44_100)
  engine.checkWatchdogTick()
  require(
    engine.checkInputRate == 44_100 && !engine.checkHasRateConverter,
    "A lower advertised rate is matched and passthrough")
  require(stubHAL.devices[201]!.rate == 44_100, "The output follows the lower rate")
  engine.stop()

  stubHAL.reset()
  let keepAlive = try startEngine(keepAlive: true)
  keepAlive.checkRequestInputRate(96_000)
  require(stubHAL.devices[201]!.rate == 48_000, "Keep-alive never changes a device rate")
  keepAlive.stop()

  stubHAL.reset()
  let runGate = AudioRenderGate()
  let guarded = try startEngine(gate: runGate)
  let policyGate = AudioRateRequest()
  policyGate.close()
  guarded.checkRequestInputRate(
    88_200, requestGate: AudioRateRequest(expiresAt: Date().addingTimeInterval(-1)))
  require(stubHAL.devices[101]!.rate == 48_000, "Expired decoder evidence cannot change actual HAL")
  guarded.checkRequestInputRate(96_000, requestGate: policyGate)
  require(
    stubHAL.devices[101]!.rate == 48_000, "A revoked policy cannot change the actual HAL device")
  runGate.close()
  guarded.checkRequestInputRate(96_000)
  require(
    stubHAL.devices[101]!.rate == 48_000, "Immediate Stop gate blocks rates before queued teardown")
  guarded.stop()

  stubHAL.reset()
  let stopped = AudioEngine(queue: checkQueue)
  stopped.checkRequestInputRate(96_000)
  require(stubHAL.devices[101]!.rate == 48_000, "A stopped engine never changes system audio")
  print("PASS: actual-engine input rate requests for Music matching")
}

func outputBitDepthChecks() throws {
  // Pure selection: deepest LPCM at the rate and width; integer wins a tie with float.
  func ranged(
    _ bits: UInt32, rate: Double = 0, channels: UInt32 = 2, float: Bool = false,
    range: (Double, Double) = (44_100, 384_000)
  ) -> AudioStreamRangedDescription {
    var format = stubIntegerFormat(rate: rate, channels: channels, bits: bits)
    if float { format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked }
    return AudioStreamRangedDescription(
      mFormat: format, mSampleRateRange: AudioValueRange(mMinimum: range.0, mMaximum: range.1))
  }
  let mixed = [
    ranged(16), ranged(24), ranged(32, float: true), ranged(32), ranged(64, channels: 4),
    ranged(48, rate: 48_000),
  ]
  let best = DeviceManager.deepestPhysicalFormat(in: mixed, rate: 96_000, channels: 2)
  require(best?.mBitsPerChannel == 32, "Deepest stereo format at the rate is chosen")
  require(
    best.map { $0.mFormatFlags & kAudioFormatFlagIsFloat == 0 } == true,
    "Integer wins a depth tie with float")
  require(best?.mSampleRate == 96_000, "A ranged entry is pinned to the requested rate")
  require(
    DeviceManager.deepestPhysicalFormat(in: mixed, rate: 48_000, channels: 2)?.mBitsPerChannel
      == 48,
    "An exact-rate entry only counts at its rate")
  require(
    DeviceManager.deepestPhysicalFormat(
      in: [ranged(24, range: (44_100, 48_000))], rate: 96_000, channels: 2) == nil,
    "Formats outside their rate range are excluded")
  var compressed = ranged(32)
  compressed.mFormat.mFormatID = kAudioFormatAC3
  require(
    DeviceManager.deepestPhysicalFormat(in: [compressed, ranged(16)], rate: 96_000, channels: 2)?
      .mBitsPerChannel == 16,
    "Only linear PCM qualifies")

  // Actual engine: a DAC left at 16-bit is moved to its deepest format on start.
  stubHAL.reset()
  stubHAL.devices[101]!.rate = 96_000
  let engine = try startEngine()
  require(stubHAL.devices[201]!.rate == 96_000, "Output follows the input rate")
  require(stubHAL.devices[201]!.physicalBits == 32, "16-bit DAC format is raised to 32-bit")
  require(stubHAL.devices[201]!.physicalFormatWrites == 1, "One physical format write")
  require(
    engine.currentStatus.outputPhysicalFormat?.bits == 32
      && engine.currentStatus.outputPhysicalFormat?.isFloat == false,
    "Status reports the DAC's 32-bit integer format")
  // A rate reopen re-applies the policy without redundant writes.
  stubHAL.devices[101]!.rate = 44_100
  _ = stubHAL.inputCallback(frames: 512)
  engine.checkWatchdogTick()
  require(engine.currentStatus.renderSampleRate == 44_100, "Rate change reopens the pipeline")
  require(stubHAL.devices[201]!.physicalBits == 32, "Depth survives a rate change")
  require(
    stubHAL.devices[201]!.physicalFormatWrites == 1, "Already-deepest format is not rewritten")
  engine.stop()
  require(engine.currentStatus.outputPhysicalFormat == nil, "Stopped status reports no format")

  // A DAC that refuses the change keeps rendering at its own depth, and reports it.
  stubHAL.reset()
  stubHAL.devices[201]!.physicalFormatSettable = false
  let refused = try startEngine()
  require(refused.currentStatus.phase == .running, "A refused depth change never stops audio")
  require(stubHAL.devices[201]!.physicalBits == 16, "Unsettable format is left alone")
  require(refused.currentStatus.outputPhysicalFormat?.bits == 16, "The real depth is reported")
  refused.stop()

  // Nothing deeper offered: no write. Keep-alive never touches the DAC format.
  stubHAL.reset()
  stubHAL.devices[201]!.availableBits = [16]
  let shallow = try startEngine()
  require(stubHAL.devices[201]!.physicalFormatWrites == 0, "No deeper format means no write")
  shallow.stop()
  stubHAL.reset()
  let keepAlive = try startEngine(keepAlive: true)
  require(stubHAL.devices[201]!.physicalFormatWrites == 0, "Keep-alive leaves the DAC format")
  keepAlive.stop()
  // Match-source: exact depth when offered, else the nearest deeper, else the deepest.
  let offered = [ranged(16), ranged(24), ranged(32), ranged(32, float: true)]
  func pick(_ bits: Int?) -> UInt32? {
    DeviceManager.physicalFormat(in: offered, rate: 96_000, channels: 2, preferredBits: bits)?
      .mBitsPerChannel
  }
  require(pick(16) == 16 && pick(24) == 24 && pick(32) == 32, "Offered depths match exactly")
  require(pick(20) == 24, "An unoffered depth takes the nearest deeper format")
  require(pick(48) == 32, "A depth deeper than any offered takes the deepest")
  require(pick(nil) == 32, "Unknown source depth takes the deepest")
  require(
    DeviceManager.physicalFormat(in: offered, rate: 96_000, channels: 2, preferredBits: 32)
      .map { $0.mFormatFlags & kAudioFormatFlagIsFloat == 0 } == true,
    "Integer wins the exact-depth tie")

  // Actual engine: a known source depth is applied at once, kept across a rate reopen,
  // and released back to the deepest when the source depth becomes unknown.
  stubHAL.reset()
  stubHAL.devices[101]!.rate = 96_000
  let matching = try startEngine()
  require(stubHAL.devices[201]!.physicalBits == 32, "Start uses the deepest before evidence")
  matching.requestOutputBitDepth(24)
  require(stubHAL.devices[201]!.physicalBits == 24, "A 24-bit source sets the DAC to 24-bit")
  require(
    matching.currentStatus.outputPhysicalFormat?.bits == 24, "Status reports the matched depth")
  matching.requestOutputBitDepth(16)
  require(stubHAL.devices[201]!.physicalBits == 16, "A 16-bit source sets the DAC to 16-bit")
  stubHAL.devices[101]!.rate = 44_100
  _ = stubHAL.inputCallback(frames: 512)
  matching.checkWatchdogTick()
  require(matching.currentStatus.renderSampleRate == 44_100, "Rate change reopens")
  require(stubHAL.devices[201]!.physicalBits == 16, "The source depth survives the reopen")
  let writes = stubHAL.devices[201]!.physicalFormatWrites
  matching.requestOutputBitDepth(16)
  require(stubHAL.devices[201]!.physicalFormatWrites == writes, "Repeated depth is not rewritten")
  matching.requestOutputBitDepth(nil)
  require(stubHAL.devices[201]!.physicalBits == 32, "Unknown depth returns to the deepest")
  matching.stop()
  stubHAL.reset()
  let idle = try startEngine(keepAlive: true)
  idle.requestOutputBitDepth(16)
  require(stubHAL.devices[201]!.physicalFormatWrites == 0, "Keep-alive ignores depth requests")
  idle.stop()
  print(
    "PASS: DAC bit depth: deepest/exact/nearest-deeper selection, live apply, reopen, refusal, keep-alive"
  )
}

checkQueue.async {
  do {
    routeChecks()
    unsafeStartChecks()
    try watchdogChecks()
    try nilOutputChecks()
    try bedLayoutChecks()
    try deviceRateAndWidthChecks()
    try rateTransitionDeliveryChecks()
    try inputRateRequestChecks()
    try outputBitDepthChecks()
    try cleanupChecks()
    print("All isolated HAL checks passed (no hardware or system routes touched)")
    exit(0)
  } catch {
    fatalError("HAL check failed: \(error)")
  }
}
dispatchMain()
