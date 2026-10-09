import AVFoundation
import AppKit
import CoreAudio
import SwiftUI

// Compile the real AudioEngine for coverage; never construct it or query live routes.
private final class UIEngine: AudioEngineControlling {
  struct Start {
    let input: AudioDeviceID
    let output: AudioDeviceID
    let framesPerBuffer: Int
    let keepAliveOnly: Bool
  }
  var starts: [Start] = []
  var stops = 0
  var configurations: [DownmixProcessor.Configuration] = []
  var holdStartup = false
  private var handler: ((EngineStatus) -> Void)?

  func setStatusHandler(_ handler: @escaping (EngineStatus) -> Void) { self.handler = handler }
  func start(
    inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID,
    configuration: DownmixProcessor.Configuration, framesPerBuffer: Int, keepAliveOnly: Bool
  ) throws {
    starts.append(
      Start(
        input: inputDeviceID, output: outputDeviceID,
        framesPerBuffer: framesPerBuffer, keepAliveOnly: keepAliveOnly))
    emit(
      EngineStatus(
        phase: holdStartup ? .starting : (keepAliveOnly ? .keepAlive : .running),
        message: holdStartup ? "Fixture opening" : "Fixture running"))
  }
  func updateConfiguration(_ configuration: DownmixProcessor.Configuration) {
    configurations.append(configuration)
  }
  func stop() {
    stops += 1
    emit(EngineStatus())
  }
  func emit(_ status: EngineStatus) {
    precondition(Thread.isMainThread)
    handler?(status)
  }
}

@MainActor
private final class UIFixture {
  static let input = AudioDeviceInfo(
    id: 101, name: "Fixture 16ch", uid: "fixture-input", inputChannelCount: 16,
    outputChannelCount: 0, nominalSampleRate: 48_000)
  static let alternateInput = AudioDeviceInfo(
    id: 102, name: "Alternate 16ch", uid: "fixture-input-2", inputChannelCount: 16,
    outputChannelCount: 0, nominalSampleRate: 48_000)
  static let output = AudioDeviceInfo(
    id: 201, name: "Fixture Speakers", uid: "fixture-output", inputChannelCount: 0,
    outputChannelCount: 2, nominalSampleRate: 48_000)
  static let alternateOutput = AudioDeviceInfo(
    id: 202, name: "Alternate Speakers", uid: "fixture-output-2", inputChannelCount: 0,
    outputChannelCount: 2, nominalSampleRate: 48_000)
  static let hiddenInput = AudioDeviceInfo(
    id: 103, name: "Hidden Studio", uid: "fixture-input-3", inputChannelCount: 16,
    outputChannelCount: 0, nominalSampleRate: 48_000)
  static let unpinnedInput = AudioDeviceInfo(
    id: 104, name: "Unpinned 16ch", uid: "fixture-input-4", inputChannelCount: 16,
    outputChannelCount: 0, nominalSampleRate: 48_000)
  static let favoriteInputs = [input, alternateInput, hiddenInput, unpinnedInput]
  static let interleavedFavorites = [
    "offline-before", output.uid, input.uid, "offline-middle", hiddenInput.uid,
    alternateOutput.uid, alternateInput.uid, "offline-after",
  ]
  let engine = UIEngine()
  var catalog = [input, alternateInput, output, alternateOutput]
  var permission = AVAuthorizationStatus.authorized
  var permissionRequests = 0
  var permissionReply: ((Bool) -> Void)?
  var enumerations = 0
  var writes: [AppPreferences] = []
  var failWrites = false
  var saveAttempts = 0

  func state() -> AppState {
    var preferences = AppPreferences()
    preferences.inputDeviceUID = Self.input.uid
    preferences.outputDeviceUID = Self.output.uid
    preferences.inputDeviceName = Self.input.name
    preferences.outputDeviceName = Self.output.name
    preferences.autoStart = false
    preferences.keepOutputAlive = false
    return AppState(
      engine: engine, preferences: preferences,
      deviceCatalog: { [self] in
        enumerations += 1
        return catalog
      },
      permissionStatusProvider: { [self] in permission },
      permissionRequestProvider: { [self] reply in
        permissionRequests += 1
        permissionReply = reply
      },
      routeSafetyProvider: { _, _ in true },
      preferenceWriter: { [self] preferences in
        saveAttempts += 1
        if failWrites { throw UIError(description: "Injected save failure") }
        writes.append(preferences)
      },
      installListeners: false)
  }
}

private struct UIError: Error, CustomStringConvertible {
  let description: String
}

@MainActor
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw UIError(description: message) }
}

/// SwiftUI's virtual AccessibilityNode conforms to NSAccessibilityElementProtocol,
/// not the full NSAccessibilityProtocol. Use checked, optional ObjC method lookup
/// for its modern AX methods, never force-cast it to the full protocol or send
/// legacy accessibilityAttributeValue messages to arbitrary children.
@MainActor
private struct NativeAXElement {
  // AppKit toolbar segments can be valid native AX objects without declaring
  // NSAccessibilityElementProtocol. Check their optional modern selectors too.
  let element: AnyObject
  private var object: AnyObject { element }

  func accessibilityIdentifier() -> String? { object.accessibilityIdentifier?() }
  func accessibilityLabel() -> String? { object.accessibilityLabel?() }
  func accessibilityTitle() -> String? { object.accessibilityTitle?() }
  func accessibilityHelp() -> String? { object.accessibilityHelp?() }
  func accessibilityRole() -> NSAccessibility.Role? { object.accessibilityRole?() }
  func isAccessibilityEnabled() -> Bool { object.isAccessibilityEnabled?() ?? false }
  func accessibilityPerformPress() -> Bool { object.accessibilityPerformPress?() ?? false }
  func accessibilityPerformIncrement() -> Bool { object.accessibilityPerformIncrement?() ?? false }
  func accessibilityIncrementButton() -> NativeAXElement? {
    guard let button = object.accessibilityIncrementButton?() else { return nil }
    return NativeAXElement(element: button as AnyObject)
  }
  func accessibilityCustomActions() -> [NSAccessibilityCustomAction] {
    object.accessibilityCustomActions?() ?? []
  }
  func accessibilityFrame() -> NSRect { object.accessibilityFrame?() ?? .zero }
  func accessibilityChildren() -> [Any] {
    // Native segmented tab bars expose their segments through AXTabs rather than
    // AXChildren on some macOS versions. These remain in-process UI descendants.
    (object.accessibilityChildren?() ?? [])
      + (object.accessibilityTabs?() ?? [])
      + (object.accessibilityContents?() ?? [])
  }

  func accessibilityValue() -> Any? {
    if let full = element as? any NSAccessibilityProtocol { return full.accessibilityValue() }
    // ObjC's three accessibilityValue declarations have different Swift result
    // types (String/NSNumber/Any). All return objects. Only this checked getter
    // needs perform; primitive/action returns are handled by typed calls above.
    let selector = NSSelectorFromString("accessibilityValue")
    guard let node = element as? NSObject, node.responds(to: selector) else { return nil }
    return node.perform(selector)?.takeUnretainedValue()
  }
}

/// Traverses only in-process native AX objects. Never requests AX trust.
@MainActor
private func accessibilityTree(_ root: AnyObject) -> [NativeAXElement] {
  var result: [NativeAXElement] = []
  var visited = Set<ObjectIdentifier>()
  func visit(_ element: AnyObject, depth: Int) {
    guard depth < 80, visited.insert(ObjectIdentifier(element)).inserted else { return }
    let native = NativeAXElement(element: element)
    result.append(native)
    for child in native.accessibilityChildren() {
      visit(child as AnyObject, depth: depth + 1)
    }
  }
  visit(root, depth: 0)
  return result
}

@MainActor
private final class HostedWindow {
  let window: NSWindow
  let host: NSHostingView<AnyView>

  init<V: View>(
    _ view: V, state: AppState, rendered: Bool, size: NSSize = NSSize(width: 1040, height: 1800),
    reduceMotion: Bool = false
  ) {
    host = NSHostingView(
      rootView: AnyView(
        // The public Reduce Motion environment is get-only in SDK26.5. This
        // writable SDK shim is fixture-only; never change the user's system setting.
        view.environment(state)
          .environment(\.accessibilityEnabled, true)
          .environment(\._accessibilityReduceMotion, reduceMotion)))
    window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -12000, y: -12000), size: size),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Downmix isolated UI checks"
    window.contentView = host
    if rendered { window.orderFront(nil) }
    settle()
  }

  func settle() {
    // Run SwiftUI observation/tasks and AppKit layout, not a test-side model action.
    let until = Date().addingTimeInterval(0.15)
    repeat {
      host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    } while Date() < until
    host.displayIfNeeded()
  }

  // macOS TabView may place its native tab buttons in the window toolbar,
  // outside NSHostingView's content subtree. Inspect this fixture window only.
  var elements: [NativeAXElement] { accessibilityTree(window) }

  var treeDescription: String {
    elements.map {
      "\($0.accessibilityIdentifier() ?? "-"): \($0.accessibilityRole()?.rawValue ?? "-") label=\($0.accessibilityLabel() ?? "-") title=\($0.accessibilityTitle() ?? "-") value=\(String(describing: $0.accessibilityValue())) [\(type(of: $0.element))]"
    }.joined(separator: "\n")
  }

  func find(_ id: String) throws -> NativeAXElement {
    let matches = elements.filter { $0.accessibilityIdentifier() == id }
    guard matches.count == 1, let element = matches.first else {
      throw UIError(
        description:
          "Expected one rendered AX element '\(id)', found \(matches.count).\n\(treeDescription)")
    }
    return element
  }

  func press(_ id: String) throws {
    try press(find(id))
  }

  func press(_ element: NativeAXElement) throws {
    try require(
      element.isAccessibilityEnabled(),
      "Control must be enabled: \(element.accessibilityIdentifier() ?? element.accessibilityLabel() ?? "unnamed") [\(type(of: element.element))]"
    )
    if let control = element.element as? NSControl {
      // NSSwitch's AX press can dispatch its action while returning false on this
      // OS. Never retry that result and toggle twice: use native performClick.
      control.performClick(nil)
    } else {
      try require(
        element.accessibilityPerformPress(),
        "Native AX press not supported by \(element.accessibilityIdentifier() ?? "control")")
    }
    settle()
  }

  func performAction(_ name: String, on id: String) throws {
    let actions = try find(id).accessibilityCustomActions().filter { $0.name == name }
    try require(actions.count == 1, "Expected one native custom action '\(name)' on \(id)")
    guard let handler = actions.first?.handler else {
      throw UIError(description: "Native custom action '\(name)' has no block handler")
    }
    try require(handler(), "Native custom action '\(name)' must succeed")
    settle()
  }

  func editText(_ id: String, to text: String) throws {
    let element = try find(id)
    // SwiftUI may expose the text-field cell rather than its owning control.
    guard
      let field = (element.element as? NSTextField)
        ?? ((element.element as? NSCell)?.controlView as? NSTextField)
    else {
      throw UIError(
        description: "Expected native NSTextField for \(id), got \(type(of: element.element))")
    }
    // Exercise the AppKit text-edit notification consumed by SwiftUI's delegate,
    // not a test-side write to the view's private search state.
    field.stringValue = text
    NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
    settle()
  }

  func deviceOrder(_ title: String) -> [String] {
    let prefix = "device.\(title.lowercased())."
    return elements.filter {
      $0.accessibilityRole() == .button
        && $0.accessibilityIdentifier()?.hasPrefix(prefix) == true
    }.sorted { $0.accessibilityFrame().minY > $1.accessibilityFrame().minY }
      .compactMap { $0.accessibilityIdentifier().map { String($0.dropFirst(prefix.count)) } }
  }

  func close() {
    window.orderOut(nil)
    window.contentView = nil
    window.close()
  }
}

@main
private struct UIChecks {
  @MainActor
  static func main() {
    do {
      guard let domain = Bundle.main.bundleIdentifier,
        domain.hasPrefix("com.local.downmix.UIchecks.")
      else { throw UIError(description: "Refusing to run outside a unique UI fixture app bundle") }
      // @AppStorage favorites must never resolve the real application's domain.
      UserDefaults.standard.removePersistentDomain(forName: domain)
      defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
      let rendered = CommandLine.arguments.contains("--rendered")
      try require(
        CGSessionCopyCurrentDictionary() != nil,
        "Native UI checks blocked: no logged-in WindowServer session")
      let app = NSApplication.shared
      app.setActivationPolicy(.accessory)
      app.finishLaunching()
      try favoriteOrderingChecks()
      if rendered {
        // SwiftUI lazily creates its virtual AX nodes when an accessibility client
        // enables enhanced UI on the application. Enable it on THIS fixture only,
        // in-process: no AXUIElement, trust request, VoiceOver or system preference.
        app.accessibilitySetValue(
          true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        try contentChecks()
        try favoriteViewChecks()
        try settingsChecks()
        try menuChecks()
        try retryWarmupChecks()
        try persistenceErrorChecks()
        try setupChecks()
        try setupSheetChecks()
        try diagnosticsChecks()
        try reducedMotionChecks()
        print(
          "PASS UI: 11 groups (1 deterministic ordering + 10 rendered native; in-process NSAccessibility actions, fake backend)"
        )
      } else {
        try hostingChecks()
        print("PASS native hosting/layout only; rendered AX/actions NOT run. Use --rendered.")
      }
      print(
        "VoiceOver speech, focus order, physical keyboard and animation behavior require manual validation."
      )
    } catch {
      FileHandle.standardError.write(Data("UI checks FAILED/blocked: \(error)\n".utf8))
      exit(1)
    }
  }

  @MainActor
  private static func hostingChecks() throws {
    let fixture = UIFixture()
    let state = fixture.state()
    for view in [
      AnyView(ContentView()), AnyView(SettingsView()), AnyView(MenuBarView()),
      AnyView(SetupChecklistView()), AnyView(EngineDiagnosticsView()),
      AnyView(MenuBarStatusIcon(source: state.meterSource, isRunning: false)),
    ] {
      let hosted = HostedWindow(view, state: state, rendered: false)
      defer { hosted.close() }
      try require(
        hosted.host.fittingSize.width > 0, "Native host must lay out actual product views")
    }
    try require(
      fixture.engine.starts.isEmpty && fixture.permissionRequests == 0, "Hosting is read-only")
  }

  @MainActor
  private static func favoriteOrderingChecks() throws {
    let input = UIFixture.input.uid
    let alternate = UIFixture.alternateInput.uid
    let hidden = UIFixture.hiddenInput.uid
    let unpinned = UIFixture.unpinnedInput.uid
    let output = UIFixture.output.uid
    let alternateOutput = UIFixture.alternateOutput.uid
    let favorites = UIFixture.interleavedFavorites
    let reconnected = AudioDeviceInfo(
      id: 105, name: "Reconnected Studio", uid: "offline-middle", inputChannelCount: 16,
      outputChannelCount: 0, nominalSampleRate: 48_000)
    let cases: [(devices: [AudioDeviceInfo], query: String, visible: [String])] = [
      (UIFixture.favoriteInputs, "", [input, hidden, alternate, unpinned]),
      (
        [reconnected] + UIFixture.favoriteInputs, "",
        [input, reconnected.uid, hidden, alternate, unpinned]
      ),
      (UIFixture.favoriteInputs, " 16CH \n", [input, alternate, unpinned]),
      (UIFixture.favoriteInputs, "hidden", [hidden]),
      (UIFixture.favoriteInputs, "fixture", [input]),
      (UIFixture.favoriteInputs, "48000 Hz", [input, hidden, alternate, unpinned]),
      (UIFixture.favoriteInputs, "no matching route", []),
      ([UIFixture.output, UIFixture.alternateOutput], "", [output, alternateOutput]),
      ([UIFixture.output, UIFixture.alternateOutput], "alternate", [alternateOutput]),
      ([], "", []),
    ]
    for test in cases {
      let ordering = DevicePickerOrdering(
        devices: test.devices, favorites: favorites, query: test.query)
      try require(ordering.devices.map(\.uid) == test.visible, "Projected device/filter order")
      let visibleFavorites = test.visible.filter { favorites.contains($0) }
      for uid in favorites + [unpinned, "unknown"] {
        for offset in [-1, 1] {
          let index = visibleFavorites.firstIndex(of: uid)
          let neighbor = index.flatMap {
            visibleFavorites.indices.contains($0 + offset) ? visibleFavorites[$0 + offset] : nil
          }
          try require(
            ordering.favoriteNeighbor(uid, offset: offset) == neighbor,
            "Move availability must follow visible favorite boundaries, including hidden/unpinned UIDs"
          )
          var expected = favorites
          if let neighbor, let source = favorites.firstIndex(of: uid),
            let target = favorites.firstIndex(of: neighbor)
          {
            expected.swapAt(source, target)
          }
          let moved = ordering.movingFavorite(uid, offset: offset)
          try require(moved == expected, "Move must swap applicable slots only, retaining all UIDs")
          let after = DevicePickerOrdering(
            devices: test.devices, favorites: moved, query: test.query)
          var expectedVisible = test.visible
          if let neighbor, let source = expectedVisible.firstIndex(of: uid),
            let target = expectedVisible.firstIndex(of: neighbor)
          {
            expectedVisible.swapAt(source, target)
          }
          try require(
            after.devices.map(\.uid) == expectedVisible, "Each available move visibly reorders")
          try require(
            after.movingFavorite(uid, offset: -offset) == favorites || neighbor == nil,
            "Inverse applicable move restores the persisted order")
        }
      }
      for offset in [0, -2, 2, Int.min, Int.max] {
        try require(
          ordering.favoriteNeighbor(input, offset: offset) == nil
            && ordering.movingFavorite(input, offset: offset) == favorites,
          "Unsupported offsets must be safe no-ops")
      }
    }
    let unpinnedOrder = DevicePickerOrdering(devices: UIFixture.favoriteInputs, favorites: [])
    try require(
      unpinnedOrder.devices.map(\.uid) == [alternate, input, hidden, unpinned],
      "Nonfavorites remain alphabetically ordered")
    let reversed = DevicePickerOrdering(
      devices: UIFixture.favoriteInputs, favorites: Array(favorites.reversed()))
    try require(
      reversed.devices.map(\.uid) == [alternate, hidden, input, unpinned],
      "Persisted priority wins over catalog/alphabetical order")
    print(
      "PASS DevicePicker model: input/output, interleaved/disconnected/filter ordering, boundaries and UID retention"
    )
  }

  @MainActor
  private static func favoriteViewChecks() throws {
    let key = "downmix.favoriteDeviceUIDs"
    UserDefaults.standard.set(UIFixture.interleavedFavorites.joined(separator: "\n"), forKey: key)
    defer { UserDefaults.standard.removeObject(forKey: key) }
    let fixture = UIFixture()
    let state = fixture.state()
    let hosted = HostedWindow(
      VStack {
        DevicePickerCard(
          title: "Input", devices: UIFixture.favoriteInputs, selectedID: UIFixture.input.id,
          emptyHint: "Fixture inputs", onSelect: state.selectInput)
        DevicePickerCard(
          title: "Output", devices: [UIFixture.output, UIFixture.alternateOutput],
          selectedID: UIFixture.output.id, emptyHint: "Fixture outputs",
          onSelect: state.selectOutput)
      }, state: state, rendered: true)
    defer { hosted.close() }
    let input = UIFixture.input.uid
    let alternate = UIFixture.alternateInput.uid
    let hidden = UIFixture.hiddenInput.uid
    let unpinned = UIFixture.unpinnedInput.uid
    let output = UIFixture.output.uid
    let alternateOutput = UIFixture.alternateOutput.uid
    func checkActions(_ title: String, _ uid: String, up: Bool, down: Bool, favorite: Bool = true)
      throws
    {
      let names = try hosted.find("device.\(title).\(uid)").accessibilityCustomActions().map(\.name)
      let expected =
        [favorite ? "Remove from Favorites" : "Add to Favorites"]
        + (up ? ["Move Favorite Up"] : []) + (down ? ["Move Favorite Down"] : [])
      try require(
        Set(names) == Set(expected),
        "Rendered AX actions must match visible boundaries: \(uid), \(names)")
    }
    try require(
      hosted.deviceOrder("Input") == [input, hidden, alternate, unpinned]
        && hosted.deviceOrder("Output") == [output, alternateOutput],
      "Actual rows follow shared persisted favorite priority")
    try checkActions("input", input, up: false, down: true)
    try checkActions("input", alternate, up: true, down: false)
    try checkActions("input", unpinned, up: false, down: false, favorite: false)
    try checkActions("output", output, up: false, down: true)
    try checkActions("output", alternateOutput, up: true, down: false)
    try hosted.performAction("Move Favorite Up", on: "device.output.\(alternateOutput)")
    try require(
      hosted.deviceOrder("Output") == [alternateOutput, output]
        && hosted.deviceOrder("Input") == [input, hidden, alternate, unpinned],
      "Output Up crosses invisible input/disconnected neighbors without changing input order")
    try hosted.performAction("Move Favorite Down", on: "device.output.\(alternateOutput)")
    try hosted.editText("device.input.filter", to: " 16CH ")
    try require(
      hosted.deviceOrder("Input") == [input, alternate, unpinned],
      "Actual search excludes nonmatching favorite")
    try hosted.performAction("Move Favorite Up", on: "device.input.\(alternate)")
    try require(
      hosted.deviceOrder("Input") == [alternate, input, unpinned],
      "Input AX Up visibly crosses filtered/disconnected/output favorites")
    var expected = UIFixture.interleavedFavorites
    expected.swapAt(2, 6)
    try require(
      UserDefaults.standard.string(forKey: key) == expected.joined(separator: "\n"),
      "Actual AX action persists all UIDs in the isolated fixture domain")
    try checkActions("input", alternate, up: false, down: true)
    try checkActions("input", input, up: true, down: false)
    try hosted.editText("device.input.filter", to: "fixture")
    try require(hosted.deviceOrder("Input") == [input], "Single search result")
    try checkActions("input", input, up: false, down: false)
    try hosted.editText("device.input.filter", to: "no matching route")
    try require(hosted.deviceOrder("Input").isEmpty, "No-match search hides all rows")
    try hosted.editText("device.input.filter", to: "")
    try require(
      hosted.deviceOrder("Input") == [alternate, hidden, input, unpinned],
      "Clearing search retains reordered priority and hidden favorite slot")
    try hosted.performAction("Move Favorite Down", on: "device.input.\(alternate)")
    try require(
      hosted.deviceOrder("Input") == [hidden, alternate, input, unpinned],
      "Unfiltered Down also reorders relative to applicable neighbors")
    try hosted.performAction("Add to Favorites", on: "device.input.\(unpinned)")
    try checkActions("input", unpinned, up: true, down: false)
    try hosted.performAction("Remove from Favorites", on: "device.input.\(unpinned)")
    try checkActions("input", unpinned, up: false, down: false, favorite: false)
    expected.swapAt(2, 4)
    try require(
      UserDefaults.standard.string(forKey: key) == expected.joined(separator: "\n"),
      "Down and add/remove retain all unrelated/disconnected persisted UIDs")
    try require(
      fixture.engine.starts.isEmpty && fixture.permissionRequests == 0,
      "Favorites/search actions never start audio or request permission")
    print(
      "PASS DevicePicker actual view: native AX favorite moves/actions, input/output boundaries, search and isolated persistence"
    )
  }

  @MainActor
  private static func contentChecks() throws {
    let fixture = UIFixture()
    let state = fixture.state()
    let hosted = HostedWindow(ContentView(), state: state, rendered: true)
    defer { hosted.close() }
    let transport = try hosted.find("main.transport")
    try require(transport.accessibilityRole() == .button, "Transport must render as a button")
    try require(transport.accessibilityLabel() == "Start", "Stopped transport label must be Start")
    try require(
      try hosted.find("main.preamp.field").accessibilityRole() == .textField,
      "Typed preamp alternative")
    try require(
      try hosted.find("main.layout").isAccessibilityEnabled(), "Bed layout picker enabled")
    try require(
      try hosted.find("main.advanced").accessibilityValue() as? String == "Collapsed",
      "Advanced collapsed")
    try hosted.press("main.transport")
    try require(
      state.isRunning && fixture.engine.starts.count == 1, "Rendered Start must call fake backend")
    try require(
      try hosted.find("main.transport").accessibilityLabel() == "Stop", "Running label must be Stop"
    )
    let secondOutput = "device.output.\(UIFixture.alternateOutput.uid)"
    try hosted.press(secondOutput)
    try require(
      fixture.engine.starts.count == 2 && fixture.engine.stops == 1
        && fixture.engine.starts.last?.output == UIFixture.alternateOutput.id,
      "Rendered output selection must stop/restart onto selected fixture route")
    try require(
      try hosted.find(secondOutput).accessibilityValue() as? String == "Selected",
      "Selected output AX state")
    try hosted.press("device.input.\(UIFixture.alternateInput.uid)")
    try require(
      fixture.engine.starts.count == 3 && fixture.engine.stops == 2
        && fixture.engine.starts.last?.input == UIFixture.alternateInput.id,
      "Rendered input selection must restart with new input")
    try hosted.press("main.transport")
    try require(!state.isRunning && fixture.engine.stops == 3, "Rendered Stop must stop backend")
    try hosted.press("main.advanced")
    try require(state.showAdvanced, "Advanced button must change model")
    try require(
      try hosted.find("main.advanced").accessibilityValue() as? String == "Expanded",
      "Expanded AX value")
    _ = try hosted.find("diagnostics")
    _ = try hosted.find("main.framesPerBuffer")
    try hosted.press("main.advanced")
    try require(
      !hosted.elements.contains { $0.accessibilityIdentifier() == "diagnostics" },
      "Collapsed hides diagnostics")
    fixture.engine.emit(EngineStatus(phase: .error, message: "Fixture route error"))
    hosted.settle()
    try require(
      try hosted.find("main.error").accessibilityLabel()?.contains("Fixture route error") == true,
      "Rendered error label")
    try hosted.press("main.retry")
    try require(
      state.isRunning && fixture.engine.starts.count == 4, "Banner Retry starts saved fixture route"
    )
    print(
      "PASS ContentView: AX labels/state, Start/Stop, input/output restart, Advanced diagnostics, banner Retry"
    )
  }

  @MainActor
  private static func selectTab(_ title: String, in hosted: HostedWindow) throws {
    guard
      let tab = hosted.elements.first(where: {
        $0.accessibilityRole() == .radioButton
          && ($0.accessibilityLabel() == title || $0.accessibilityTitle() == title)
      })
    else {
      throw UIError(
        description: "Rendered Settings tab '\(title)' missing.\n\(hosted.treeDescription)")
    }
    // Some native toolbar segments dispatch while returning false (like NSSwitch).
    // Press once, never retry; prove success from the actual rendered destination.
    let acknowledged = tab.accessibilityPerformPress()
    hosted.settle()
    let marker: String
    switch title {
    case "Audio": marker = "settings.input"
    case "Advanced": marker = "settings.framesPerBuffer"
    default: marker = "settings.autoStart"
    }
    try require(
      hosted.elements.contains { $0.accessibilityIdentifier() == marker },
      "Native tab '\(title)' did not select its rendered pane (AX acknowledgement: \(acknowledged)).\n\(hosted.treeDescription)"
    )
  }

  @MainActor
  private static func settingsChecks() throws {
    let fixture = UIFixture()
    let state = fixture.state()
    let hosted = HostedWindow(
      SettingsView(), state: state, rendered: true, size: NSSize(width: 560, height: 430))
    defer { hosted.close() }
    try hosted.press("settings.autoStart")
    try require(
      state.preferences.autoStart, "General toggle changes preferences through native action")
    try hosted.press("settings.transport")
    try require(
      state.isRunning && fixture.engine.starts.count == 1,
      "Settings transport starts the fake renderer")
    try selectTab("Audio", in: hosted)
    _ = try hosted.find("settings.input")
    _ = try hosted.find("settings.output")
    _ = try hosted.find("settings.layout")
    let slider = try hosted.find("settings.preamp")
    let original = state.preferences.preampDb
    try require(
      slider.accessibilityLabel() == "Preamp" && slider.accessibilityRole() == .slider,
      "Preamp AX semantics")
    try require(slider.accessibilityPerformIncrement(), "Native preamp increment supported")
    hosted.settle()
    try require(state.preferences.preampDb > original, "Rendered slider increment changes model")
    try hosted.press("settings.swapOutputs")
    try require(state.preferences.swapOutputs, "Rendered swap toggle changes model")
    try require(
      try hosted.find("settings.swapOutputs").accessibilityValue() as? NSNumber == 1,
      "Swap AX on state")
    try selectTab("Advanced", in: hosted)
    let buffer = try hosted.find("settings.framesPerBuffer")
    let originalFrames = state.preferences.framesPerBuffer
    // AppKit's stepper cell exposes an AX increment button, but its own
    // accessibilityPerformIncrement returns false. Press the declared native
    // arrow once rather than retrying an unacknowledged action or editing model state.
    guard let increment = buffer.accessibilityIncrementButton() else {
      throw UIError(
        description: "Native buffer increment button missing.\n\(hosted.treeDescription)")
    }
    // These native arrows may omit the optional AXEnabled getter and can
    // dispatch while returning false, like toolbar segments. Never retry;
    // prove the single press from the resulting preference/backend change.
    let incrementAcknowledged = increment.accessibilityPerformPress()
    hosted.settle()
    try require(
      state.preferences.framesPerBuffer == originalFrames + 32
        && fixture.engine.starts.count == 2 && fixture.engine.stops == 1
        && fixture.engine.starts.last?.framesPerBuffer == originalFrames + 32,
      "Settings buffer increment restarts the fake renderer with the requested buffer (AX acknowledgement: \(incrementAcknowledged))"
    )
    try hosted.press("settings.keepOutputAlive")
    try require(
      state.preferences.keepOutputAlive && fixture.engine.starts.count == 2,
      "Enabling keep-alive while rendering does not interrupt the renderer")
    _ = try hosted.find("diagnostics")
    try selectTab("General", in: hosted)
    try hosted.press("settings.transport")
    try require(
      !state.isRunning && state.isKeepingOutputAwake && fixture.engine.starts.count == 3
        && fixture.engine.starts.last?.keepAliveOnly == true,
      "Settings Stop transitions to fake output-only keep-alive")
    try selectTab("Advanced", in: hosted)
    try hosted.press("settings.keepOutputAlive")
    try require(
      !state.isKeepingOutputAwake && fixture.engine.stops == 3,
      "Disabling keep-alive stops the fake output-only route")
    state.flushPreferences()
    try require(
      fixture.writes.last == state.preferences && fixture.permissionRequests == 0,
      "Settings use fake writer only")
    print(
      "PASS SettingsView: native tabs, transport, buffer restart, keep-alive, auto-start/preamp/swap, fake persistence"
    )
  }

  @MainActor
  private static func menuChecks() throws {
    let fixture = UIFixture()
    let state = fixture.state()
    let hosted = HostedWindow(
      MenuBarView(), state: state, rendered: true, size: NSSize(width: 260, height: 500))
    defer { hosted.close() }
    try require(
      try hosted.find("menu.transport").accessibilityLabel() == "Start Renderer",
      "Menu stopped label")
    try hosted.press("menu.transport")
    try require(state.isRunning && fixture.engine.starts.count == 1, "Menu Start invokes backend")
    try require(
      try hosted.find("menu.transport").accessibilityLabel() == "Stop Renderer",
      "Menu running label")
    try hosted.press("menu.transport")
    fixture.engine.emit(EngineStatus(phase: .error, message: "Fixture disconnected"))
    fixture.catalog.removeAll { $0.id == UIFixture.output.id }
    hosted.settle()
    try hosted.press("menu.retry")
    try require(
      !state.isRunning && fixture.engine.starts.count == 1, "Missing saved output cannot fall back")
    fixture.catalog.append(UIFixture.output)
    try hosted.press("menu.retry")
    try require(
      state.isRunning && fixture.engine.starts.count == 2, "Menu Retry resolves saved route")
    let count = fixture.enumerations
    try hosted.press("menu.refresh")
    try require(fixture.enumerations == count + 1, "Menu refresh invokes fixture catalog")
    _ = try hosted.find("menu.showWindow")
    _ = try hosted.find("menu.quit")
    print(
      "PASS MenuBarView: transport labels/actions, retry missing/reconnected route, refresh; no Quit/system action invoked"
    )
  }

  @MainActor
  private static func retryWarmupChecks() throws {
    let fixture = UIFixture()
    let state = fixture.state()
    fixture.engine.emit(EngineStatus(phase: .error, message: "Fixture failure"))
    fixture.engine.holdStartup = true
    state.preferences.keepOutputAlive = true
    state.startKeepAliveIfNeeded()
    try require(
      state.status.phase == .starting && state.isKeepingOutputAwake && !state.isRunning,
      "Fixture must exercise output-only warmup, not renderer warmup")
    let main = HostedWindow(ContentView(), state: state, rendered: true)
    defer { main.close() }
    let menu = HostedWindow(
      MenuBarView(), state: state, rendered: true, size: NSSize(width: 260, height: 500))
    defer { menu.close() }
    try require(
      try !main.find("main.retry").isAccessibilityEnabled(),
      "Main Retry must be disabled during keep-alive warmup")
    try require(
      try !menu.find("menu.retry").isAccessibilityEnabled(),
      "Menu Retry must be disabled during keep-alive warmup")
    let beforeRetry = fixture.enumerations
    state.retrySavedRoute()
    try require(
      fixture.enumerations == beforeRetry && fixture.engine.starts.count == 1,
      "Retry must leave the warming-up route untouched")
    fixture.engine.emit(EngineStatus(phase: .keepAlive))
    main.settle()
    menu.settle()
    try require(
      try main.find("main.retry").isAccessibilityEnabled()
        && menu.find("menu.retry").isAccessibilityEnabled(),
      "Retry becomes available after output-only startup completes")
    state.preferences.keepOutputAlive = false
    state.stop()
    print("PASS Retry warmup: actual main/menu AX controls disabled until keep-alive is ready")
  }

  @MainActor
  private static func persistenceErrorChecks() throws {
    let fixture = UIFixture()
    let state = fixture.state()
    fixture.engine.emit(EngineStatus(phase: .error, message: "Independent audio failure"))
    let surfaces = [
      ("main", HostedWindow(ContentView(), state: state, rendered: true)),
      (
        "settings",
        HostedWindow(
          SettingsView(), state: state, rendered: true, size: NSSize(width: 560, height: 560))
      ),
      (
        "menu",
        HostedWindow(
          MenuBarView(), state: state, rendered: true, size: NSSize(width: 300, height: 640))
      ),
    ]
    defer { for (_, hosted) in surfaces { hosted.close() } }
    for (surface, hosted) in surfaces {
      fixture.failWrites = true
      state.flushPreferences()
      for (identifier, window) in surfaces {
        window.settle()
        try require(
          try window.find("\(identifier).saveError").accessibilityLabel()?.contains(
            "Could not save settings") == true,
          "Save error must be readable in \(identifier)")
      }
      let before = fixture.saveAttempts
      try hosted.press("\(surface).retrySave")
      try require(
        fixture.saveAttempts == before + 1 && state.persistenceErrorMessage != nil,
        "Retry Save must retry the writer and retain a repeated failure")
      fixture.failWrites = false
      try hosted.press("\(surface).retrySave")
      try require(
        fixture.saveAttempts == before + 2 && state.persistenceErrorMessage == nil,
        "Successful native Retry Save clears the persistence error")
      for (identifier, window) in surfaces {
        window.settle()
        try require(
          !window.elements.contains { $0.accessibilityIdentifier() == "\(identifier).saveError" },
          "Successful save removes every surface's persistence banner")
      }
      try require(
        state.errorMessage == "Independent audio failure" && state.status.phase == .error,
        "Persistence recovery must not clear the independent audio error")
      try require(
        fixture.engine.starts.isEmpty && fixture.engine.stops == 0
          && fixture.engine.configurations.isEmpty,
        "Retry Save must never start, stop or reconfigure audio")
    }
    fixture.failWrites = true
    state.flushPreferences()
    let beforeDismiss = fixture.saveAttempts
    surfaces[0].1.settle()
    try surfaces[0].1.press("main.dismissSaveError")
    try require(
      state.persistenceErrorMessage == nil && fixture.saveAttempts == beforeDismiss
        && state.errorMessage == "Independent audio failure",
      "Dismissing a save error must neither write nor dismiss the audio error")
    print(
      "PASS save recovery: actual main/Settings/menu Retry Save actions, independent errors, no transport"
    )
  }

  @MainActor
  private static func setupChecks() throws {
    let fixture = UIFixture()
    fixture.permission = .notDetermined
    let state = fixture.state()
    let hosted = HostedWindow(
      SetupChecklistView(), state: state, rendered: true, size: NSSize(width: 540, height: 640))
    defer { hosted.close() }
    for id in ["speakerMapping", "systemOutput"] {
      let row = try hosted.find("setup.row.\(id)")
      try require(
        row.accessibilityValue() as? String == "Manual check",
        "Manual rows must never announce Verified; actual value: \(String(describing: row.accessibilityValue())).\n\(hosted.treeDescription)"
      )
      try require(row.accessibilityHelp()?.isEmpty == false, "Manual rows expose guidance")
    }
    try require(
      try hosted.find("setup.row.authorization").accessibilityValue() as? String
        == "Permission required", "Permission state")
    _ = try hosted.find("setup.requestPermission")
    _ = try hosted.find("setup.audioMIDI")
    _ = try hosted.find("setup.microphoneSettings")
    _ = try hosted.find("setup.done")
    let before = fixture.enumerations
    try hosted.press("setup.refresh")
    try require(fixture.enumerations == before + 1, "Refresh uses fake catalog")
    try require(
      fixture.permissionRequests == 0 && fixture.engine.starts.isEmpty,
      "Setup rendering/refresh never prompts or starts")
    print(
      "PASS SetupChecklistView: manual/permission AX values and guidance, native refresh; system-tool/permission buttons not pressed"
    )
  }

  @MainActor
  private static func setupSheetChecks() throws {
    let fixture = UIFixture()
    fixture.permission = .notDetermined
    let state = fixture.state()
    let hosted = HostedWindow(ContentView(), state: state, rendered: true)
    defer { hosted.close() }
    try hosted.press("setup.open")
    try require(!hosted.window.sheets.isEmpty, "Setup button presents an actual native sheet")
    try hosted.press("setup.requestPermission")
    try require(
      fixture.permissionRequests == 1 && fixture.engine.starts.isEmpty,
      "Sheet permission button invokes injected fake request only")
    fixture.permission = .denied
    fixture.permissionReply?(false)
    fixture.permissionReply = nil
    hosted.settle()
    try require(
      !state.isRunning && state.errorMessage != nil,
      "Fake permission denial retains stopped/error state")
    fixture.permission = .notDetermined
    try hosted.press("setup.refresh")
    try hosted.press("setup.requestPermission")
    try require(fixture.permissionRequests == 2, "Sheet can retry a fake permission request")
    fixture.permission = .authorized
    fixture.permissionReply?(true)
    fixture.permissionReply = nil
    hosted.settle()
    try require(
      state.isRunning && fixture.engine.starts.count == 1,
      "Fake permission grant starts only the fixture backend")
    try require(
      try hosted.find("setup.row.authorization").accessibilityValue() as? String == "Verified",
      "Sheet updates rendered permission status")
    try hosted.press("setup.done")
    try require(hosted.window.sheets.isEmpty, "Done dismisses the actual sheet")
    try hosted.press("main.transport")
    try require(!state.isRunning, "Renderer remains controllable after sheet dismissal")
    print(
      "PASS Setup sheet: native presentation/dismissal, fake permission deny/retry/grant; no system/TCC action"
    )
  }

  @MainActor
  private static func diagnosticsChecks() throws {
    let fixture = UIFixture()
    let state = fixture.state()
    var diagnostics = EngineDiagnostics.empty
    diagnostics.underrunCount = 3
    diagnostics.requestedBufferFrames = 128
    diagnostics.queuedFrames = 480
    fixture.engine.emit(EngineStatus(phase: .running, diagnostics: diagnostics))
    let hosted = HostedWindow(EngineDiagnosticsView(), state: state, rendered: true)
    defer { hosted.close() }
    try require(
      try hosted.find("diagnostics.Underruns").accessibilityValue() as? String == "3",
      "Rendered underrun counter")
    try require(
      try hosted.find("diagnostics.Approx. queue latency").accessibilityValue() as? String
        == "10.00 ms", "Rendered queue estimate")
    fixture.engine.emit(
      EngineStatus(phase: .error, message: "Fixture error", diagnostics: diagnostics))
    hosted.settle()
    try require(
      try hosted.find("diagnostics").accessibilityLabel() == "Last-run audio engine diagnostics",
      "Error diagnostics label")
    try require(
      try hosted.find("diagnostics.Queued audio").accessibilityValue() as? String == "0 frames",
      "Error clears queued audio")
    print("PASS EngineDiagnosticsView: native AX counters/queue estimate and last-run error state")
  }

  @MainActor
  private static func reducedMotionChecks() throws {
    let fixture = UIFixture()
    let state = fixture.state()
    let hosted = HostedWindow(ContentView(), state: state, rendered: true, reduceMotion: true)
    defer { hosted.close() }
    try hosted.press("main.transport")
    try require(
      state.isRunning && fixture.engine.starts.count == 1, "Reduced-motion transport retains action"
    )
    try hosted.press("main.advanced")
    _ = try hosted.find("diagnostics")
    for reduced in [false, true] {
      let icon = HostedWindow(
        MenuBarStatusIcon(source: state.meterSource, isRunning: true), state: state,
        rendered: true, size: NSSize(width: 100, height: 40), reduceMotion: reduced)
      defer { icon.close() }
      try require(
        try icon.find("menu.statusIcon").accessibilityLabel() == "Downmix is rendering",
        "Reduce Motion retains icon content")
    }
    print(
      "PASS Reduce Motion environment: native content/AX/actions retained (not an animation-behavior measurement)"
    )
  }
}
