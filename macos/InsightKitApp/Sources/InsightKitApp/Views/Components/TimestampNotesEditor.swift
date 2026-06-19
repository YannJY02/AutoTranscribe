import AppKit
import SwiftUI

struct TimestampNotesEditor<DataSource: NotesEditorDataSource>: View {
    @ObservedObject var dataSource: DataSource
    let autofocusInput: Bool
    let autoScrollToPlaybackTime: Bool
    @State private var newNoteText = ""
    @State private var isNoteInputFocused = false
    @State private var submitAttempts = 0
    @State private var lastSubmittedText = ""
    private let isUITestingMode = ProcessInfo.processInfo.environment["INSIGHTKIT_UI_TEST_MODE"] == "1"

    init(
        dataSource: DataSource,
        autofocusInput: Bool = true,
        autoScrollToPlaybackTime: Bool = true
    ) {
        self.dataSource = dataSource
        self.autofocusInput = autofocusInput
        self.autoScrollToPlaybackTime = autoScrollToPlaybackTime
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InsightSpacing.sm) {
            Text("笔记")
                .font(InsightTypography.heading)
                .foregroundStyle(InsightTheme.textPrimary)
                .padding(.horizontal, InsightSpacing.lg)
                .padding(.top, InsightSpacing.lg)
                .accessibilityIdentifier("live_notes_title")

            Text("\(dataSource.notes.count)")
                .font(.caption2)
                .foregroundStyle(.clear)
                .accessibilityIdentifier("live_notes_count")
                .accessibilityHidden(!isUITestingMode)

            Text(newNoteText)
                .font(.caption2)
                .foregroundStyle(.clear)
                .accessibilityIdentifier("live_note_draft_text")
                .accessibilityHidden(!isUITestingMode)

            Text("\(submitAttempts)")
                .font(.caption2)
                .foregroundStyle(.clear)
                .accessibilityIdentifier("live_note_submit_count")
                .accessibilityHidden(!isUITestingMode)

            Text(lastSubmittedText)
                .font(.caption2)
                .foregroundStyle(.clear)
                .accessibilityIdentifier("live_note_last_submitted_text")
                .accessibilityHidden(!isUITestingMode)

            if dataSource.notes.isEmpty && !dataSource.isEditable {
                Spacer()
                Text("录制开始后可记录笔记")
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("live_notes_empty_locked")
                Spacer()
            } else {
                if dataSource.notes.isEmpty {
                    Text("录制中，可在下方输入笔记")
                        .font(InsightTypography.caption)
                        .foregroundStyle(InsightTheme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, InsightSpacing.lg)
                        .accessibilityIdentifier("live_notes_empty_editable")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: InsightSpacing.sm) {
                                ForEach(Array(dataSource.notes.enumerated()), id: \.element.id) { index, note in
                                    noteRow(note, index: index)
                                        .id(note.id)
                                }
                            }
                            .padding(.horizontal, InsightSpacing.lg)
                        }
                        .onChange(of: dataSource.currentPlaybackTime) { _ in
                            guard autoScrollToPlaybackTime else { return }
                            if let time = dataSource.currentPlaybackTime,
                               let closest = dataSource.notes.min(by: {
                                   abs($0.timestamp - time) < abs($1.timestamp - time)
                               }) {
                                proxy.scrollTo(closest.id, anchor: .center)
                            }
                        }
                    }
                }

                Spacer()

                if dataSource.isEditable {
                    Divider()
                        .padding(.horizontal, InsightSpacing.lg)
                    HStack(spacing: InsightSpacing.sm) {
                        NotesInputField(
                            text: $newNoteText,
                            isFocused: $isNoteInputFocused,
                            placeholder: "输入笔记...",
                            accessibilityIdentifier: "live_note_input",
                            onSubmit: submitNote
                        )
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .onAppear {
                            isNoteInputFocused = autofocusInput
                        }
                        Button {
                            submitNote()
                        } label: {
                            Label("提交", systemImage: "arrow.up.circle.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(InsightTheme.accent)
                        .controlSize(.small)
                        .disabled(newNoteText.isEmpty)
                        .accessibilityIdentifier("live_note_submit_button")
                    }
                    .padding(.horizontal, InsightSpacing.lg)
                    .padding(.bottom, InsightSpacing.lg)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func noteRow(_ note: TimestampedNote, index: Int) -> some View {
        let isHighlighted = isNoteHighlighted(note)
        return Button {
            dataSource.onNoteTapped(note)
        } label: {
            VStack(alignment: .leading, spacing: InsightSpacing.xs) {
                Text(note.text)
                    .font(InsightTypography.noteBody)
                    .foregroundStyle(InsightTheme.textPrimary)
                Text(formatTimestamp(note.timestamp))
                    .font(InsightTypography.noteTimestamp)
                    .foregroundStyle(InsightTheme.textTertiary)
            }
            .padding(InsightSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHighlighted ? InsightTheme.accentLight : InsightTheme.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("live_note_row_\(index)")
        .accessibilityLabel(note.text)
        .accessibilityValue(formatTimestamp(note.timestamp))
    }

    private func isNoteHighlighted(_ note: TimestampedNote) -> Bool {
        guard let time = dataSource.currentPlaybackTime else { return false }
        return abs(note.timestamp - time) < 3.0
    }

    private func submitNote() {
        guard !newNoteText.isEmpty else { return }
        submitAttempts += 1
        lastSubmittedText = newNoteText
        let time = dataSource.currentPlaybackTime ?? dataSource.recordingTime
        dataSource.onNoteCreated(newNoteText, at: time)
        newNoteText = ""
        isNoteInputFocused = !isUITestingMode
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d ⏱", mins, secs)
    }
}

private struct NotesInputField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let accessibilityIdentifier: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> FocusAwareTextField {
        let textField = FocusAwareTextField()
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.isEditable = true
        textField.isSelectable = true
        textField.focusRingType = .default
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.lineBreakMode = .byTruncatingTail
        textField.usesSingleLineMode = true
        textField.placeholderString = placeholder
        textField.delegate = context.coordinator
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.submit)
        textField.wantsFocus = isFocused
        textField.onFocusChanged = { focused in
            DispatchQueue.main.async {
                context.coordinator.isFocused = focused
            }
        }
        textField.setAccessibilityIdentifier(accessibilityIdentifier)
        return textField
    }

    func updateNSView(_ nsView: FocusAwareTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
        if nsView.wantsFocus != isFocused {
            nsView.wantsFocus = isFocused
            nsView.applyPendingFocus()
        }
        nsView.onFocusChanged = { focused in
            DispatchQueue.main.async {
                if context.coordinator.isFocused != focused {
                    context.coordinator.isFocused = focused
                }
            }
        }

        guard isFocused || nsView.currentEditor() != nil || nsView.window?.firstResponder as AnyObject? === nsView else {
            return
        }
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let editor = nsView.currentEditor()
            let hasFocus = editor != nil || window.firstResponder as AnyObject? === nsView

            if isFocused && !hasFocus {
                nsView.beginEditing()
            } else if !isFocused, hasFocus {
                window.makeFirstResponder(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        @Binding var isFocused: Bool
        let onSubmit: () -> Void

        init(text: Binding<String>, isFocused: Binding<Bool>, onSubmit: @escaping () -> Void) {
            _text = text
            _isFocused = isFocused
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text = textField.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isFocused = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isFocused = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                submit()
                return true
            }
            return false
        }

        @objc func submit() {
            onSubmit()
        }
    }
}

private final class FocusAwareTextField: NSTextField {
    var onFocusChanged: ((Bool) -> Void)?
    var wantsFocus = false

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPendingFocus()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyPendingFocus()
    }

    override func becomeFirstResponder() -> Bool {
        let focused = super.becomeFirstResponder()
        if focused {
            currentEditor()?.selectedRange = NSRange(location: stringValue.count, length: 0)
            onFocusChanged?(true)
        }
        return focused
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChanged?(false)
        }
        return resigned
    }

    func applyPendingFocus() {
        guard wantsFocus, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.beginEditing()
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        beginEditing()
    }

    func beginEditing() {
        guard let window else {
            wantsFocus = true
            return
        }

        if currentEditor() == nil {
            window.makeFirstResponder(self)
            selectText(nil)
        } else {
            currentEditor()?.selectedRange = NSRange(location: stringValue.count, length: 0)
        }
    }
}
