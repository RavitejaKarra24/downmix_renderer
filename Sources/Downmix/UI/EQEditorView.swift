import SwiftUI
import UniformTypeIdentifiers

struct EQEditorView: View {
  @Environment(AppState.self) private var state
  @Environment(\.dismiss) private var dismiss
  @State private var profileName = ""
  @State private var importingGlobalPEQ = false
  @State private var importingSpeakerPEQ = false

  var body: some View {
    @Bindable var state = state

    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Output EQ")
            .font(.title2.weight(.bold))
          Text("DSP order: matrix + preamp → User PEQ → L/R swap → Speaker EQ")
            .font(.caption)
            .foregroundStyle(DownmixTheme.textSecondary)
        }
        Spacer()
        Button("Done") {
          state.persist()
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding(20)

      Divider().opacity(0.2)

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          profileBar

          HStack(alignment: .top, spacing: 16) {
            peqBox(
              title: "User / global PEQ",
              text: $state.preferences.globalPEQText,
              placeholder:
                "Paste Equalizer APO / Peace PEQ text.\nApplied to both channels before L/R swap.",
              onImport: { importingGlobalPEQ = true }
            )
            peqBox(
              title: "Stereo speaker EQ",
              text: $state.preferences.speakerPEQText,
              placeholder:
                "CH:0 / Channel:L and CH:1 / Channel:R sections supported.\nApplied after swap to physical outputs.",
              onImport: { importingSpeakerPEQ = true }
            )
          }

          Text("Supported filters: PK/PEQ, LS/LSC, HS/HSC. OFF and Xfeed lines are ignored.")
            .font(.caption)
            .foregroundStyle(DownmixTheme.textSecondary)
        }
        .padding(20)
      }
    }
    .background(DownmixTheme.bg)
    .preferredColorScheme(.dark)
    .fileImporter(
      isPresented: $importingGlobalPEQ,
      allowedContentTypes: [.plainText, .data]
    ) { result in
      importPEQ(result, destination: \AppPreferences.globalPEQText)
    }
    .fileImporter(
      isPresented: $importingSpeakerPEQ,
      allowedContentTypes: [.plainText, .data]
    ) { result in
      importPEQ(result, destination: \AppPreferences.speakerPEQText)
    }
    .onDisappear { state.persist() }
  }

  private var profileBar: some View {
    @Bindable var state = state

    return VStack(alignment: .leading, spacing: 10) {
      Text("Profiles")
        .font(.headline)
      HStack(spacing: 10) {
        Picker(
          "Saved",
          selection: Binding(
            get: { state.preferences.activeEQProfileID },
            set: { id in
              state.preferences.activeEQProfileID = id
              if let id, let profile = state.preferences.eqProfiles.first(where: { $0.id == id }) {
                apply(profile)
              }
            }
          )
        ) {
          Text("None").tag(Optional<UUID>.none)
          ForEach(state.preferences.eqProfiles) { profile in
            Text(profile.name).tag(Optional(profile.id))
          }
        }
        .frame(maxWidth: 220)

        TextField("Profile name", text: $profileName)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 200)

        Button("Save") { saveProfile() }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        Button("Delete") { deleteActiveProfile() }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(state.preferences.activeEQProfileID == nil)
      }
    }
    .padding(14)
    .background(card)
  }

  private func peqBox(
    title: String,
    text: Binding<String>,
    placeholder: String,
    onImport: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(title)
          .font(.headline)
        Spacer()
        Button("Import…", action: onImport)
          .buttonStyle(SecondaryButtonStyle())
        Button("Clear") { text.wrappedValue = "" }
          .buttonStyle(SecondaryButtonStyle())
      }
      ZStack(alignment: .topLeading) {
        if text.wrappedValue.isEmpty {
          Text(placeholder)
            .font(.caption)
            .foregroundStyle(DownmixTheme.textSecondary.opacity(0.8))
            .padding(.top, 8)
            .padding(.leading, 6)
        }
        TextEditor(text: text)
          .font(.system(.body, design: .monospaced))
          .scrollContentBackground(.hidden)
          .frame(minHeight: 280)
      }
      .padding(8)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.black.opacity(0.35))
      )
    }
    .padding(14)
    .background(card)
    .frame(maxWidth: .infinity)
  }

  private func importPEQ(
    _ result: Result<URL, Error>,
    destination: WritableKeyPath<AppPreferences, String>
  ) {
    do {
      let url = try result.get()
      let granted = url.startAccessingSecurityScopedResource()
      defer {
        if granted { url.stopAccessingSecurityScopedResource() }
      }
      state.preferences[keyPath: destination] = try String(contentsOf: url, encoding: .utf8)
      state.persist()
    } catch {
      state.errorMessage = "Could not import PEQ file: \(error.localizedDescription)"
    }
  }

  private func saveProfile() {
    let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    let profile = EQProfile(
      name: name,
      swapOutputs: state.preferences.swapOutputs,
      globalPEQText: state.preferences.globalPEQText,
      speakerPEQText: state.preferences.speakerPEQText
    )
    state.preferences.eqProfiles.removeAll { $0.name == name }
    state.preferences.eqProfiles.append(profile)
    state.preferences.activeEQProfileID = profile.id
    profileName = ""
    state.persist()
  }

  private func deleteActiveProfile() {
    guard let id = state.preferences.activeEQProfileID else { return }
    state.preferences.eqProfiles.removeAll { $0.id == id }
    state.preferences.activeEQProfileID = nil
    state.persist()
  }

  private func apply(_ profile: EQProfile) {
    state.preferences.swapOutputs = profile.swapOutputs
    state.preferences.globalPEQText = profile.globalPEQText
    state.preferences.speakerPEQText = profile.speakerPEQText
    state.persist()
  }

  private var card: some View {
    RoundedRectangle(cornerRadius: 16, style: .continuous)
      .fill(DownmixTheme.card)
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(DownmixTheme.cardStroke, lineWidth: 1)
      )
  }
}
