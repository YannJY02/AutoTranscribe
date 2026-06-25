import CoreGraphics

enum TimeBoundNotesEditorLayout {
    enum ComposerPlacement {
        case beforeNotesList
        case afterNotesList
    }

    static let minimumComposerHeight: CGFloat = 112
    static let maximumComposerHeight: CGFloat = 220
    static let editableComposerPlacement: ComposerPlacement = .beforeNotesList
    static let supportsMultilineDrafts = true

    static func composerHeight(forAvailableHeight availableHeight: CGFloat) -> CGFloat {
        min(max(availableHeight * 0.30, minimumComposerHeight), maximumComposerHeight)
    }
}
