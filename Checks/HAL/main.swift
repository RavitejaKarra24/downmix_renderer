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
    ("input channels", { stubHAL.devices[101]!.inputChannels = 8 }),
    ("output channels", { stubHAL.devices[201]!.outputChannels = 1 }),
    ("input nominal rate", { stubHAL.devices[101]!.rate = 44_100 }),
    ("output nominal rate", { stubHAL.devices[201]!.rate = 96_000 }),
    (
      "input unit device rate",
      {
        let unit = stubHAL.units.first { $0.value.isInput }!.key
        stubHAL.units[unit]!.hardwareRate = 44_100
      }
    ),
    (
      "output unit device rate",
      {
        let unit = stubHAL.units.first { !$0.value.isInput }!.key
        stubHAL.units[unit]!.hardwareRate = 44_100
      }
    ),
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
    ("input physical stream rate", { stubHAL.devices[101]!.physicalRate = 44_100 }),
    ("output virtual stream rate", { stubHAL.devices[201]!.virtualRate = 44_100 }),
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
  stubHAL.devices[101]!.inputChannels = 16
  wider.checkWatchdogTick()
  require(
    wider.currentStatus.phase == .error, "Topology checked against negotiated 32, not fixed 16")
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

checkQueue.async {
  do {
    routeChecks()
    unsafeStartChecks()
    try watchdogChecks()
    try nilOutputChecks()
    try cleanupChecks()
    print("All isolated HAL checks passed (no hardware or system routes touched)")
    exit(0)
  } catch {
    fatalError("HAL check failed: \(error)")
  }
}
dispatchMain()
