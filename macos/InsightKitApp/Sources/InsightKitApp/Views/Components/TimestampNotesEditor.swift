import SwiftUI

struct TimestampNotesEditor<DataSource: NotesEditorDataSource>: View {
    @ObservedObject var dataSource: DataSource
    let autofocusInput: Bool
    let autoScrollToPlaybackTime: Bool
    @State private var newNoteText = ""
    @FocusState private var isNoteInputFocused: Bool
    @State private var submitAttempts = 0
    @State private var lastSubmittedText = ""
    private let isUITestingMode = ProcessInfo.processInfo.environment["INSIGHTKIT_UI_TEST_MODE"] == "1"
    private var canSubmitNote: Bool {
        !newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
                if dataSource.isEditable {
                    noteComposer
                }

                if dataSource.notes.isEmpty {
                    Text("暂无笔记")
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
                        .onChange(of: dataSource.currentPlaybackTime) { _, _ in
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

                Spacer(minLength: InsightSpacing.sm)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var noteComposer: some View {
        VStack(alignment: .leading, spacing: InsightSpacing.sm) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $newNoteText)
                    .font(InsightTypography.noteBody)
                    .foregroundStyle(InsightTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($isNoteInputFocused)
                    .padding(.horizontal, InsightSpacing.xs)
                    .padding(.vertical, InsightSpacing.xs)
                    .frame(
                        minHeight: TimeBoundNotesEditorLayout.minimumComposerHeight,
                        maxHeight: TimeBoundNotesEditorLayout.maximumComposerHeight
                    )
                    .accessibilityIdentifier("live_note_input")
                    .onAppear {
                        isNoteInputFocused = autofocusInput
                    }

                if newNoteText.isEmpty {
                    Text("输入笔记...")
                        .font(InsightTypography.noteBody)
                        .foregroundStyle(InsightTheme.textTertiary)
                        .padding(.horizontal, InsightSpacing.sm + 2)
                        .padding(.vertical, InsightSpacing.sm)
                        .allowsHitTesting(false)
                }
            }
            .background(InsightTheme.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                    .stroke(
                        isNoteInputFocused ? InsightTheme.accent.opacity(0.65) : InsightTheme.border,
                        lineWidth: isNoteInputFocused ? 1.2 : 1
                    )
            )

            HStack {
                Spacer()
                Button {
                    submitNote()
                } label: {
                    Label("添加笔记", systemImage: "plus.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(InsightTheme.accent)
                .controlSize(.small)
                .disabled(!canSubmitNote)
                .accessibilityIdentifier("live_note_submit_button")
            }
        }
        .padding(.horizontal, InsightSpacing.lg)
        .padding(.top, InsightSpacing.sm)
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
        let text = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        submitAttempts += 1
        lastSubmittedText = text
        let time = dataSource.currentPlaybackTime ?? dataSource.recordingTime
        dataSource.onNoteCreated(text, at: time)
        newNoteText = ""
        isNoteInputFocused = !isUITestingMode
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d ⏱", mins, secs)
    }
}
