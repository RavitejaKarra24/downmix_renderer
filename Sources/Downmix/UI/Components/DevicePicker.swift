import CoreAudio
import SwiftUI

struct DevicePickerCard: View {
  let title: String
  let devices: [AudioDeviceInfo]
  let selectedID: AudioDeviceID?
  let emptyHint: String
  let onSelect: (AudioDeviceInfo) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.headline)
        .foregroundStyle(DownmixTheme.textPrimary)

      if devices.isEmpty {
        Text(emptyHint)
          .font(.callout)
          .foregroundStyle(DownmixTheme.textSecondary)
          .padding(.vertical, 12)
      } else {
        VStack(spacing: 6) {
          ForEach(devices) { device in
            deviceRow(device)
          }
        }
      }
    }
    .padding(14)
    .background(cardBackground)
  }

  private func deviceRow(_ device: AudioDeviceInfo) -> some View {
    let selected = device.id == selectedID
    let isVirtual = device.name.localizedCaseInsensitiveContains("blackhole")
    return Button {
      onSelect(device)
    } label: {
      HStack(spacing: 10) {
        Circle()
          .fill(selected ? DownmixTheme.accent : Color.white.opacity(0.12))
          .frame(width: 8, height: 8)
        VStack(alignment: .leading, spacing: 2) {
          Text(device.name)
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundStyle(DownmixTheme.textPrimary)
            .lineLimit(1)
          Text(device.subtitle)
            .font(.caption)
            .foregroundStyle(DownmixTheme.textSecondary)
        }
        Spacer(minLength: 0)
        if isVirtual {
          Text("VIRTUAL")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(DownmixTheme.accentSoft)
            .foregroundStyle(DownmixTheme.accent)
            .clipShape(Capsule())
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(selected ? DownmixTheme.accentSoft : Color.clear)
      )
    }
    .buttonStyle(.plain)
  }

  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 16, style: .continuous)
      .fill(DownmixTheme.card)
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(DownmixTheme.cardStroke, lineWidth: 1)
      )
  }
}
