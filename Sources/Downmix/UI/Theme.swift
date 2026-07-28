import SwiftUI

enum DownmixTheme {
  static let bg = Color(red: 0.04, green: 0.045, blue: 0.055)
  static let card = Color(red: 0.09, green: 0.10, blue: 0.12)
  static let cardStroke = Color.white.opacity(0.08)
  static let textPrimary = Color(red: 0.93, green: 0.94, blue: 0.96)
  static let textSecondary = Color(red: 0.62, green: 0.66, blue: 0.72)
  static let accent = Color(red: 0.35, green: 0.68, blue: 1.0)
  static let accentSoft = Color(red: 0.35, green: 0.68, blue: 1.0).opacity(0.16)
  static let good = Color(red: 0.35, green: 0.86, blue: 0.58)
  static let warn = Color(red: 1.0, green: 0.72, blue: 0.28)
  static let bad = Color(red: 1.0, green: 0.38, blue: 0.42)
  static let meter = Color(red: 0.42, green: 0.78, blue: 1.0)
  static let heightChannel = Color(red: 0.72, green: 0.55, blue: 1.0)
}
