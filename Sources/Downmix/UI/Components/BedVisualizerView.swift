import SwiftUI

struct BedVisualizerView: View {
  let levelsDb: [Float]
  let activeThresholdDb: Float = -48

  var body: some View {
    GeometryReader { geo in
      let size = min(geo.size.width, geo.size.height)
      ZStack {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(DownmixTheme.card)
          .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .stroke(DownmixTheme.cardStroke, lineWidth: 1)
          )

        // Room guide
        RoundedRectangle(cornerRadius: 28, style: .continuous)
          .stroke(Color.white.opacity(0.05), lineWidth: 1)
          .frame(width: size * 0.72, height: size * 0.72)

        Circle()
          .fill(Color.white.opacity(0.04))
          .frame(width: 54, height: 54)
        Image(systemName: "headphones")
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(DownmixTheme.textSecondary)

        ForEach(BedChannel.allCases) { channel in
          let db = level(for: channel)
          let active = db > activeThresholdDb
          let pos = channel.visualPosition
          let x = geo.size.width * 0.5 + CGFloat(pos.x) * size * 0.34
          let y = geo.size.height * 0.5 - CGFloat(pos.y) * size * 0.34

          VStack(spacing: 4) {
            ZStack {
              Circle()
                .fill(glowColor(for: channel, active: active, db: db))
                .frame(width: 16, height: 16)
              Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                .frame(width: 16, height: 16)
            }
            Text(channel.label)
              .font(.system(size: 9, weight: .semibold, design: .rounded))
              .foregroundStyle(
                active ? DownmixTheme.textPrimary : DownmixTheme.textSecondary.opacity(0.7))
          }
          .position(x: x, y: y)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minHeight: 280)
  }

  private func level(for channel: BedChannel) -> Float {
    guard channel.rawValue < levelsDb.count else { return -120 }
    return levelsDb[channel.rawValue]
  }

  private func glowColor(for channel: BedChannel, active: Bool, db: Float) -> Color {
    guard active else { return Color.white.opacity(0.12) }
    let t = min(1, max(0, (Double(db) + 48) / 48))
    if channel.isHeight {
      return DownmixTheme.heightChannel.opacity(0.45 + 0.55 * t)
    }
    if channel == .lfe {
      return DownmixTheme.warn.opacity(0.45 + 0.55 * t)
    }
    return DownmixTheme.accent.opacity(0.45 + 0.55 * t)
  }
}
