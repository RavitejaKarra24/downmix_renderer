import AppKit

/// Opens the rotating diagnostics log. Kept out of the logger so the log itself stays
/// usable from headless checks that never link a UI framework.
enum DiagnosticLogActions {
  static func reveal() {
    let log = DownmixLog.shared
    let url = log.fileURL
    if FileManager.default.fileExists(atPath: url.path) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
      try? FileManager.default.createDirectory(
        at: log.directory, withIntermediateDirectories: true)
      NSWorkspace.shared.open(log.directory)
    }
  }
}
