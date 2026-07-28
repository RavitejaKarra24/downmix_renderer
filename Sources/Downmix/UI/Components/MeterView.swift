import SwiftUI

struct StereoMeterView: View {
  let leftDb: Float
  let rightDb: Float
  let clipL: Bool
  let clipR: Bool

  var body: some View {
    HStack(spacing: 10) {
      meter(label: "L", db: leftDb, clip: clipL)
      meter(label: "R", db: rightDb, clip: clipR)
    }
  }

  private func meter(label: String, db: Float, clip: Bool) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(label)
          .font(.caption.weight(.semibold))
          .foregroundStyle(DownmixTheme.textSecondary)
        Spacer()
        Text(clip ? "CLIP" : String(format: "%.1f dB", db))
          .font(.caption.monospacedDigit())
          .foregroundStyle(clip ? DownmixTheme.bad : DownmixTheme.textSecondary)
          .frame(width: 68, alignment: .trailing)
      }
      GeometryReader { geo in
        let width = max(0, geo.size.width * CGFloat(level(db)))
        ZStack(alignment: .leading) {
          Capsule()
            .fill(Color.white.opacity(0.06))
          Capsule()
            .fill(
              LinearGradient(
                colors: [DownmixTheme.accent.opacity(0.75), DownmixTheme.good],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .frame(width: width)
        }
      }
      .frame(height: 8)
    }
  }

  private func level(_ db: Float) -> Double {
    // Map -60...0 dB to 0...1
    let clamped = min(0, max(-60, Double(db)))
    return (clamped + 60) / 60
  }
}
