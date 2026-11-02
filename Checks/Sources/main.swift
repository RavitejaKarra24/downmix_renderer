import CoreAudio
import Darwin
import Foundation
import Synchronization

private struct Client: Sendable {
  var object: UInt32
  var pid: Int32?
  var running: UInt32?
  var devices: [UInt32]?
  var bundle: String?
}

private struct Scenario: Sendable {
  var name: String
  var clients: [Client] = []
  var discoveryFails = false
  var malformedList = false
  var growOnce = false
  var alive: UInt32 = 1
  var expectedPIDs: [Int32] = []
  var expectedAvailable = true
}

private struct FakeState {
  var scenario = Scenario(name: "unset")
  var reads = 0
  var listReads = 0
  var outputScopesOnly = true
}

private let fake = Mutex(FakeState())
private let selected: UInt32 = 900

// These same-module functions shadow the imported HAL functions for this test
// executable ONLY. The unmodified production file is compiled beside this file.
// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioObjectHasProperty(
  _ object: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>
) -> Bool {
  precondition(!Thread.isMainThread, "HAL must not run on main")
  return true
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioObjectGetPropertyDataSize(
  _ object: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
  _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>
) -> OSStatus {
  precondition(!Thread.isMainThread)
  return fake.withLock { state in
    state.reads += 1
    let selector = address.pointee.mSelector
    if selector == kAudioHardwarePropertyProcessObjectList {
      if state.scenario.discoveryFails { return kAudioHardwareUnspecifiedError }
      size.pointee = state.scenario.malformedList ? 3 : UInt32(state.scenario.clients.count * 4)
      return noErr
    }
    if selector == kAudioProcessPropertyDevices {
      state.outputScopesOnly =
        state.outputScopesOnly && address.pointee.mScope == kAudioObjectPropertyScopeOutput
      guard let client = state.scenario.clients.first(where: { $0.object == object }),
        let devices = client.devices
      else { return kAudioHardwareUnknownPropertyError }
      size.pointee = UInt32(devices.count * 4)
      return noErr
    }
    return kAudioHardwareUnknownPropertyError
  }
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func AudioObjectGetPropertyData(
  _ object: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
  _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>,
  _ output: UnsafeMutableRawPointer
) -> OSStatus {
  precondition(!Thread.isMainThread)
  return fake.withLock { state in
    state.reads += 1
    func scalar(_ value: UInt32?) -> OSStatus {
      guard let value else { return kAudioHardwareUnknownPropertyError }
      output.storeBytes(of: value, as: UInt32.self)
      size.pointee = 4
      return noErr
    }
    func list(_ values: [UInt32]) -> OSStatus {
      guard Int(size.pointee) >= values.count * 4 else { return kAudioHardwareBadPropertySizeError }
      for (index, value) in values.enumerated() {
        output.storeBytes(of: value, toByteOffset: index * 4, as: UInt32.self)
      }
      size.pointee = UInt32(values.count * 4)
      return noErr
    }
    switch address.pointee.mSelector {
    case kAudioDevicePropertyDeviceIsAlive:
      return scalar(state.scenario.alive)
    case kAudioHardwarePropertyProcessObjectList:
      state.listReads += 1
      if state.scenario.growOnce && state.listReads == 1 {
        return kAudioHardwareBadPropertySizeError
      }
      return list(state.scenario.clients.map(\.object))
    default:
      guard let client = state.scenario.clients.first(where: { $0.object == object }) else {
        return kAudioHardwareBadObjectError
      }
      switch address.pointee.mSelector {
      case kAudioProcessPropertyPID: return scalar(client.pid.map { UInt32(bitPattern: $0) })
      case kAudioProcessPropertyIsRunningOutput: return scalar(client.running)
      case kAudioProcessPropertyDevices:
        state.outputScopesOnly =
          state.outputScopesOnly && address.pointee.mScope == kAudioObjectPropertyScopeOutput
        guard let devices = client.devices else { return kAudioHardwareUnknownPropertyError }
        return list(devices)
      case kAudioProcessPropertyBundleID:
        guard let bundle = client.bundle else { return kAudioHardwareUnknownPropertyError }
        output.storeBytes(
          of: Unmanaged.passRetained(bundle as CFString), as: Unmanaged<CFString>.self)
        size.pointee = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        return noErr
      default: return kAudioHardwareUnknownPropertyError
      }
    }
  }
}

@main
private struct SourceMonitorChecks {
  static func main() {
    let active = Client(
      object: 100, pid: 1_500_001, running: 1, devices: [selected], bundle: "Zeta App")
    let scenarios: [Scenario] = [
      Scenario(name: "empty discovery"),
      Scenario(name: "discovery failure", discoveryFails: true, expectedAvailable: false),
      Scenario(name: "malformed list", malformedList: true, expectedAvailable: false),
      Scenario(name: "dead selected device", alive: 0, expectedAvailable: false),
      Scenario(name: "active route", clients: [active], expectedPIDs: [1_500_001]),
      Scenario(
        name: "list grows and retries", clients: [active], growOnce: true, expectedPIDs: [1_500_001]
      ),
      Scenario(
        name: "missing activity on selected route",
        clients: [Client(object: 100, pid: 1_500_001, running: nil, devices: [selected])],
        expectedAvailable: false),
      Scenario(
        name: "missing devices while active",
        clients: [Client(object: 100, pid: 1_500_001, running: 1, devices: nil)],
        expectedAvailable: false),
      Scenario(
        name: "both metadata unreadable",
        clients: [Client(object: 100, pid: 1_500_001, running: nil, devices: nil)],
        expectedAvailable: false),
      Scenario(
        name: "missing PID while relevant",
        clients: [Client(object: 100, pid: nil, running: 1, devices: [selected])],
        expectedAvailable: false),
      Scenario(
        name: "inactive with unreadable devices",
        clients: [Client(object: 100, pid: nil, running: 0, devices: nil)]),
      Scenario(
        name: "other route with unreadable activity",
        clients: [Client(object: 100, pid: nil, running: nil, devices: [901])]),
      Scenario(
        name: "empty output list",
        clients: [Client(object: 100, pid: 1_500_001, running: 1, devices: [])]),
      Scenario(
        name: "own PID excluded even with unreadable metadata",
        clients: [Client(object: 100, pid: getpid(), running: nil, devices: nil)]),
      Scenario(
        name: "Another Downmix PID is not the renderer itself",
        clients: [
          Client(
            object: 100, pid: 1_500_002, running: 1, devices: [selected],
            bundle: "com.local.downmix")
        ], expectedPIDs: [1_500_002]),
      Scenario(
        name: "missing display metadata is safe",
        clients: [Client(object: 100, pid: 1_500_001, running: 1, devices: [selected])],
        expectedPIDs: [1_500_001]),
      Scenario(
        name: "known source plus uncertain client",
        clients: [active, Client(object: 101, pid: 1_500_002, running: 1, devices: nil)],
        expectedPIDs: [1_500_001], expectedAvailable: false),
      Scenario(
        name: "deduplicate PID and sort by name",
        clients: [
          active,
          Client(object: 101, pid: 1_500_001, running: 1, devices: [selected], bundle: "Zeta App"),
          Client(object: 102, pid: 1_500_002, running: 1, devices: [selected], bundle: "Alpha App"),
        ], expectedPIDs: [1_500_002, 1_500_001]),
    ]
    run(scenarios, index: 0)
    RunLoop.main.run(until: Date().addingTimeInterval(20))
    fatalError("Source monitor checks timed out")
  }

  static func run(_ scenarios: [Scenario], index: Int) {
    precondition(Thread.isMainThread)
    guard index < scenarios.count else {
      print("PASS \(scenarios.count) simulated HAL scenarios; production file unmodified")
      exit(0)
    }
    let scenario = scenarios[index]
    fake.withLock { $0 = FakeState(scenario: scenario) }
    let monitor = AudioSourceMonitor()
    monitor.start(inputDeviceID: selected) { observation in
      precondition(Thread.isMainThread)
      precondition(observation.isAvailable == scenario.expectedAvailable, scenario.name)
      precondition(observation.sources.map(\.id) == scenario.expectedPIDs, scenario.name)
      fake.withLock {
        precondition($0.reads > 0 && $0.outputScopesOnly, scenario.name)
        if scenario.growOnce { precondition($0.listReads == 2) }
      }
      monitor.stop()
      print("PASS \(scenario.name)")
      DispatchQueue.main.async { run(scenarios, index: index + 1) }
    }
  }
}
