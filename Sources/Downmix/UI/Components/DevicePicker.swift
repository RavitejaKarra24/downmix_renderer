import CoreAudio
import SwiftUI

struct DevicePickerCard: View {
  let title: String
  let devices: [AudioDeviceInfo]
  let selectedID: AudioDeviceID?
  let emptyHint: String
  let onSelect: (AudioDeviceInfo) -> Void

  @AppStorage("downmix.favoriteDeviceUIDs") private var favoriteDeviceUIDs = ""
  @State private var searchText = ""

  private var favoriteUIDs: [String] {
    favoriteDeviceUIDs.split(separator: "\n").map(String.init)
  }

  private var visibleDevices: [AudioDeviceInfo] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered =
      query.isEmpty
      ? devices
      : devices.filter {
        $0.name.localizedCaseInsensitiveContains(query)
          || $0.subtitle.localizedCaseInsensitiveContains(query)
      }
    let favorites = favoriteUIDs
    return filtered.sorted { lhs, rhs in
      let lhsIndex = favorites.firstIndex(of: lhs.uid)
      let rhsIndex = favorites.firstIndex(of: rhs.uid)
      switch (lhsIndex, rhsIndex) {
      case (let left?, let right?):
        return left == right
          ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
          : left < right
      case (.some, nil):
        return true
      case (nil, .some):
        return false
      case (nil, nil):
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Text(title)
          .font(DownmixTheme.TypeScale.headline)
          .foregroundStyle(DownmixTheme.textPrimary)
        Text("\(devices.count)")
          .font(DownmixTheme.TypeScale.label.monospacedDigit())
          .foregroundStyle(DownmixTheme.textSecondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(DownmixTheme.surfaceWell, in: Capsule())
        Spacer()
        if let selected = devices.first(where: { $0.id == selectedID }) {
          Label("Connected", systemImage: "checkmark.circle.fill")
            .font(DownmixTheme.TypeScale.label)
            .foregroundStyle(DownmixTheme.good)
            .labelStyle(.titleAndIcon)
            .accessibilityLabel("\(selected.name) connected")
        }
      }

      if devices.count > 3 || !searchText.isEmpty {
        Label {
          TextField("Filter devices", text: $searchText)
            .textFieldStyle(.plain)
        } icon: {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(DownmixTheme.textSecondary)
        }
        .font(DownmixTheme.TypeScale.body)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .downmixRecessedWell(cornerRadius: 9)
      }

      if devices.isEmpty {
        ContentUnavailableView {
          Label("No \(title.lowercased()) devices", systemImage: "waveform.slash")
        } description: {
          Text(emptyHint)
        }
        .foregroundStyle(DownmixTheme.textSecondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
      } else if visibleDevices.isEmpty {
        Text("No devices match “\(searchText)”.")
          .font(DownmixTheme.TypeScale.body)
          .foregroundStyle(DownmixTheme.textSecondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
      } else {
        VStack(spacing: 6) {
          ForEach(visibleDevices) { device in
            deviceRow(device)
              .draggable(device.uid)
              .dropDestination(for: String.self) { uids, _ in
                guard let uid = uids.first else { return false }
                moveFavorite(uid, before: device.uid)
                return true
              }
          }
        }
      }
    }
    .padding(14)
    .downmixRaisedPanel()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(title) device picker")
  }

  private func deviceRow(_ device: AudioDeviceInfo) -> some View {
    let selected = device.id == selectedID
    let isVirtual = device.name.localizedCaseInsensitiveContains("blackhole")
    let isFavorite = favoriteUIDs.contains(device.uid)

    return Button {
      onSelect(device)
    } label: {
      HStack(spacing: 10) {
        ZStack {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? DownmixTheme.accentSoft : DownmixTheme.surfaceWell)
            .frame(width: 34, height: 34)
          Image(systemName: symbol(for: device, isVirtual: isVirtual))
            .font(.system(size: 14, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(selected ? DownmixTheme.accent : DownmixTheme.textSecondary)
        }

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 5) {
            Text(device.name)
              .font(
                selected ? DownmixTheme.TypeScale.bodyStrong : DownmixTheme.TypeScale.body
              )
              .foregroundStyle(DownmixTheme.textPrimary)
              .lineLimit(1)
            if isFavorite {
              Image(systemName: "pin.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(DownmixTheme.accent)
                .accessibilityLabel("Favorite")
            }
          }
          HStack(spacing: 5) {
            badge(
              channelBadge(for: device),
              warning: title == "Input" && device.inputChannelCount < 16
            )
            if device.nominalSampleRate > 0 {
              badge(
                String(format: "%.1f kHz", device.nominalSampleRate / 1_000),
                warning: abs(device.nominalSampleRate - 48_000) > 1
              )
            }
            if isVirtual {
              badge("VIRTUAL", accent: true)
            }
            if let warning = healthWarning(for: device) {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DownmixTheme.warn)
                .help(warning)
                .accessibilityLabel(warning)
            }
          }
        }

        Spacer(minLength: 0)

        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(selected ? DownmixTheme.accent : DownmixTheme.textSecondary.opacity(0.5))
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
      .padding(.horizontal, 9)
      .padding(.vertical, 7)
      .background(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .fill(selected ? DownmixTheme.accentSoft : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .stroke(selected ? DownmixTheme.accent.opacity(0.32) : Color.clear, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button {
        toggleFavorite(device.uid)
      } label: {
        Label(
          isFavorite ? "Remove from Favorites" : "Add to Favorites",
          systemImage: isFavorite ? "pin.slash" : "pin"
        )
      }
    }
    .accessibilityLabel(
      "\(device.name), \(device.subtitle)\(selected ? ", selected and connected" : "")"
    )
    .accessibilityHint(
      healthWarning(for: device)
        .map { "\($0) Selects this device. Drag to reorder favorites." }
        ?? "Selects this device. Drag to reorder favorites."
    )
  }

  private func badge(
    _ text: String,
    accent: Bool = false,
    warning: Bool = false
  ) -> some View {
    let foreground =
      warning ? DownmixTheme.warn : (accent ? DownmixTheme.accent : DownmixTheme.textSecondary)
    let background =
      warning
      ? DownmixTheme.warn.opacity(0.12)
      : (accent ? DownmixTheme.accentSoft : DownmixTheme.surfaceWell.opacity(0.78))

    return Text(text)
      .font(DownmixTheme.TypeScale.label.monospacedDigit())
      .foregroundStyle(foreground)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(background, in: Capsule())
  }

  private func symbol(for device: AudioDeviceInfo, isVirtual: Bool) -> String {
    if isVirtual { return "square.stack.3d.up.fill" }
    if device.inputChannelCount > 0, device.outputChannelCount > 0 {
      return "waveform.path.ecg"
    }
    if device.inputChannelCount > 0 { return "mic.fill" }
    return "speaker.wave.2.fill"
  }

  private func channelBadge(for device: AudioDeviceInfo) -> String {
    if title == "Input" {
      return "\(device.inputChannelCount) ch"
    }
    return "\(device.outputChannelCount) ch"
  }

  private func healthWarning(for device: AudioDeviceInfo) -> String? {
    var warnings: [String] = []
    if title == "Input", device.inputChannelCount < 16 {
      warnings.append("Downmix rendering requires a 16-channel input")
    }
    if device.nominalSampleRate > 0, abs(device.nominalSampleRate - 48_000) > 1 {
      warnings.append("The audio engine requires a 48 kHz sample rate")
    }
    return warnings.isEmpty ? nil : warnings.joined(separator: ". ")
  }

  private func toggleFavorite(_ uid: String) {
    var favorites = favoriteUIDs
    if let index = favorites.firstIndex(of: uid) {
      favorites.remove(at: index)
    } else {
      favorites.append(uid)
    }
    favoriteDeviceUIDs = favorites.joined(separator: "\n")
  }

  private func moveFavorite(_ uid: String, before targetUID: String) {
    guard uid != targetUID else { return }
    var favorites = favoriteUIDs
    favorites.removeAll { $0 == uid }
    if let targetIndex = favorites.firstIndex(of: targetUID) {
      favorites.insert(uid, at: targetIndex)
    } else {
      favorites.append(uid)
    }
    favoriteDeviceUIDs = favorites.joined(separator: "\n")
  }
}
