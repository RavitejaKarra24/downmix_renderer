import SwiftUI

struct StructuredPEQEditorView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let title: String
  private let subtitle: String
  @Binding private var text: String
  private let exposesChannels: Bool
  private let swapsPreviewChannels: Bool
  private let onImport: () -> Void
  private let onExport: () -> Void

  @State private var draft: PEQEditorDraft
  @State private var rawDraft: String
  @State private var showsRawText = false
  @State private var externallyReceivedDraft: PEQEditorDraft?
  @State private var lastEmittedText: String?

  init(
    title: String,
    subtitle: String,
    text: Binding<String>,
    exposesChannels: Bool,
    swapsPreviewChannels: Bool = false,
    onImport: @escaping () -> Void,
    onExport: @escaping () -> Void
  ) {
    self.title = title
    self.subtitle = subtitle
    _text = text
    self.exposesChannels = exposesChannels
    self.swapsPreviewChannels = swapsPreviewChannels
    self.onImport = onImport
    self.onExport = onExport

    let source = text.wrappedValue
    _draft = State(initialValue: PEQEditorDraft(text: source))
    _rawDraft = State(initialValue: source)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      editorHeader
      PEQFrequencyResponseView(
        snapshot: draft.response,
        separatesChannels: exposesChannels,
        swapsChannels: swapsPreviewChannels
      )
      preampControl
      filterList
      rawTextEditor
    }
    .padding(16)
    .frame(minWidth: 470, maxWidth: .infinity, alignment: .topLeading)
    .downmixRaisedPanel()
    .onChange(of: draft) { _, newDraft in
      emitStructuredChange(newDraft)
    }
    .onChange(of: text) { _, newText in
      receiveExternalText(newText)
    }
  }

  private var editorHeader: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(title)
          .font(DownmixTheme.TypeScale.headline)
          .foregroundStyle(DownmixTheme.textPrimary)
        Spacer()
        Button(action: onImport) {
          Label("Import…", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(SecondaryButtonStyle())
        .help("Import Equalizer APO text")

        Button(action: exportRawText) {
          Label("Export…", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(SecondaryButtonStyle())
        .help("Export the current raw text")
      }

      Text(subtitle)
        .font(DownmixTheme.TypeScale.caption)
        .foregroundStyle(DownmixTheme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var preampControl: some View {
    HStack(spacing: 10) {
      Label("PEQ preamp", systemImage: "dial.low")
        .font(DownmixTheme.TypeScale.bodyStrong)
        .foregroundStyle(DownmixTheme.textPrimary)
      Spacer()
      TextField(
        "Preamp",
        value: $draft.preampDb,
        format: .number.precision(.fractionLength(0...2))
      )
      .textFieldStyle(.roundedBorder)
      .multilineTextAlignment(.trailing)
      .monospacedDigit()
      .frame(width: 72)
      .accessibilityLabel("PEQ preamp gain")
      Text("dB")
        .font(DownmixTheme.TypeScale.caption)
        .foregroundStyle(DownmixTheme.textSecondary)
      Stepper(
        "Adjust PEQ preamp",
        value: $draft.preampDb,
        in: -30...12,
        step: 0.5
      )
      .labelsHidden()
    }
    .padding(10)
    .downmixRecessedWell(cornerRadius: 10)
  }

  private var filterList: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Filters")
          .font(DownmixTheme.TypeScale.bodyStrong)
          .foregroundStyle(DownmixTheme.textPrimary)
        Text("\(draft.filters.count)")
          .font(DownmixTheme.TypeScale.label)
          .monospacedDigit()
          .foregroundStyle(DownmixTheme.textSecondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(DownmixTheme.surfaceWell, in: Capsule())
        Spacer()
        Button {
          animate {
            draft.addFilter()
          }
        } label: {
          Label("Add Filter", systemImage: "plus")
        }
        .buttonStyle(SecondaryButtonStyle())
      }

      if draft.filters.isEmpty {
        ContentUnavailableView(
          "No Filters",
          systemImage: "slider.horizontal.3",
          description: Text("Add a filter or import Equalizer APO text.")
        )
        .frame(maxWidth: .infinity, minHeight: 118)
        .downmixRecessedWell(cornerRadius: 10)
      } else {
        LazyVStack(spacing: 8) {
          ForEach($draft.filters) { $filter in
            let position = draft.filters.firstIndex(where: { $0.id == filter.id }) ?? 0
            PEQFilterRowView(
              filter: $filter,
              number: position + 1,
              exposesChannel: exposesChannels,
              canMoveUp: position > 0,
              canMoveDown: position < draft.filters.count - 1,
              onMoveUp: {
                animate { draft.moveFilter(id: filter.id, offset: -1) }
              },
              onMoveDown: {
                animate { draft.moveFilter(id: filter.id, offset: 1) }
              },
              onRemove: {
                animate { draft.removeFilter(id: filter.id) }
              }
            )
          }
        }
      }
    }
  }

  private var rawTextEditor: some View {
    DisclosureGroup(isExpanded: $showsRawText) {
      VStack(alignment: .leading, spacing: 9) {
        Text(
          "Apply reparses supported filters. Comments and unsupported directives remain in "
            + "the raw text until the next structured edit."
        )
        .font(DownmixTheme.TypeScale.caption)
        .foregroundStyle(DownmixTheme.textSecondary)

        TextEditor(text: $rawDraft)
          .font(.system(size: 12, design: .monospaced))
          .scrollContentBackground(.hidden)
          .frame(minHeight: 150)
          .padding(8)
          .downmixRecessedWell(cornerRadius: 10)
          .accessibilityLabel("\(title) raw Equalizer APO text")

        HStack {
          if rawDraft != text {
            Label("Raw edits not applied", systemImage: "circle.fill")
              .font(DownmixTheme.TypeScale.caption)
              .foregroundStyle(DownmixTheme.warn)
          }
          Spacer()
          Button("Revert") {
            rawDraft = text
          }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(rawDraft == text)

          Button("Apply Raw Text") {
            applyRawText()
          }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(rawDraft == text)
        }
      }
      .padding(.top, 9)
    } label: {
      Label("Raw text", systemImage: "chevron.left.forwardslash.chevron.right")
        .font(DownmixTheme.TypeScale.bodyStrong)
        .foregroundStyle(DownmixTheme.textPrimary)
    }
  }

  private func emitStructuredChange(_ newDraft: PEQEditorDraft) {
    if let receivedDraft = externallyReceivedDraft {
      externallyReceivedDraft = nil
      if receivedDraft == newDraft {
        return
      }
    }

    let serialized = newDraft.serializedText
    guard serialized != text else {
      rawDraft = serialized
      return
    }
    lastEmittedText = serialized
    rawDraft = serialized
    text = serialized
  }

  private func receiveExternalText(_ newText: String) {
    if newText == lastEmittedText {
      lastEmittedText = nil
      return
    }
    var receivedDraft = draft
    receivedDraft.replace(with: newText)
    externallyReceivedDraft = receivedDraft
    draft = receivedDraft
    rawDraft = newText
  }

  private func applyRawText() {
    let source = rawDraft
    lastEmittedText = source
    var receivedDraft = draft
    receivedDraft.replace(with: source)
    externallyReceivedDraft = receivedDraft
    draft = receivedDraft
    text = source
  }

  private func exportRawText() {
    if rawDraft != text {
      applyRawText()
    }
    onExport()
  }

  private func animate(_ changes: () -> Void) {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16), changes)
  }
}

private struct PEQFilterRowView: View {
  @Binding var filter: PEQFilterDraft

  let number: Int
  let exposesChannel: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let onMoveUp: () -> Void
  let onMoveDown: () -> Void
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 8) {
        Text("\(number)")
          .font(DownmixTheme.TypeScale.liveValue)
          .foregroundStyle(DownmixTheme.textSecondary)
          .frame(width: 22)

        Picker("Filter type", selection: $filter.kind) {
          ForEach(PEQFilterKind.editableKinds, id: \.self) { kind in
            Text(kind.displayName).tag(kind)
          }
        }
        .labelsHidden()
        .frame(minWidth: 118)

        if exposesChannel {
          Picker("Channel", selection: $filter.channel) {
            Text("Both").tag(PEQBand.PEQChannel.all)
            Text("Left").tag(PEQBand.PEQChannel.left)
            Text("Right").tag(PEQBand.PEQChannel.right)
            if case .index(let index) = filter.channel, index > 1 {
              Text("Channel \(index)").tag(PEQBand.PEQChannel.index(index))
            }
          }
          .labelsHidden()
          .frame(minWidth: 86)
        }

        Spacer()
        rowAction(
          systemImage: "chevron.up",
          label: "Move filter \(number) up",
          enabled: canMoveUp,
          action: onMoveUp
        )
        rowAction(
          systemImage: "chevron.down",
          label: "Move filter \(number) down",
          enabled: canMoveDown,
          action: onMoveDown
        )
        rowAction(
          systemImage: "trash",
          label: "Remove filter \(number)",
          role: .destructive,
          action: onRemove
        )
      }

      HStack(alignment: .bottom, spacing: 10) {
        PEQNumericField(
          title: "Frequency",
          unit: "Hz",
          value: $filter.frequency,
          range: 10...23_999,
          step: 1,
          fractionDigits: 0...1
        )
        PEQNumericField(
          title: "Gain",
          unit: "dB",
          value: $filter.gainDb,
          range: -30...30,
          step: 0.5,
          fractionDigits: 0...2
        )
        PEQNumericField(
          title: "Q",
          unit: "",
          value: $filter.q,
          range: 0.05...20,
          step: 0.05,
          fractionDigits: 0...2
        )
      }

      if let validationMessage = filter.validationMessage {
        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
          .font(DownmixTheme.TypeScale.caption)
          .foregroundStyle(DownmixTheme.warn)
      }
    }
    .padding(10)
    .downmixRecessedWell(cornerRadius: 10)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Filter \(number), \(filter.kind.displayName)")
  }

  private func rowAction(
    systemImage: String,
    label: String,
    role: ButtonRole? = nil,
    enabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    Button(role: role, action: action) {
      Image(systemName: systemImage)
        .frame(width: 20, height: 20)
    }
    .buttonStyle(.borderless)
    .disabled(!enabled)
    .accessibilityLabel(label)
    .help(label)
  }
}

private struct PEQNumericField: View {
  let title: String
  let unit: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  let fractionDigits: ClosedRange<Int>

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(DownmixTheme.TypeScale.label)
        .foregroundStyle(DownmixTheme.textSecondary)

      HStack(spacing: 5) {
        TextField(
          title,
          value: $value,
          format: .number.precision(.fractionLength(fractionDigits))
        )
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .frame(minWidth: 58)

        if !unit.isEmpty {
          Text(unit)
            .font(DownmixTheme.TypeScale.caption)
            .foregroundStyle(DownmixTheme.textSecondary)
        }

        Stepper(title, value: $value, in: range, step: step)
          .labelsHidden()
      }
    }
    .frame(maxWidth: .infinity)
  }
}

private struct PEQFrequencyResponseView: View {
  let snapshot: PEQResponseSnapshot
  let separatesChannels: Bool
  let swapsChannels: Bool

  private let displayRange = -18.0...18.0
  private let frequencyTicks = [20.0, 100, 1_000, 10_000, 20_000]
  private let gainTicks = [-18.0, -12, -6, 0, 6, 12, 18]

  private var drawsStereo: Bool {
    separatesChannels || snapshot.leftDb != snapshot.rightDb
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Canvas { context, size in
        var drawingContext = context
        draw(in: &drawingContext, size: size)
      }

      HStack(spacing: 10) {
        legend(color: DownmixTheme.accent, title: drawsStereo ? "L" : "Response")
        if drawsStereo {
          legend(color: DownmixTheme.heightChannel, title: "R")
        }
      }
      .padding(.top, 7)
      .padding(.trailing, 9)
    }
    .frame(height: 154)
    .downmixRecessedWell(cornerRadius: 10)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Frequency response preview")
    .accessibilityValue(
      "\(drawsStereo ? "Left and right channels" : "Combined response"), "
        + snapshot.rangeDescription
    )
  }

  private func legend(color: Color, title: String) -> some View {
    HStack(spacing: 4) {
      Capsule()
        .fill(color)
        .frame(width: 13, height: 3)
      Text(title)
        .font(DownmixTheme.TypeScale.label)
        .foregroundStyle(DownmixTheme.textSecondary)
    }
  }

  private func draw(in context: inout GraphicsContext, size: CGSize) {
    let plot = CGRect(
      x: 33,
      y: 9,
      width: max(size.width - 43, 1),
      height: max(size.height - 29, 1)
    )

    drawGrid(in: &context, plot: plot)

    var clipped = context
    clipped.clip(to: Path(plot))
    drawCurve(
      swapsChannels ? snapshot.rightDb : snapshot.leftDb,
      frequencies: snapshot.frequencies,
      color: DownmixTheme.accent,
      in: &clipped,
      plot: plot
    )
    if drawsStereo {
      drawCurve(
        swapsChannels ? snapshot.leftDb : snapshot.rightDb,
        frequencies: snapshot.frequencies,
        color: DownmixTheme.heightChannel,
        in: &clipped,
        plot: plot
      )
    }
  }

  private func drawGrid(in context: inout GraphicsContext, plot: CGRect) {
    for gain in gainTicks {
      let y = yPosition(for: gain, plot: plot)
      var path = Path()
      path.move(to: CGPoint(x: plot.minX, y: y))
      path.addLine(to: CGPoint(x: plot.maxX, y: y))
      context.stroke(
        path,
        with: .color(
          gain == 0 ? DownmixTheme.textSecondary.opacity(0.45) : DownmixTheme.cardStroke
        ),
        lineWidth: gain == 0 ? 1.2 : 0.7
      )
      context.draw(
        Text(gainLabel(gain))
          .font(DownmixTheme.TypeScale.label)
          .foregroundStyle(DownmixTheme.textSecondary),
        at: CGPoint(x: plot.minX - 5, y: y),
        anchor: .trailing
      )
    }

    for frequency in frequencyTicks {
      let x = xPosition(for: frequency, plot: plot)
      var path = Path()
      path.move(to: CGPoint(x: x, y: plot.minY))
      path.addLine(to: CGPoint(x: x, y: plot.maxY))
      context.stroke(path, with: .color(DownmixTheme.cardStroke), lineWidth: 0.7)
      context.draw(
        Text(frequencyLabel(frequency))
          .font(DownmixTheme.TypeScale.label)
          .foregroundStyle(DownmixTheme.textSecondary),
        at: CGPoint(x: x, y: plot.maxY + 10),
        anchor: .center
      )
    }
  }

  private func drawCurve(
    _ values: [Double],
    frequencies: [Double],
    color: Color,
    in context: inout GraphicsContext,
    plot: CGRect
  ) {
    guard values.count == frequencies.count, !values.isEmpty else { return }
    var path = Path()
    for index in values.indices {
      let point = CGPoint(
        x: xPosition(for: frequencies[index], plot: plot),
        y: yPosition(for: values[index], plot: plot)
      )
      if index == values.startIndex {
        path.move(to: point)
      } else {
        path.addLine(to: point)
      }
    }
    context.stroke(
      path,
      with: .color(color),
      style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
    )
  }

  private func xPosition(for frequency: Double, plot: CGRect) -> CGFloat {
    let minimum = log10(PEQResponseCalculator.minimumFrequency)
    let span = log10(PEQResponseCalculator.maximumFrequency) - minimum
    let fraction = (log10(max(frequency, 1)) - minimum) / span
    return plot.minX + CGFloat(fraction) * plot.width
  }

  private func yPosition(for gain: Double, plot: CGRect) -> CGFloat {
    let clamped = min(max(gain, displayRange.lowerBound), displayRange.upperBound)
    let fraction =
      (displayRange.upperBound - clamped)
      / (displayRange.upperBound - displayRange.lowerBound)
    return plot.minY + CGFloat(fraction) * plot.height
  }

  private func gainLabel(_ gain: Double) -> String {
    gain > 0 ? "+\(Int(gain))" : "\(Int(gain))"
  }

  private func frequencyLabel(_ frequency: Double) -> String {
    switch frequency {
    case 1_000: "1k"
    case 10_000: "10k"
    case 20_000: "20k"
    default: "\(Int(frequency))"
    }
  }
}

extension PEQFilterKind {
  fileprivate static let editableKinds: [PEQFilterKind] = [.peaking, .lowShelf, .highShelf]

  fileprivate var displayName: String {
    switch self {
    case .peaking: "Peaking"
    case .lowShelf: "Low shelf"
    case .highShelf: "High shelf"
    case .off: "Off"
    }
  }
}
