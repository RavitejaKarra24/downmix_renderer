import SwiftUI

struct EQProfileManagerView: View {
  @Environment(AppState.self) private var state
  @State private var profileName = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(spacing: 10) {
        Text("Profiles")
          .font(DownmixTheme.TypeScale.headline)
          .foregroundStyle(DownmixTheme.textPrimary)

        profileStatus
        Spacer()

        Picker("Saved profile", selection: activeProfileBinding) {
          Text("None").tag(Optional<UUID>.none)
          ForEach(state.preferences.eqProfiles) { profile in
            Text(profileLabel(profile)).tag(Optional(profile.id))
          }
        }
        .frame(width: 220)
      }

      HStack(spacing: 9) {
        TextField("Profile name", text: $profileName)
          .textFieldStyle(.roundedBorder)
          .frame(minWidth: 170, maxWidth: 240)

        Button("Save as New") {
          saveAsNewProfile()
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(trimmedProfileName.isEmpty)

        Button("Save Changes") {
          saveActiveProfile()
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(activeProfile == nil || !isActiveProfileModified)

        Button("Rename") {
          renameActiveProfile()
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(
          activeProfile == nil
            || trimmedProfileName.isEmpty
            || trimmedProfileName == activeProfile?.name
        )

        Button {
          duplicateActiveProfile()
        } label: {
          Label("Duplicate", systemImage: "plus.square.on.square")
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(activeProfile == nil)

        Spacer()

        profileOrderButton(
          systemImage: "chevron.up",
          label: "Move profile up",
          offset: -1
        )
        profileOrderButton(
          systemImage: "chevron.down",
          label: "Move profile down",
          offset: 1
        )

        Button(role: .destructive) {
          deleteActiveProfile()
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(activeProfile == nil)
      }
    }
    .padding(14)
    .downmixRaisedPanel()
    .onAppear {
      profileName = activeProfile?.name ?? ""
    }
  }

  private var profileStatus: some View {
    let status: (title: String, color: Color, symbol: String)
    if activeProfile == nil {
      status = ("No saved profile", DownmixTheme.textSecondary, "circle")
    } else if isActiveProfileModified {
      status = ("Modified", DownmixTheme.warn, "circle.fill")
    } else {
      status = ("Saved", DownmixTheme.good, "checkmark.circle.fill")
    }

    return Label(status.title, systemImage: status.symbol)
      .font(DownmixTheme.TypeScale.caption)
      .foregroundStyle(status.color)
      .accessibilityLabel("Profile status: \(status.title)")
  }

  private var activeProfileBinding: Binding<UUID?> {
    Binding(
      get: { state.preferences.activeEQProfileID },
      set: { id in
        state.preferences.activeEQProfileID = id
        guard let id,
          let profile = state.preferences.eqProfiles.first(where: { $0.id == id })
        else {
          profileName = ""
          state.persist()
          return
        }
        profileName = profile.name
        apply(profile)
      }
    )
  }

  private var activeProfile: EQProfile? {
    guard let id = state.preferences.activeEQProfileID else { return nil }
    return state.preferences.eqProfiles.first { $0.id == id }
  }

  private var activeProfileIndex: Int? {
    guard let id = state.preferences.activeEQProfileID else { return nil }
    return state.preferences.eqProfiles.firstIndex { $0.id == id }
  }

  private var isActiveProfileModified: Bool {
    guard let profile = activeProfile else { return false }
    return profile.swapOutputs != state.preferences.swapOutputs
      || profile.globalPEQText != state.preferences.globalPEQText
      || profile.speakerPEQText != state.preferences.speakerPEQText
  }

  private var trimmedProfileName: String {
    profileName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func profileLabel(_ profile: EQProfile) -> String {
    if profile.id == state.preferences.activeEQProfileID, isActiveProfileModified {
      return "\(profile.name) •"
    }
    return profile.name
  }

  private func profileOrderButton(
    systemImage: String,
    label: String,
    offset: Int
  ) -> some View {
    let enabled: Bool
    if let index = activeProfileIndex {
      enabled = state.preferences.eqProfiles.indices.contains(index + offset)
    } else {
      enabled = false
    }

    return Button {
      moveActiveProfile(offset: offset)
    } label: {
      Image(systemName: systemImage)
        .frame(width: 20, height: 20)
    }
    .buttonStyle(.borderless)
    .disabled(!enabled)
    .accessibilityLabel(label)
    .help(label)
  }

  private func saveAsNewProfile() {
    guard !trimmedProfileName.isEmpty else { return }
    let profile = EQProfile(
      name: uniqueName(trimmedProfileName),
      swapOutputs: state.preferences.swapOutputs,
      globalPEQText: state.preferences.globalPEQText,
      speakerPEQText: state.preferences.speakerPEQText
    )
    state.preferences.eqProfiles.append(profile)
    state.preferences.activeEQProfileID = profile.id
    profileName = profile.name
    state.persist()
  }

  private func saveActiveProfile() {
    guard let index = activeProfileIndex else { return }
    state.preferences.eqProfiles[index].swapOutputs = state.preferences.swapOutputs
    state.preferences.eqProfiles[index].globalPEQText = state.preferences.globalPEQText
    state.preferences.eqProfiles[index].speakerPEQText = state.preferences.speakerPEQText
    state.persist()
  }

  private func renameActiveProfile() {
    guard let index = activeProfileIndex, !trimmedProfileName.isEmpty else { return }
    let id = state.preferences.eqProfiles[index].id
    let name = uniqueName(trimmedProfileName, excluding: id)
    state.preferences.eqProfiles[index].name = name
    profileName = name
    state.persist()
  }

  private func duplicateActiveProfile() {
    guard let index = activeProfileIndex else { return }
    var duplicate = state.preferences.eqProfiles[index]
    duplicate.id = UUID()
    duplicate.name = uniqueName("\(duplicate.name) Copy")
    state.preferences.eqProfiles.insert(duplicate, at: index + 1)
    state.preferences.activeEQProfileID = duplicate.id
    profileName = duplicate.name
    state.persist()
  }

  private func moveActiveProfile(offset: Int) {
    guard let source = activeProfileIndex else { return }
    let destination = source + offset
    guard state.preferences.eqProfiles.indices.contains(destination) else { return }
    state.preferences.eqProfiles.swapAt(source, destination)
    state.persist()
  }

  private func deleteActiveProfile() {
    guard let index = activeProfileIndex else { return }
    state.preferences.eqProfiles.remove(at: index)
    state.preferences.activeEQProfileID = nil
    profileName = ""
    state.persist()
  }

  private func apply(_ profile: EQProfile) {
    state.preferences.swapOutputs = profile.swapOutputs
    state.preferences.globalPEQText = profile.globalPEQText
    state.preferences.speakerPEQText = profile.speakerPEQText
    state.persist()
  }

  private func uniqueName(_ requested: String, excluding excludedID: UUID? = nil) -> String {
    let existingNames = Set(
      state.preferences.eqProfiles
        .filter { $0.id != excludedID }
        .map { $0.name.lowercased() }
    )
    guard existingNames.contains(requested.lowercased()) else { return requested }

    var suffix = 2
    while existingNames.contains("\(requested) \(suffix)".lowercased()) {
      suffix += 1
    }
    return "\(requested) \(suffix)"
  }
}
