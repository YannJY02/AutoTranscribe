import XCTest
@testable import InsightKitApp

final class TimestampNotesEditorLayoutTests: XCTestCase {
    func testEditableComposerReservesEnoughSpaceForActiveNoteTaking() {
        XCTAssertGreaterThanOrEqual(TimeBoundNotesEditorLayout.minimumComposerHeight, 96)
        XCTAssertGreaterThanOrEqual(
            TimeBoundNotesEditorLayout.composerHeight(forAvailableHeight: 420),
            96
        )
    }

    func testEditableComposerAppearsBeforeExistingNotesForDiscoverability() {
        XCTAssertEqual(TimeBoundNotesEditorLayout.editableComposerPlacement, .beforeNotesList)
    }

    func testEditableComposerSupportsMultilineDrafts() {
        XCTAssertTrue(TimeBoundNotesEditorLayout.supportsMultilineDrafts)
    }
}
