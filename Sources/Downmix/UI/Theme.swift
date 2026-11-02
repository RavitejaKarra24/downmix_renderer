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
    light: NSColor(red: 0.93, green: 0.945, blue: 0.955, alpha: 1),
    dark: NSColor(red: 0.039, green: 0.045, blue: 0.059, alpha: 1)
  )
  static let nsSurfaceWell = adaptive(
    light: NSColor(red: 0.88, green: 0.905, blue: 0.92, alpha: 0.85),
    dark: NSColor(red: 0.052, green: 0.06, blue: 0.078, alpha: 0.92)
  )
  static let nsSurfaceRaised = adaptive(
    light: NSColor(red: 0.985, green: 0.99, blue: 0.995, alpha: 0.92),
    dark: NSColor(red: 0.098, green: 0.11, blue: 0.138, alpha: 0.94)
  )
  /// Top and bottom stops of the raised panel gradient.
  static let nsPanelTop = adaptive(
    light: NSColor(red: 0.995, green: 0.997, blue: 1, alpha: 1),
    dark: NSColor(red: 0.088, green: 0.099, blue: 0.124, alpha: 1)
  )
  static let nsPanelBottom = adaptive(
    light: NSColor(red: 0.955, green: 0.965, blue: 0.975, alpha: 1),
    dark: NSColor(red: 0.061, green: 0.069, blue: 0.088, alpha: 1)
  )
  static let nsPanelHighlight = adaptive(
    light: NSColor.white.withAlphaComponent(0.9),
    dark: NSColor.white.withAlphaComponent(0.07)
  )
  static let nsCardStroke = adaptive(
    light: NSColor.black.withAlphaComponent(0.1),
    dark: NSColor.white.withAlphaComponent(0.085),
    highContrastLight: NSColor.black.withAlphaComponent(0.28),
    highContrastDark: NSColor.white.withAlphaComponent(0.3)
  )
  static let nsTextPrimary = adaptive(
    light: NSColor(red: 0.075, green: 0.09, blue: 0.12, alpha: 1),
    dark: NSColor(red: 0.94, green: 0.952, blue: 0.97, alpha: 1)
  )
  static let nsTextSecondary = adaptive(
    light: NSColor(red: 0.32, green: 0.36, blue: 0.42, alpha: 1),
    dark: NSColor(red: 0.6, green: 0.64, blue: 0.71, alpha: 1)
  )
  static let nsAccent = adaptive(
    light: NSColor(red: 0, green: 0.48, blue: 0.43, alpha: 1),
    dark: NSColor(red: 0.29, green: 0.87, blue: 0.76, alpha: 1)
  )
  static let nsOnAccent = adaptive(
    light: .white,
    dark: NSColor(red: 0.02, green: 0.05, blue: 0.05, alpha: 1)
  )
  static let nsGood = adaptive(
    light: NSColor(red: 0.03, green: 0.5, blue: 0.27, alpha: 1),
    dark: NSColor(red: 0.42, green: 0.88, blue: 0.5, alpha: 1)
  )
  static let nsWarn = adaptive(
    light: NSColor(red: 0.66, green: 0.36, blue: 0, alpha: 1),
    dark: NSColor(red: 1, green: 0.72, blue: 0.33, alpha: 1)
  )
  static let nsBad = adaptive(
    light: NSColor(red: 0.78, green: 0.17, blue: 0.24, alpha: 1),
    dark: NSColor(red: 1, green: 0.4, blue: 0.45, alpha: 1)
  )
  static let nsOnBad = adaptive(
    light: .white,
    dark: NSColor(red: 0.12, green: 0.02, blue: 0.03, alpha: 1)
  )
  static let nsBedChannel = adaptive(
    light: NSColor(red: 0, green: 0.5, blue: 0.68, alpha: 1),
    dark: NSColor(red: 0.33, green: 0.8, blue: 0.97, alpha: 1)
  )
  static let nsHeightChannel = adaptive(
    light: NSColor(red: 0.47, green: 0.3, blue: 0.82, alpha: 1),
    dark: NSColor(red: 0.71, green: 0.6, blue: 1, alpha: 1)
  )
  static let nsLFEChannel = nsWarn
  static let nsMeterTrack = adaptive(
    light: NSColor.black.withAlphaComponent(0.08),
    dark: NSColor.white.withAlphaComponent(0.065),
    highContrastLight: NSColor.black.withAlphaComponent(0.2),
    highContrastDark: NSColor.white.withAlphaComponent(0.2)
  )

  // MARK: - Soundfield stage

  static let nsStageCenter = adaptive(
    light: NSColor(red: 0.975, green: 0.982, blue: 0.99, alpha: 1),
    dark: NSColor(red: 0.075, green: 0.086, blue: 0.11, alpha: 1)
  )
  static let nsStageEdge = adaptive(
    light: NSColor(red: 0.935, green: 0.948, blue: 0.96, alpha: 1),
    dark: NSColor(red: 0.047, green: 0.054, blue: 0.07, alpha: 1)
  )
  static let nsStageGuide = adaptive(
    light: NSColor.black.withAlphaComponent(0.12),
    dark: NSColor.white.withAlphaComponent(0.095),
    highContrastLight: NSColor.black.withAlphaComponent(0.3),
    highContrastDark: NSColor.white.withAlphaComponent(0.3)
  )
  static let nsPanelRim = adaptive(
    light: NSColor.black.withAlphaComponent(0.06),
    dark: NSColor.white.withAlphaComponent(0.15)
  )
  static let nsSpeakerBody = adaptive(
    light: NSColor(red: 0.99, green: 0.993, blue: 1, alpha: 1),
    dark: NSColor(red: 0.115, green: 0.13, blue: 0.162, alpha: 1)
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
  static let panelTop = Color(nsColor: nsPanelTop)
  static let panelBottom = Color(nsColor: nsPanelBottom)
  static let panelRim = Color(nsColor: nsPanelRim)

  static let panelGradient = LinearGradient(
    colors: [panelTop, panelBottom],
    startPoint: .top,
    endPoint: .bottom
  )

  /// Brand tile used behind the app glyph.
  static let brandGradient = LinearGradient(
    colors: [accent, bedChannel],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

  // MARK: - Type scale

  enum TypeScale {
    static let wordmark = Font.system(size: 27, weight: .bold, design: .rounded)
    static let title = Font.system(size: 20, weight: .bold, design: .rounded)
    static let headline = Font.system(size: 15, weight: .semibold, design: .rounded)
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
      .background(shape.fill(DownmixTheme.panelGradient))
      .overlay(
        shape.strokeBorder(
          contrast == .increased
            ? AnyShapeStyle(DownmixTheme.cardStroke)
            : AnyShapeStyle(
              LinearGradient(
                colors: [DownmixTheme.panelRim, DownmixTheme.cardStroke, DownmixTheme.cardStroke],
                startPoint: .top,
                endPoint: .bottom
              )),
          lineWidth: contrast == .increased ? 1.5 : 1
        )
      )
      .shadow(
        color: Color.black.opacity(colorScheme == .dark ? 0.38 : 0.08),
        radius: 18,
        x: 0,
        y: 8
      )
  }
}

/// Window backdrop: a deep base with two faint coloured glows, so panels read as
/// floating glass rather than boxes on a flat fill.
struct DownmixBackdrop: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let strength = colorScheme == .dark ? 1.0 : 0.6
    ZStack {
      DownmixTheme.bg
      RadialGradient(
        colors: [DownmixTheme.accent.opacity(0.11 * strength), .clear],
        center: .topLeading,
        startRadius: 0,
        endRadius: 720
      )
      RadialGradient(
        colors: [DownmixTheme.heightChannel.opacity(0.08 * strength), .clear],
        center: .bottomTrailing,
        startRadius: 0,
        endRadius: 820
      )
    }
    .accessibilityHidden(true)
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}
