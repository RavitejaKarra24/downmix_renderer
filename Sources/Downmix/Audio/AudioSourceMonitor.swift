import AppKit
import CoreAudio
import Darwin
import Foundation
import Synchronization

struct AudioPlaybackSource: Identifiable, Equatable, Sendable {
  let id: Int32
  let name: String
  let bundleIdentifier: String?
}

struct AudioSourceObservation: Equatable, Sendable {
  var sources: [AudioPlaybackSource] = []
  var isAvailable: Bool = true
}

/// Call start/stop on the main thread; reports arrive on the main queue.
protocol AudioSourceMonitoring: AnyObject {
  func start(
    inputDeviceID: AudioDeviceID, report: @escaping @Sendable (AudioSourceObservation) -> Void)
  func stop()
}

/// Read-only HAL process discovery, not audio capture. Running output IO does not
/// prove audible content, identify a browser tab, or reveal a source file's rate.
/// The selected input device (e.g. BlackHole) must appear in a client's OUTPUT list.
final class AudioSourceMonitor: AudioSourceMonitoring, Sendable {
  private struct State {
    var generation: UInt64 = 0
    var inputDeviceID: AudioDeviceID?
    var timer: DispatchSourceTimer?
    var lastObservation: AudioSourceObservation?
  }

  // All mutable lifecycle/deduplication state is mutex-protected. HAL and process
  // metadata reads run exclusively on queue, never while holding this mutex.
  private let state = Mutex(State())
  private let queue = DispatchQueue(label: "com.local.downmix.audio-sources", qos: .utility)
  private let ownPID = ProcessInfo.processInfo.processIdentifier

  func start(
    inputDeviceID: AudioDeviceID, report: @escaping @Sendable (AudioSourceObservation) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    state.withLock { state in
      // An idempotent start retains the original callback and timer.
      guard state.inputDeviceID != inputDeviceID else { return }
      state.timer?.cancel()
      state.generation &+= 1
      state.inputDeviceID = inputDeviceID
      state.lastObservation = nil
      let generation = state.generation
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(150))
      timer.setEventHandler { [weak self] in
        self?.poll(inputDeviceID: inputDeviceID, generation: generation, report: report)
      }
      state.timer = timer
      timer.resume()
    }
  }

  func stop() {
    dispatchPrecondition(condition: .onQueue(.main))
    state.withLock { state in
      state.generation &+= 1
      state.inputDeviceID = nil
      state.timer?.cancel()
      state.timer = nil
      state.lastObservation = nil
    }
  }

  deinit {
    state.withLock { $0.timer?.cancel() }
  }

  private func poll(
    inputDeviceID: AudioDeviceID, generation: UInt64,
    report: @escaping @Sendable (AudioSourceObservation) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard state.withLock({ $0.generation == generation && $0.inputDeviceID != nil }) else {
      return
    }
    let observation = autoreleasepool { readObservation(inputDeviceID: inputDeviceID) }
    let shouldReport = state.withLock { state in
      guard state.generation == generation, state.inputDeviceID != nil,
        state.lastObservation != observation
      else { return false }
      state.lastObservation = observation
      return true
    }
    guard shouldReport else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self,
        self.state.withLock({ $0.generation == generation && $0.inputDeviceID != nil })
      else { return }
      // start/stop and delivery share the main queue, so stop cannot interleave
      // between this generation check and the callback. Never call back under lock.
      report(observation)
    }
  }

  private func readObservation(inputDeviceID: AudioDeviceID) -> AudioSourceObservation {
    guard inputDeviceID != kAudioObjectUnknown,
      Self.readUInt32(object: inputDeviceID, selector: kAudioDevicePropertyDeviceIsAlive) == 1,
      let processes = Self.readObjects(
        object: AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyProcessObjectList)
    else { return AudioSourceObservation(isAvailable: false) }

    var observation = AudioSourceObservation()
    var sourcesByPID: [Int32: AudioPlaybackSource] = [:]
    for process in Set(processes).sorted() {
      // PID is a pid_t (Int32); reading its bits uses the same four-byte HAL ABI.
      let pid = Self.readUInt32(object: process, selector: kAudioProcessPropertyPID)
        .map { Int32(bitPattern: $0) }
      if pid == ownPID { continue }
      let running = Self.readUInt32(
        object: process, selector: kAudioProcessPropertyIsRunningOutput)
      if running == 0 { continue }
      let devices = Self.readObjects(
        object: process, selector: kAudioProcessPropertyDevices,
        scope: kAudioObjectPropertyScopeOutput)
      if let devices, !devices.contains(inputDeviceID) { continue }

      // Either known inactivity or a known different route is sufficient to
      // exclude a client. Otherwise missing activity/routing/PID is uncertainty,
      // including process-exit races; retry naturally on the next poll.
      guard running != nil, devices != nil, let pid, pid > 0 else {
        observation.isAvailable = false
        continue
      }
      let app = NSRunningApplication(processIdentifier: pid)
      let bundleID =
        Self.readBundleIdentifier(process: process) ?? Self.nonempty(app?.bundleIdentifier)
      let name = Self.nonempty(app?.localizedName) ?? Self.processName(pid: pid)
      // Missing display metadata is harmless: the PID still identifies the client.
      if sourcesByPID[pid] == nil {
        sourcesByPID[pid] = AudioPlaybackSource(
          id: pid, name: name ?? bundleID ?? "Process \(pid)", bundleIdentifier: bundleID)
      }
    }
    observation.sources = sourcesByPID.values.sorted {
      let order = $0.name.localizedCaseInsensitiveCompare($1.name)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
    return observation
  }

  private static func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  private static func readUInt32(
    object: AudioObjectID, selector: AudioObjectPropertySelector
  ) -> UInt32? {
    var address = address(selector)
    guard AudioObjectHasProperty(object, &address) else { return nil }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard
      AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
      size == MemoryLayout<UInt32>.size
    else { return nil }
    return value
  }

  private static func readObjects(
    object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> [AudioObjectID]? {
    var address = address(selector, scope: scope)
    guard AudioObjectHasProperty(object, &address) else { return nil }
    let stride = UInt32(MemoryLayout<AudioObjectID>.stride)
    // Lists can grow between the size query and read. Retry boundedly rather
    // than presenting a failed/truncated read as an empty or complete list.
    for _ in 0..<3 {
      var size: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
        size % stride == 0
      else { return nil }
      if size == 0 { return [] }
      let capacity = size
      var objects = [AudioObjectID](repeating: 0, count: Int(size / stride))
      let status = objects.withUnsafeMutableBytes { buffer in
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
      }
      if status == noErr, size <= capacity, size % stride == 0 {
        return Array(objects.prefix(Int(size / stride)))
      }
    }
    return nil
  }

  private static func readBundleIdentifier(process: AudioObjectID) -> String? {
    var address = address(kAudioProcessPropertyBundleID)
    guard AudioObjectHasProperty(process, &address) else { return nil }
    // AudioHardware.h explicitly gives the caller ownership of this CFString.
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
      let value
    else { return nil }
    let string = value.takeRetainedValue()
    guard size == MemoryLayout<Unmanaged<CFString>?>.size else { return nil }
    return nonempty(string as String)
  }

  private static func processName(pid: Int32) -> String? {
    var buffer = [UInt8](repeating: 0, count: 1024)
    let count = buffer.withUnsafeMutableBytes {
      proc_name(pid, $0.baseAddress!, UInt32($0.count))
    }
    guard count > 0 else { return nil }
    return nonempty(String(decoding: buffer.prefix(Int(count)).prefix { $0 != 0 }, as: UTF8.self))
  }

  private static func nonempty(_ string: String?) -> String? {
    guard let string else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
