import Foundation

extension LiveSessionViewModel {
    var editableSpeakers: [String] {
        let transcriptLabels = transcriptSegments.map(\.speaker)
        let minuteLabels = smartMinutesData?.speakerSummaries.map(\.speakerName) ?? []
        let packageLabels = lastInsightPackage?.speakerPerspectives.map(\.speaker) ?? []
        return Self.uniqueNormalizedSpeakerLabels(transcriptLabels + minuteLabels + packageLabels)
    }

    func renameSpeaker(from oldLabel: String, to newLabel: String) {
        let sourceLabel = Self.normalizedSpeakerLabel(oldLabel)
        let replacement = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceLabel.isEmpty, !replacement.isEmpty else { return }

        transcriptSegments = transcriptSegments.renamingSpeaker(from: sourceLabel, to: replacement)

        if let cache = finalizedMediaTranscriptCache {
            finalizedMediaTranscriptCache = (
                mediaPath: cache.mediaPath,
                segments: cache.segments.renamingSpeaker(from: sourceLabel, to: replacement)
            )
        }

        if let minutes = smartMinutesData {
            smartMinutesData = minutes.renamingSpeaker(from: sourceLabel, to: replacement)
        }

        if let package = lastInsightPackage {
            lastInsightPackage = package.renamingSpeaker(from: sourceLabel, to: replacement)
        }

        workbench = workbench.renamingSpeaker(from: sourceLabel, to: replacement)
        persistSpeakerRenameToCurrentRecord(from: sourceLabel, to: replacement)

        if let meetingID = currentBuildTargetID() {
            try? replaceRuntimeTranscript(meetingID: meetingID, segments: transcriptSegments)
        }
    }

    private func persistSpeakerRenameToCurrentRecord(from sourceLabel: String, to replacement: String) {
        guard let recordPath = currentPersistedRecordPath() else { return }
        let transcriptURL = recordPath.appendingPathComponent("transcript.json")
        guard Self.renameSpeakerInTranscriptFile(transcriptURL, from: sourceLabel, to: replacement) else { return }
        recordsService?.refreshIndex()
    }

    private func currentPersistedRecordPath() -> URL? {
        if let meetingID = currentBuildTargetID(), let root = recordsService?.rootDirectory {
            let recordPath = root.appendingPathComponent(meetingID, isDirectory: true)
            if FileManager.default.fileExists(atPath: recordPath.appendingPathComponent("transcript.json").path) {
                return recordPath
            }
        }

        let lastPath = lastExportPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lastPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: lastPath)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
        let parent = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.appendingPathComponent("transcript.json").path) {
            return parent
        }
        return nil
    }

    private static func renameSpeakerInTranscriptFile(_ url: URL, from sourceLabel: String, to replacement: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
              var rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return false }

        var changed = false
        for index in rows.indices {
            let existing = normalizedSpeakerLabel(rows[index]["speaker"] as? String)
            guard existing == sourceLabel else { continue }
            rows[index]["speaker"] = replacement
            changed = true
        }
        guard changed,
              let output = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        else { return false }

        try? output.write(to: url)
        return true
    }

    private static func uniqueNormalizedSpeakerLabels(_ labels: [String]) -> [String] {
        Array(Set(labels.map(normalizedSpeakerLabel).filter { !$0.isEmpty })).sorted()
    }

    private static func normalizedSpeakerLabel(_ speaker: String?) -> String {
        let trimmed = speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "未标注" : trimmed
    }
}

private extension Array where Element == TranscriptSegment {
    func renamingSpeaker(from sourceLabel: String, to replacement: String) -> [TranscriptSegment] {
        map { segment in
            let current = segment.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = current.isEmpty ? "未标注" : current
            guard normalized == sourceLabel else { return segment }
            return TranscriptSegment(
                startMs: segment.startMs,
                endMs: segment.endMs,
                speaker: replacement,
                source: segment.source,
                text: segment.text
            )
        }
    }
}

private extension SmartMinutes {
    func renamingSpeaker(from sourceLabel: String, to replacement: String) -> SmartMinutes {
        SmartMinutes(
            id: id,
            generatedAt: generatedAt,
            structuredSummary: structuredSummary,
            highlights: highlights,
            speakerSummaries: speakerSummaries.map {
                let normalized = $0.speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (normalized.isEmpty ? "未标注" : normalized) == sourceLabel else { return $0 }
                return SpeakerMinutesSummary(id: $0.id, speakerName: replacement, summary: $0.summary)
            },
            keyDecisions: keyDecisions,
            actionItems: actionItems,
            chapters: chapters
        )
    }
}

private extension InsightPackageV1 {
    func renamingSpeaker(from sourceLabel: String, to replacement: String) -> InsightPackageV1 {
        InsightPackageV1(
            sessionOverview: sessionOverview,
            highlightInsights: highlightInsights.map {
                .init(
                    quote: $0.quote,
                    reason: $0.reason,
                    speaker: normalizedSpeaker($0.speaker) == sourceLabel ? replacement : $0.speaker,
                    evidenceSpan: $0.evidenceSpan
                )
            },
            speakerPerspectives: speakerPerspectives.map {
                .init(
                    speaker: normalizedSpeaker($0.speaker) == sourceLabel ? replacement : $0.speaker,
                    viewpoints: $0.viewpoints,
                    evidenceSpans: $0.evidenceSpans
                )
            },
            decisionLedger: decisionLedger,
            actionTracks: actionTracks,
            timelineBeats: timelineBeats,
            provenanceLinks: provenanceLinks
        )
    }

    private func normalizedSpeaker(_ speaker: String) -> String {
        let trimmed = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未标注" : trimmed
    }
}

private extension InsightWorkbenchState {
    func renamingSpeaker(from sourceLabel: String, to replacement: String) -> InsightWorkbenchState {
        InsightWorkbenchState(
            sessionOverview: sessionOverview,
            highlightInsights: highlightInsights.map {
                WorkbenchItem(
                    title: $0.title,
                    body: $0.body,
                    meta: $0.meta == "发言人：\(sourceLabel)" ? "发言人：\(replacement)" : $0.meta,
                    evidence: $0.evidence
                )
            },
            speakerPerspectives: speakerPerspectives.map {
                WorkbenchItem(
                    title: normalizedSpeaker($0.title) == sourceLabel ? replacement : $0.title,
                    body: $0.body,
                    meta: $0.meta,
                    evidence: $0.evidence
                )
            },
            decisionLedger: decisionLedger,
            actionTracks: actionTracks,
            timelineBeats: timelineBeats
        )
    }

    private func normalizedSpeaker(_ speaker: String) -> String {
        let trimmed = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未标注" : trimmed
    }
}
