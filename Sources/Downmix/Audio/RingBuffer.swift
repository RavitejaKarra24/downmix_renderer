import Foundation
import Synchronization

/// Single-producer / single-consumer lock-free float ring buffer.
final class FloatRingBuffer: @unchecked Sendable {
  private let capacity: Int
  private let storage: UnsafeMutablePointer<Float>
  private let readIndex = Atomic<Int>(0)
  private let writeIndex = Atomic<Int>(0)

  init(capacity: Int) {
    // +1 distinguishes full vs empty.
    self.capacity = max(capacity + 1, 64)
    storage = .allocate(capacity: self.capacity)
    storage.initialize(repeating: 0, count: self.capacity)
  }

  deinit {
    storage.deinitialize(count: capacity)
    storage.deallocate()
  }

  var availableToRead: Int {
    let write = writeIndex.load(ordering: .acquiring)
    let read = readIndex.load(ordering: .relaxed)
    if write >= read { return write - read }
    return capacity - read + write
  }

  var availableToWrite: Int {
    capacity - 1 - availableToRead
  }

  @discardableResult
  func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
    let writable = min(count, availableToWrite)
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
    let readable = min(count, availableToRead)
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

  func clear() {
    readIndex.store(0, ordering: .relaxed)
    writeIndex.store(0, ordering: .relaxed)
    storage.update(repeating: 0, count: capacity)
  }
}
