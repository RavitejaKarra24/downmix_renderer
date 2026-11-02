import Foundation
import Synchronization

/// One-way cancellation for a single run. Main may close it while HAL setup blocks.
/// Callbacks only load this atomic; they never lock or access UI/control state.
/// Retain the gate with callback resources until both units are disposed.
final class AudioRenderGate: Sendable {
  private let open = Atomic<Bool>(true)

  var isOpen: Bool { open.load(ordering: .acquiring) }

  func close() {
    open.store(false, ordering: .releasing)
  }
}

/// Control-side policy authorization, never used in render callbacks. Unlike the
/// audio run gate it can expire: queued decoder evidence must still be fresh at
/// the final HAL write, even while the main queue or a HAL query is blocked.
final class AudioRateRequest: Sendable {
  private let gate = AudioRenderGate()
  private let deadline: ContinuousClock.Instant?

  init(expiresAt: Date? = nil) {
    deadline = expiresAt.map { date in
      let remaining = date.timeIntervalSinceNow
      return .now.advanced(by: .seconds(remaining.isFinite ? max(0, remaining) : 0))
    }
  }

  var isOpen: Bool {
    gate.isOpen && (deadline.map { ContinuousClock.now < $0 } ?? true)
  }

  func close() { gate.close() }
}
