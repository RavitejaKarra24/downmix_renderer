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
