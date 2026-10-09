import CoreAudio
import Foundation

/// Immutable HAL results. Safety is scoped to an output identity AND an input UID;
/// a missing certificate fails closed. No UI read performs a Core Audio query.
struct DeviceCatalogSnapshot: Sendable {
  struct Route: Hashable, Sendable {
    let output: AudioDeviceInfo
    let inputUID: String
  }

  let devices: [AudioDeviceInfo]
  let safety: [Route: Bool]

  func isSafeOutput(_ output: AudioDeviceInfo, inputUID: String) -> Bool {
    safety[Route(output: output, inputUID: inputUID)] ?? false
  }

  static func capture(
    inputUID: String,
    catalog: () -> [AudioDeviceInfo],
    routeSafety: (AudioDeviceInfo, String) -> Bool
  ) -> DeviceCatalogSnapshot {
    let devices = catalog()
    // Include saved-but-absent input identities for output-only keep-alive, plus
    // every selectable input so changing selections needs no synchronous HAL read.
    let inputUIDs = Set(devices.filter(\.isInputCapable).map(\.uid) + [inputUID, ""])
    var safety: [Route: Bool] = [:]
    for output in devices where output.isOutputCapable {
      for uid in inputUIDs {
        safety[Route(output: output, inputUID: uid)] = routeSafety(output, uid)
      }
    }
    return DeviceCatalogSnapshot(devices: devices, safety: safety)
  }
}

/// One serial off-main enumeration/safety job at a time, at most one pending job.
/// New requests replace pending work and invalidate already-enqueued main deliveries.
/// Injectable Sendable HAL closures exercise the production bridge without hardware.
@MainActor
final class DeviceCatalogProvider {
  private struct Request: Sendable {
    let id: UInt64
    let inputUID: String
    let completion: @MainActor (DeviceCatalogSnapshot) -> Void
  }

  private let queue: DispatchQueue
  private let catalog: @Sendable () -> [AudioDeviceInfo]
  private let routeSafety: @Sendable (AudioDeviceInfo, String) -> Bool
  private var revision: UInt64 = 0
  private var inFlight = false
  private var pending: Request?

  init(
    queue: DispatchQueue = DispatchQueue(label: "com.local.downmix.device-catalog"),
    catalog: @escaping @Sendable () -> [AudioDeviceInfo] = DeviceManager.allDevices,
    routeSafety: @escaping @Sendable (AudioDeviceInfo, String) -> Bool = DeviceManager
      .isSafeOutputRoute
  ) {
    self.queue = queue
    self.catalog = catalog
    self.routeSafety = routeSafety
  }

  func refresh(
    inputUID: String, completion: @escaping @MainActor (DeviceCatalogSnapshot) -> Void
  ) {
    revision &+= 1
    let request = Request(id: revision, inputUID: inputUID, completion: completion)
    if inFlight {
      pending = request
    } else {
      launch(request)
    }
  }

  private func launch(_ request: Request) {
    inFlight = true
    queue.async { [weak self, catalog, routeSafety] in
      dispatchPrecondition(condition: .notOnQueue(.main))
      let snapshot = DeviceCatalogSnapshot.capture(
        inputUID: request.inputUID, catalog: catalog, routeSafety: routeSafety)
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.inFlight = false
          if request.id == self.revision { request.completion(snapshot) }
          if let next = self.pending {
            self.pending = nil
            self.launch(next)
          }
        }
      }
    }
  }
}
