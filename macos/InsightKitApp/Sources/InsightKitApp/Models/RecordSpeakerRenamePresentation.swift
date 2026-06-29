import Foundation

struct RecordSpeakerRenamePresentation: Equatable {
    struct SpeakerAction: Equatable, Identifiable {
        let speakerLabel: String
        let accessibilityID: String

        var id: String { speakerLabel }
    }

    let showsSpeakerStrip: Bool
    let speakerStripAccessibilityID: String
    let speakerActions: [SpeakerAction]

    static func make(metadata: RecordMetadata, editableSpeakers: [String]) -> RecordSpeakerRenamePresentation {
        make(
            editableSpeakers: editableSpeakers,
            stripAccessibilityID: "record_speaker_rename_strip",
            buttonAccessibilityID: "record_speaker_rename_button"
        )
    }

    static func make(
        editableSpeakers: [String],
        stripAccessibilityID: String,
        buttonAccessibilityID: String
    ) -> RecordSpeakerRenamePresentation {
        let actions = editableSpeakers
            .map(normalizedSpeakerLabel)
            .filter { !$0.isEmpty }
            .uniquedSorted()
            .map { SpeakerAction(speakerLabel: $0, accessibilityID: buttonAccessibilityID) }

        return RecordSpeakerRenamePresentation(
            showsSpeakerStrip: !actions.isEmpty,
            speakerStripAccessibilityID: stripAccessibilityID,
            speakerActions: actions
        )
    }

    static func rowAction(for entry: TranscriptEntry) -> SpeakerAction? {
        let label = normalizedSpeakerLabel(entry.speaker)
        guard !label.isEmpty else { return nil }
        return SpeakerAction(
            speakerLabel: label,
            accessibilityID: "record_transcript_speaker_rename"
        )
    }

    private static func normalizedSpeakerLabel(_ speaker: String?) -> String {
        let trimmed = speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "未标注" : trimmed
    }
}

private extension Array where Element == String {
    func uniquedSorted() -> [String] {
        Array(Set(self)).sorted()
    }
}
