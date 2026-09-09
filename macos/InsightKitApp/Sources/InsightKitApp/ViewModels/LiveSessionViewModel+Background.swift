import Foundation

extension LiveSessionViewModel {
    func beginLiveBackgroundWork(meetingID: String) {
        invalidateLiveBackgroundWork()
        stateQueue.sync {
            liveBackgroundSession = LiveBackgroundSession(meetingID: meetingID, generation: UUID())
        }
    }

    /// Stop/final/reset retires the token immediately, even if socket I/O is busy.
    func invalidateLiveBackgroundWork() {
        stateQueue.sync { liveBackgroundSession = nil }
        liveSummaryQueue?.invalidate()
        liveSpeakerQueue?.invalidate()
    }

    func acceptsLiveBackgroundResult(_ session: LiveBackgroundSession) -> Bool {
        stateQueue.sync {
            liveBackgroundSession == session && _sessionState.activeMeetingID == session.meetingID && isRunning
        }
    }

    func enqueueLiveBackgroundWork(chunk: AudioChunk, outcome: LiveTranscriptPipelineOutcome, session: LiveBackgroundSession) {
        guard acceptsLiveBackgroundResult(session) else { return }
        // Empty ASR chunks still advance the continuous speaker audio timeline.
        let accepted = liveSpeakerQueue?.submit(LiveSpeakerRequest(session: session, chunkID: String(chunk.index))) ?? false
        if !accepted {
            updateMain {
                guard self.acceptsLiveBackgroundResult(session) else { return }
                self.metrics.droppedSpeakerChunks += 1
                self.recordingStatusMessage = LiveAnalysisHealthHint.speakerBacklog
            }
        }
        if case .requested = outcome.refresh, !stateQueue.sync(execute: { insightRefreshSuspended }) {
            liveSummaryQueue?.submit(session)
        }
    }

    func applyLiveInsightOutcome(_ outcome: LiveInsightRefreshOutcome, session: LiveBackgroundSession) {
        updateMain {
            // Check at the point of mutation, not before dispatching to main.
            guard self.acceptsLiveBackgroundResult(session) else { return }
            self.stateQueue.sync { self.insightRefreshSuspended = outcome.shouldSuspend }
            if outcome.shouldSuspend { self.liveSummaryQueue?.invalidate() }
            self.analysisRuntimeState = outcome.runtimeState
            if let message = outcome.errorMessage { self.errorMessage = message }
            if let message = outcome.statusMessage {
                self.recordingStatusMessage = message
            } else if LiveAnalysisHealthHint.isTransient(self.recordingStatusMessage) {
                self.recordingStatusMessage = nil
            }
            if let result = outcome.result {
                self.updateWorkbench(result, analyticsLatencyMilliseconds: outcome.latencyMs)
            }
            // This result owns summary state only. It cannot rewind first-text,
            // chunk/queue metrics, captureState, or append old transcript rows.
        }
    }

    func applyLiveSpeakerResult(_ result: Result<LiveSpeakerEnrichmentResult, Error>, request: LiveSpeakerRequest) {
        updateMain {
            guard self.acceptsLiveBackgroundResult(request.session) else { return }
            switch result {
            case .success(let enrichment):
                guard enrichment.meetingID == request.session.meetingID else { return }
                if enrichment.status == .stopped { return }
                self.transcriptSegments = LiveSpeakerPatch.apply(enrichment.updates, to: self.transcriptSegments)
                if enrichment.status == .unavailable {
                    self.recordingStatusMessage = LiveAnalysisHealthHint.speakerUnavailable
                }
            case .failure:
                self.recordingStatusMessage = LiveAnalysisHealthHint.speakerUnavailable
            }
        }
    }
}
