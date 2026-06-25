from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
NOTES_EDITOR = ROOT / "macos/InsightKitApp/Sources/InsightKitApp/Views/Components/TimestampNotesEditor.swift"


def test_live_notes_editor_does_not_use_single_line_text_field():
    source = NOTES_EDITOR.read_text(encoding="utf-8")

    assert "usesSingleLineMode = true" not in source
    assert "FocusAwareTextField" not in source


def test_live_notes_editor_keeps_input_accessibility_identifier():
    source = NOTES_EDITOR.read_text(encoding="utf-8")

    assert '"live_note_input"' in source
