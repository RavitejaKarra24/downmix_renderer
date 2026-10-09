import Foundation
import Synchronization

/// Single-producer / single-consumer lock-free interleaved stereo float ring buffer.
/// Counts are in samples; transfers round down to complete two-sample frames.
/// Overflow drops the unwritten suffix, never half a stereo frame.
final class FloatRingBuffer: @unchecked Sendable {
  private let capacity: Int
  private let storage: UnsafeMutablePointer<Float>
  private let readIndex = Atomic<Int>(0)
  private let writeIndex = Atomic<Int>(0)

  init(capacity: Int) {
    precondition(capacity < Int.max, "Ring capacity must leave room for the sentinel")
    // At least one stereo frame, with an even usable capacity. +1 marks full vs empty.
    let usableCapacity = max(capacity, 2) / 2 * 2
    self.capacity = usableCapacity + 1
    storage = .allocate(capacity: self.capacity)
    storage.initialize(repeating: 0, count: self.capacity)
  }

  deinit {
    storage.deinitialize(count: capacity)
    storage.deallocate()
  }

  /// Consumer-side snapshot (not a transactional snapshot for a third observer).
  var availableToRead: Int {
    let write = writeIndex.load(ordering: .acquiring)
    let read = readIndex.load(ordering: .relaxed)
    if write >= read { return write - read }
    return capacity - read + write
  }

  /// Producer-side snapshot. Acquire the consumer's release before reusing storage.
  var availableToWrite: Int {
    let read = readIndex.load(ordering: .acquiring)
    let write = writeIndex.load(ordering: .relaxed)
    let used = write >= read ? write - read : capacity - read + write
    return capacity - 1 - used
  }

  @discardableResult
  func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
    guard count > 0 else { return 0 }
    let writable = min(count / 2 * 2, availableToWrite)
    if writable == 0 { return 0 }

    let currentWrite = writeIndex.load(ordering: .relaxed)
    let first = min(writable, capacity - currentWrite)
    storage.advanced(by: currentWrite).update(from: source, count: first)
    let second = writable - first
    if second > 0 {
      storage.update(from: source.advanced(by: first), count: second)
    }
    writeIndex.store((currentWrite + writable) % capacity, ordering: .releasing)
    return writable
  }

  @discardableResult
  func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
    guard count > 0 else { return 0 }
    let readable = min(count / 2 * 2, availableToRead)
    if readable == 0 { return 0 }

    let currentRead = readIndex.load(ordering: .relaxed)
    let first = min(readable, capacity - currentRead)
    destination.update(from: storage.advanced(by: currentRead), count: first)
    let second = readable - first
    if second > 0 {
      destination.advanced(by: first).update(from: storage, count: second)
    }
    readIndex.store((currentRead + readable) % capacity, ordering: .releasing)
    return readable
  }

  /// Call only after both producer and consumer have stopped.
  func clear() {
    readIndex.store(0, ordering: .relaxed)
    writeIndex.store(0, ordering: .relaxed)
  }
}
