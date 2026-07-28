import Foundation

enum BedChannel: Int, CaseIterable, Identifiable, Sendable {
  case l, r, c, lfe, ls, rs, lrs, rrs, lw, rw, ltf, rtf, ltm, rtm, ltr, rtr

  var id: Int { rawValue }

  var label: String {
    switch self {
    case .l: "L"
    case .r: "R"
    case .c: "C"
    case .lfe: "LFE"
    case .ls: "Ls"
    case .rs: "Rs"
    case .lrs: "Lrs"
    case .rrs: "Rrs"
    case .lw: "Lw"
    case .rw: "Rw"
    case .ltf: "Ltf"
    case .rtf: "Rtf"
    case .ltm: "Ltm"
    case .rtm: "Rtm"
    case .ltr: "Ltr"
    case .rtr: "Rtr"
    }
  }

  /// Normalized position in the top-down bed visualizer (x, y) with y forward.
  var visualPosition: (x: Double, y: Double) {
    switch self {
    case .l: (-0.55, 0.72)
    case .r: (0.55, 0.72)
    case .c: (0.0, 0.82)
    case .lfe: (0.22, 0.55)
    case .ls: (-0.82, 0.08)
    case .rs: (0.82, 0.08)
    case .lrs: (-0.62, -0.62)
    case .rrs: (0.62, -0.62)
    case .lw: (-0.92, 0.42)
    case .rw: (0.92, 0.42)
    case .ltf: (-0.42, 0.58)
    case .rtf: (0.42, 0.58)
    case .ltm: (-0.48, 0.05)
    case .rtm: (0.48, 0.05)
    case .ltr: (-0.38, -0.42)
    case .rtr: (0.38, -0.42)
    }
  }

  var isHeight: Bool {
    switch self {
    case .ltf, .rtf, .ltm, .rtm, .ltr, .rtr: true
    default: false
    }
  }
}

struct LayoutPreset: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  /// 1-based input channel map for the 16 bed slots. 0 = muted/unmapped.
  let map: [Int]

  static let all: [LayoutPreset] = [
    .init(
      id: "9.1.6", name: "9.1.6 bed (1:1)",
      map: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]),
    .init(id: "7.1.4", name: "7.1.4", map: [1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 9, 10, 11, 12, 0, 0]),
    .init(id: "7.1.2", name: "7.1.2", map: [1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 9, 10, 0, 0, 0, 0]),
    .init(id: "7.1", name: "7.1", map: [1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0, 0, 0, 0, 0]),
    .init(id: "5.1.4", name: "5.1.4", map: [1, 2, 3, 4, 5, 6, 0, 0, 0, 0, 7, 8, 9, 10, 0, 0]),
    .init(id: "5.1.2", name: "5.1.2", map: [1, 2, 3, 4, 5, 6, 0, 0, 0, 0, 7, 8, 0, 0, 0, 0]),
    .init(id: "5.1", name: "5.1", map: [1, 2, 3, 4, 5, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    .init(id: "3.1", name: "3.1", map: [1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    .init(id: "3.0", name: "3.0", map: [1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    .init(id: "2.1", name: "2.1", map: [1, 2, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    .init(id: "2.0", name: "2.0 stereo", map: [1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  ]

  static func named(_ name: String) -> LayoutPreset {
    all.first { $0.name == name || $0.id == name } ?? all[0]
  }
}
