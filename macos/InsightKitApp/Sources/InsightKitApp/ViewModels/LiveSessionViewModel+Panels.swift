import Foundation

// MARK: - ChapterSidebarDataSource

extension LiveSessionViewModel: ChapterSidebarDataSource {
    var smartMinutes: SmartMinutes? { smartMinutesData }

    var canGenerateMinutes: Bool {
        sessionPhase == .postSession || sessionPhase == .reviewing
    }

    func onChapterTapped(_ chapter: ChapterSummary) {
        // Seek to chapter timestamp in reviewing mode
        if sessionPhase == .reviewing {
            onSeek(to: chapter.timestamp)
        }
    }

    func onGenerateMinutes() {
        buildFinalInsight()
    }
}

// MARK: - CenterStageDataSource

extension LiveSessionViewModel: CenterStageDataSource {
    var phase: SessionPhase { sessionPhase }

    var capturePreview: (any CapturePreviewProvider)? { videoCaptureService }

    var transcriptEntries: [TranscriptEntry] {
        transcriptSegments.map { seg in
            TranscriptEntry(
                timestamp: TimeInterval(seg.startMs) / 1000.0,
                speaker: seg.speaker,
                text: seg.text
            )
        }
    }

    func onStartRecording() {
        startLiveSession()
    }

    func onStopRecording() {
        stopLiveSession()
    }

    func onPauseRecording() {
        // Pause not yet supported — stop instead
        stopLiveSession()
    }

    func onTranscriptEntryTapped(_ entry: TranscriptEntry) {
        if sessionPhase == .reviewing {
            onSeek(to: entry.timestamp)
        }
    }

    func onSeek(to time: TimeInterval) {
        currentPlaybackTime = time
    }

    func onSkipMinutes() {
        sessionPhase = .reviewing
    }
}

// MARK: - NotesEditorDataSource

extension LiveSessionViewModel: NotesEditorDataSource {
    var isEditable: Bool {
        sessionPhase == .running || sessionPhase == .postSession || sessionPhase == .reviewing
    }

    var recordingTime: TimeInterval {
        recordingDuration
    }

    func onNoteCreated(_ text: String, at time: TimeInterval) {
        let note = TimestampedNote(
            text: text,
            timestamp: time
        )
        notes.append(note)
    }

    func onNoteUpdated(_ note: TimestampedNote) {
        guard let idx = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[idx] = note
    }

    func onNoteTapped(_ note: TimestampedNote) {
        if sessionPhase == .reviewing {
            onSeek(to: note.timestamp)
        }
    }
}
