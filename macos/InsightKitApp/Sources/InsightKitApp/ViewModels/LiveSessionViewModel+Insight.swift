import Foundation

extension LiveSessionViewModel {
    func updateWorkbench(_ result: InsightRefreshResult) {
        let package = result.package
        updateMain {
            self.workbench = InsightWorkbenchState(
                sessionOverview: package.sessionOverview.overview,
                highlightInsights: package.highlightInsights.map {
                    WorkbenchItem(
                        title: $0.quote,
                        body: $0.reason,
                        meta: $0.speaker.isEmpty ? "" : "发言人：\($0.speaker)",
                        evidence: $0.evidenceSpan.range
                    )
                },
                speakerPerspectives: package.speakerPerspectives.map {
                    WorkbenchItem(
                        title: $0.speaker,
                        body: $0.viewpoints.joined(separator: "\n"),
                        meta: "观点数：\($0.viewpoints.count)",
                        evidence: $0.evidenceSpans.first?.range
                    )
                },
                decisionLedger: package.decisionLedger.map {
                    WorkbenchItem(
                        title: $0.problem,
                        body: "方案：\($0.options.joined(separator: " / "))\n决策：\($0.decision)\n依据：\($0.rationale)",
                        meta: "负责人：\($0.owner)\(($0.needsReview == true) ? " · 需复核" : "")",
                        evidence: $0.evidenceSpan.range
                    )
                },
                actionTracks: package.actionTracks.map {
                    WorkbenchItem(
                        title: $0.task,
                        body: "负责人：\($0.owner)\n截止：\($0.dueAt.isEmpty ? "未设置" : $0.dueAt)",
                        meta: "状态：\($0.status) · 优先级：\($0.priority)\(($0.needsReview == true) ? " · 需复核" : "")",
                        evidence: $0.evidenceSpan.range
                    )
                },
                timelineBeats: package.timelineBeats.map {
                    WorkbenchItem(
                        title: "\($0.timestamp) \($0.title)",
                        body: $0.summary,
                        meta: "",
                        evidence: nil
                    )
                }
            )

            self.actionItems = package.actionTracks.map {
                ActionItem(
                    task: $0.task,
                    owner: $0.owner,
                    status: $0.status,
                    dueAt: $0.dueAt,
                    priority: $0.priority,
                    needsReview: $0.needsReview ?? false,
                    evidence: $0.evidenceSpan.range
                )
            }

            self.metrics.provider = result.provider
            self.metrics.needsReviewCount = result.needsReviewCount
            self.metrics.lastRefreshAt = result.updatedAt ?? Date()
        }
    }

    func syncActionTracksToWorkbench() {
        workbench.actionTracks = actionItems.map { item in
            WorkbenchItem(
                title: item.task,
                body: "负责人：\(item.owner)\n截止：\(item.dueAt.isEmpty ? "未设置" : item.dueAt)",
                meta: "状态：\(item.status) · 优先级：\(item.priority)\(item.needsReview ? " · 需复核" : "")",
                evidence: item.evidence
            )
        }
    }

    func probeProvidersInBackground() {
        rpcQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning else { return }
            do {
                try self.ensureRuntimeReady(requireASR: false, requireProvider: true, allowProviderProbeFailure: true)
            } catch {
                self.updateMain {
                    if self.errorMessage == nil || self.errorMessage?.isEmpty == true {
                        self.errorMessage = "智能分析暂不可用，转写继续。请在设置中完成服务配置后重试。"
                    }
                }
            }
        }
    }
}
