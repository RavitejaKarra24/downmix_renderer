import AppKit
import SwiftUI

/// The shared visual language for both SwiftUI and AppKit surfaces.
///
/// Colors are backed by dynamic `NSColor` values so the custom meter canvas and
/// SwiftUI controls resolve the exact same palette in Light, Dark, and increased
/// contrast appearances.
enum DownmixTheme {
  // MARK: - AppKit color bridge

  static let nsBackground = adaptive(
    light: NSColor(red: 0.93, green: 0.95, blue: 0.96, alpha: 1),
    dark: NSColor(red: 0.055, green: 0.063, blue: 0.078, alpha: 1)
  )
  static let nsSurfaceWell = adaptive(
    light: NSColor(red: 0.86, green: 0.89, blue: 0.91, alpha: 0.82),
    dark: NSColor(red: 0.075, green: 0.088, blue: 0.11, alpha: 0.88)
  )
  static let nsSurfaceRaised = adaptive(
    light: NSColor(red: 0.98, green: 0.985, blue: 0.99, alpha: 0.88),
    dark: NSColor(red: 0.12, green: 0.14, blue: 0.175, alpha: 0.88)
  )
  static let nsCardStroke = adaptive(
    light: NSColor.black.withAlphaComponent(0.13),
    dark: NSColor.white.withAlphaComponent(0.13),
    highContrastLight: NSColor.black.withAlphaComponent(0.28),
    highContrastDark: NSColor.white.withAlphaComponent(0.3)
  )
  static let nsTextPrimary = adaptive(
    light: NSColor(red: 0.075, green: 0.09, blue: 0.12, alpha: 1),
    dark: NSColor(red: 0.95, green: 0.965, blue: 0.98, alpha: 1)
  )
  static let nsTextSecondary = adaptive(
    light: NSColor(red: 0.29, green: 0.33, blue: 0.39, alpha: 1),
    dark: NSColor(red: 0.69, green: 0.73, blue: 0.79, alpha: 1)
  )
  static let nsAccent = adaptive(
    light: NSColor(red: 0, green: 0.45, blue: 0.42, alpha: 1),
    dark: NSColor(red: 0.18, green: 0.78, blue: 0.71, alpha: 1)
  )
  static let nsOnAccent = adaptive(
    light: .white,
    dark: NSColor(red: 0.025, green: 0.035, blue: 0.04, alpha: 1)
  )
  static let nsGood = adaptive(
    light: NSColor(red: 0.03, green: 0.45, blue: 0.23, alpha: 1),
    dark: NSColor(red: 0.28, green: 0.79, blue: 0.47, alpha: 1)
  )
  static let nsWarn = adaptive(
    light: NSColor(red: 0.62, green: 0.32, blue: 0, alpha: 1),
    dark: NSColor(red: 0.96, green: 0.66, blue: 0.25, alpha: 1)
  )
  static let nsBad = adaptive(
    light: NSColor(red: 0.75, green: 0.16, blue: 0.22, alpha: 1),
    dark: NSColor(red: 0.95, green: 0.36, blue: 0.42, alpha: 1)
  )
  static let nsOnBad = adaptive(
    light: .white,
    dark: NSColor(red: 0.025, green: 0.035, blue: 0.04, alpha: 1)
  )
  static let nsBedChannel = adaptive(
    light: NSColor(red: 0.04, green: 0.47, blue: 0.78, alpha: 1),
    dark: NSColor(red: 0.31, green: 0.67, blue: 0.98, alpha: 1)
  )
  static let nsHeightChannel = adaptive(
    light: NSColor(red: 0.48, green: 0.28, blue: 0.79, alpha: 1),
    dark: NSColor(red: 0.7, green: 0.55, blue: 0.98, alpha: 1)
  )
  static let nsLFEChannel = nsWarn
  static let nsMeterTrack = adaptive(
    light: NSColor.black.withAlphaComponent(0.1),
    dark: NSColor.white.withAlphaComponent(0.09),
    highContrastLight: NSColor.black.withAlphaComponent(0.2),
    highContrastDark: NSColor.white.withAlphaComponent(0.2)
  )

  // MARK: - SwiftUI colors

  static let bg = Color(nsColor: nsBackground)
  static let surfaceWell = Color(nsColor: nsSurfaceWell)
  static let surfaceRaised = Color(nsColor: nsSurfaceRaised)
  static let card = surfaceRaised
  static let cardStroke = Color(nsColor: nsCardStroke)
  static let textPrimary = Color(nsColor: nsTextPrimary)
  static let textSecondary = Color(nsColor: nsTextSecondary)
  static let accent = Color(nsColor: nsAccent)
  static let onAccent = Color(nsColor: nsOnAccent)
  static let accentHover = accent.opacity(0.86)
  static let accentPressed = accent.opacity(0.7)
  static let accentSoft = accent.opacity(0.14)
  static let good = Color(nsColor: nsGood)
  static let warn = Color(nsColor: nsWarn)
  static let bad = Color(nsColor: nsBad)
  static let onBad = Color(nsColor: nsOnBad)
  static let meter = Color(nsColor: nsBedChannel)
  static let bedChannel = Color(nsColor: nsBedChannel)
  static let heightChannel = Color(nsColor: nsHeightChannel)
  static let lfeChannel = Color(nsColor: nsLFEChannel)
  static let meterTrack = Color(nsColor: nsMeterTrack)

  static let backgroundGradient = LinearGradient(
    colors: [bg, accent.opacity(0.035), bg],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

  // MARK: - Type scale

  enum TypeScale {
    static let wordmark = Font.system(size: 27, weight: .bold, design: .rounded)
    static let title = Font.system(size: 20, weight: .bold, design: .rounded)
    static let headline = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 11, weight: .regular)
    static let label = Font.system(size: 10, weight: .semibold)
    static let liveValue = Font.system(size: 12, weight: .semibold, design: .monospaced)
  }

  // MARK: - Layout

  static let panelRadius: CGFloat = 16
  static let wellRadius: CGFloat = 14

  private static func adaptive(
    light: NSColor,
    dark: NSColor,
    highContrastLight: NSColor? = nil,
    highContrastDark: NSColor? = nil
  ) -> NSColor {
    NSColor(name: nil) { appearance in
      let match = appearance.bestMatch(from: [
        .accessibilityHighContrastDarkAqua,
        .accessibilityHighContrastAqua,
        .darkAqua,
        .aqua,
      ])
      switch match {
      case .accessibilityHighContrastDarkAqua:
        return highContrastDark ?? dark
      case .accessibilityHighContrastAqua:
        return highContrastLight ?? light
      case .darkAqua:
        return dark
      default:
        return light
      }
    }
  }
}

private struct DownmixRaisedPanelModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast

  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    content
      .background(.thinMaterial, in: shape)
      .background(shape.fill(DownmixTheme.surfaceRaised.opacity(0.72)))
      .overlay(
        shape.stroke(
          DownmixTheme.cardStroke,
          lineWidth: contrast == .increased ? 1.5 : 1
        )
      )
      .shadow(
        color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12),
        radius: 14,
        x: 0,
        y: 7
      )
  }
}

private struct DownmixRecessedWellModifier: ViewModifier {
  @Environment(\.colorSchemeContrast) private var contrast

  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    content
      .background(shape.fill(DownmixTheme.surfaceWell))
      .overlay(
        shape.stroke(
          DownmixTheme.cardStroke.opacity(contrast == .increased ? 1 : 0.75),
          lineWidth: contrast == .increased ? 1.5 : 1
        )
      )
  }
}

extension View {
  func downmixRaisedPanel(cornerRadius: CGFloat = DownmixTheme.panelRadius) -> some View {
    modifier(DownmixRaisedPanelModifier(cornerRadius: cornerRadius))
  }

  func downmixRecessedWell(cornerRadius: CGFloat = DownmixTheme.wellRadius) -> some View {
    modifier(DownmixRecessedWellModifier(cornerRadius: cornerRadius))
  }
}

struct SecondaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(DownmixTheme.TypeScale.bodyStrong)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        Capsule()
          .fill(
            configuration.isPressed
              ? DownmixTheme.accentSoft.opacity(0.7)
              : DownmixTheme.surfaceWell.opacity(0.88)
          )
      )
      .overlay(Capsule().stroke(DownmixTheme.cardStroke, lineWidth: 1))
      .foregroundStyle(isEnabled ? DownmixTheme.textPrimary : DownmixTheme.textSecondary)
      .opacity(isEnabled ? 1 : 0.55)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}
