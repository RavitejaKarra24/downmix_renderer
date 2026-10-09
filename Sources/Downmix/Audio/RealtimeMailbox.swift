import Synchronization

/// Bounded latest-value transport for exactly one producer and one consumer.
///
/// Each side exclusively owns one slot; the atomic middle owns the third. Only
/// an acquiring/releasing exchange transfers ownership, including permission to
/// reuse storage. The producer never writes the consumer's slot, even while a
/// returned value is being copied. Intermediate publications may be overwritten.
///
/// `publish` calls must not overlap other producer calls, and `consumeLatest`
/// calls must not overlap other consumer calls. Both owners must be quiescent
/// before destruction (or before transferring their role to another thread).
/// The unchecked Sendable conformance relies on these SPSC/lifetime invariants.
/// `BitwiseCopyable` excludes Array and reference-backed payloads: hot paths only
/// copy POD storage, with no locks, retry loops, allocation, or payload ARC.
final class RealtimeMailbox<Value: BitwiseCopyable & Sendable>: @unchecked Sendable {
  private let storage: UnsafeMutablePointer<Value>
  // Low two bits are the slot index; bit 2 marks an unconsumed publication.
  private let middle = Atomic<Int>(1)
  private var writeIndex = 2  // Producer-only state.
  private var readIndex = 0  // Consumer-only state.

  /// Initializes all slots, but does not mark the initial value as a publication.
  init(_ initialValue: Value) {
    storage = .allocate(capacity: 3)
    storage.initialize(repeating: initialValue, count: 3)
  }

  deinit {
    storage.deinitialize(count: 3)
    storage.deallocate()
  }

  /// Producer only. Publishes the newest value, replacing any pending value.
  @inline(__always)
  func publish(_ value: Value) {
    storage[writeIndex] = value
    let previous = middle.exchange(writeIndex | 4, ordering: .acquiringAndReleasing)
    writeIndex = previous & 3
  }

  /// Consumer only. Returns nil if nothing has been published since consumption.
  @inline(__always)
  func consumeLatest() -> Value? {
    guard middle.load(ordering: .acquiring) & 4 != 0 else { return nil }
    // Only this consumer clears dirty. A concurrent producer can only replace
    // the middle with another dirty publication, so no retry is necessary.
    let previous = middle.exchange(readIndex, ordering: .acquiringAndReleasing)
    readIndex = previous & 3
    return storage[readIndex]
  }
}
