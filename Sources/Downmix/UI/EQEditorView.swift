import SwiftUI
import UniformTypeIdentifiers

struct EQEditorView: View {
  @Environment(AppState.self) private var state
  @Environment(\.dismiss) private var dismiss

  @State private var importingGlobalPEQ = false
  @State private var importingSpeakerPEQ = false
  @State private var exportingGlobalPEQ = false
  @State private var exportingSpeakerPEQ = false

  var body: some View {
    @Bindable var state = state

    VStack(spacing: 0) {
      header

      Divider()
        .opacity(0.35)

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          EQProfileManagerView()

          HStack(alignment: .top, spacing: 16) {
            StructuredPEQEditorView(
              title: "User / global PEQ",
              subtitle: "Applied to both channels before L/R swap.",
              text: $state.preferences.globalPEQText,
              exposesChannels: false,
              onImport: { importingGlobalPEQ = true },
              onExport: { exportingGlobalPEQ = true }
            )

            StructuredPEQEditorView(
              title: "Stereo speaker EQ",
              subtitle: "Per-channel correction applied after swap to physical outputs.",
              text: $state.preferences.speakerPEQText,
              exposesChannels: true,
              swapsPreviewChannels: state.preferences.swapOutputs,
              onImport: { importingSpeakerPEQ = true },
              onExport: { exportingSpeakerPEQ = true }
            )
          }

          Label(
            "Supported filters: PK/PEQ, LS/LSC, HS/HSC. OFF and Xfeed lines are ignored.",
            systemImage: "info.circle"
          )
          .font(DownmixTheme.TypeScale.caption)
          .foregroundStyle(DownmixTheme.textSecondary)
        }
        .padding(20)
      }
    }
    .frame(minWidth: 1_000, minHeight: 650)
    .background(DownmixTheme.backgroundGradient)
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
    .fileExporter(
      isPresented: $exportingGlobalPEQ,
      document: PEQTextFile(text: state.preferences.globalPEQText),
      contentType: .plainText,
      defaultFilename: "Downmix-Global-PEQ.txt"
    ) { result in
      handleExport(result)
    }
    .fileExporter(
      isPresented: $exportingSpeakerPEQ,
      document: PEQTextFile(text: state.preferences.speakerPEQText),
      contentType: .plainText,
      defaultFilename: "Downmix-Speaker-PEQ.txt"
    ) { result in
      handleExport(result)
    }
    .onDisappear {
      state.persist()
    }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text("Output EQ")
          .font(DownmixTheme.TypeScale.title)
          .foregroundStyle(DownmixTheme.textPrimary)
        Text("DSP order: matrix + preamp → User PEQ → L/R swap → Speaker EQ")
          .font(DownmixTheme.TypeScale.caption)
          .foregroundStyle(DownmixTheme.textSecondary)
      }
      Spacer()
      Button("Done") {
        state.persist()
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
      .buttonStyle(SecondaryButtonStyle())
    }
    .padding(20)
    .background(.ultraThinMaterial)
  }

  private func importPEQ(
    _ result: Result<URL, Error>,
    destination: WritableKeyPath<AppPreferences, String>
  ) {
    do {
      let url = try result.get()
      let granted = url.startAccessingSecurityScopedResource()
      defer {
        if granted {
          url.stopAccessingSecurityScopedResource()
        }
      }
      state.preferences[keyPath: destination] = try String(contentsOf: url, encoding: .utf8)
      state.persist()
    } catch {
      state.errorMessage = "Could not import PEQ file: \(error.localizedDescription)"
    }
  }

  private func handleExport(_ result: Result<URL, Error>) {
    if case .failure(let error) = result {
      state.errorMessage = "Could not export PEQ file: \(error.localizedDescription)"
    }
  }
}

private struct PEQTextFile: FileDocument {
  static var readableContentTypes: [UTType] { [.plainText] }

  var text: String

  init(text: String) {
    self.text = text
  }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      text = ""
      return
    }
    text = String(decoding: data, as: UTF8.self)
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}
