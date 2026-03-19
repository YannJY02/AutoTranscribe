import SwiftUI

struct TimestampNotesEditor<DataSource: NotesEditorDataSource>: View {
    @ObservedObject var dataSource: DataSource
    @State private var newNoteText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: InsightSpacing.sm) {
            Text("笔记")
                .font(InsightTypography.heading)
                .foregroundStyle(InsightTheme.textPrimary)
                .padding(.horizontal, InsightSpacing.lg)
                .padding(.top, InsightSpacing.lg)

            if dataSource.notes.isEmpty && !dataSource.isEditable {
                Spacer()
                Text("录制开始后可记录笔记")
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                if dataSource.notes.isEmpty {
                    Text("录制中，可在下方输入笔记")
                        .font(InsightTypography.caption)
                        .foregroundStyle(InsightTheme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, InsightSpacing.lg)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: InsightSpacing.sm) {
                                ForEach(dataSource.notes) { note in
                                    noteRow(note)
                                        .id(note.id)
                                }
                            }
                            .padding(.horizontal, InsightSpacing.lg)
                        }
                        .onChange(of: dataSource.currentPlaybackTime) { _ in
                            if let time = dataSource.currentPlaybackTime,
                               let closest = dataSource.notes.min(by: {
                                   abs($0.timestamp - time) < abs($1.timestamp - time)
                               }) {
                                withAnimation(InsightAnimation.noteHighlight) {
                                    proxy.scrollTo(closest.id, anchor: .center)
                                }
                            }
                        }
                    }
                }

                Spacer()

                if dataSource.isEditable {
                    Divider()
                        .padding(.horizontal, InsightSpacing.lg)
                    HStack(spacing: InsightSpacing.sm) {
                        TextField("输入笔记...", text: $newNoteText)
                            .textFieldStyle(.plain)
                            .font(InsightTypography.noteBody)
                            .onSubmit { submitNote() }
                        Button(action: submitNote) {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(InsightTheme.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(newNoteText.isEmpty)
                    }
                    .padding(.horizontal, InsightSpacing.lg)
                    .padding(.bottom, InsightSpacing.lg)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func noteRow(_ note: TimestampedNote) -> some View {
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
    }

    private func isNoteHighlighted(_ note: TimestampedNote) -> Bool {
        guard let time = dataSource.currentPlaybackTime else { return false }
        return abs(note.timestamp - time) < 3.0
    }

    private func submitNote() {
        guard !newNoteText.isEmpty else { return }
        let time = dataSource.currentPlaybackTime ?? dataSource.recordingTime
        dataSource.onNoteCreated(newNoteText, at: time)
        newNoteText = ""
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d ⏱", mins, secs)
    }
}
