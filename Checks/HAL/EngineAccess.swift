// Appended to an unchanged temporary copy of AudioEngine.swift by check_hal.sh.
// Private access only; all setup, watchdog, callbacks and teardown are product code.
extension AudioEngine {
  func checkWatchdogTick() { pollStatus() }

  func checkCancelTimer() {
    meterTimer?.cancel()
    meterTimer = nil
  }

  var checkStorageAllocated: Bool {
    outputRenderer != nil && (keepAliveOnly || (!inputData.isEmpty && ring != nil))
  }
}
