# Smart Minutes cannot be exported from the review flow

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

After Smart Minutes are generated, the owner cannot find a clear way to export the Smart Minutes from the Live Workspace summary review flow.

The generated Smart Minutes are visible in the app, but they do not have an obvious export action from the place where the user reviews them.

## What I expected

When Smart Minutes are available, InsightKit should provide a clear export action for them.

The export should produce a usable Export Document, such as Markdown or PDF, that includes the Smart Minutes sections and enough transcript or provenance context for review.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Capture a session and generate Smart Minutes.
4. Enter the generated Smart Minutes review experience.
5. Look for an action to export the Smart Minutes.
6. Observe that the export path is missing or not discoverable from the Smart Minutes review flow.

## Additional context

Reported after owner retest of installed build `20260625165436`.

Record-level export may exist elsewhere, but this issue is about the user not being able to export Smart Minutes from the review context where they are looking at the generated minutes.

## Comments

### 2026-06-25 - Manual QA

The owner reported that Smart Minutes cannot be exported from the current review experience.

### 2026-06-25 - Batch triage

Classification: `ready-for-agent`.

Why:

- The app already has Record-level Markdown/PDF export behavior, but the Live Workspace Smart Minutes review flow does not expose an obvious export action.
- The expected behavior is clear and can be verified with existing Export Document concepts.

Dependency:

- Independent from issue 20's audible playback problem.
- Related to Record export, but not blocked by Record rename or default naming work.

Implementation boundary:

- Add clear Markdown/PDF export actions where generated Smart Minutes are reviewed.
- Export should include Smart Minutes modules and enough transcript/provenance context for review.
- Do not change Provider generation behavior in this issue.

Suggested verification:

- Add a ViewModel or presentation test proving the Smart Minutes review state exposes export actions when export is available.
- Add or reuse RecordDocumentExporter tests to confirm Smart Minutes content appears in the exported document.
- Owner retest should confirm Smart Minutes can be exported from the review flow without navigating to a different workspace.

### 2026-06-25 - Code fix installed for owner retest

Status changed to `ready-for-human`.

Implementation summary:

- Added Markdown and PDF export actions directly to the Live Workspace Smart Minutes review header.
- Routed the review header through the existing Center Stage panel data source instead of adding a separate export path.
- Reused the existing native Record Document export path, so exported Markdown/PDF includes Smart Minutes modules, transcript context, notes, and record provenance.
- Added a visible success status showing the exported file name after export completes.

TDD proof:

- RED: `swift test --package-path macos/InsightKitApp --filter LiveReviewPresentationPlanTests/testSummaryReviewWithExportableMinutesShowsExportActions` failed because the review presentation plan had no export action model.
- GREEN: the same test passed after adding Markdown/PDF export actions to `LiveReviewPresentationPlan`.
- RED: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testCenterStageDataSourceExportsSmartMinutesReviewMarkdown` failed because `CenterStageDataSource` did not expose export capability, export path, or export action.
- GREEN: the same test passed after adding the export interface and wiring it to `LiveSessionViewModel.exportDocument(format:)`.
- GREEN: `swift test --package-path macos/InsightKitApp --filter LiveReviewPresentationPlanTests` passed, 3 tests, 0 failures.
- GREEN: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests` passed, 35 tests, 0 failures.
- GREEN: `swift test --package-path macos/InsightKitApp --filter RecordDocumentExporterTests` passed, 4 tests, 0 failures.
- GREEN: `swift test --package-path macos/InsightKitApp` passed, 153 tests, 0 failures.

Installed-app proof:

- Installed build: `20260625185114`
- Sync proof: `logs/workflow/latest_sync.json`
- Command: `scripts/sync_insightkit_app.sh --debug --skip-tests`
- Installed smoke: launched `/Users/yann.jy/Applications/InsightKit.app` in UI-test Live route and quit successfully.

Owner retest:

- Generate Smart Minutes from a Live Workspace session.
- Confirm the Smart Minutes review header shows `导出 Markdown` and `导出 PDF`.
- Click `导出 Markdown` and confirm a Markdown file is produced and the review header shows the exported file name.
- Optionally click `导出 PDF` and confirm a PDF file is produced.

### 2026-06-25 - Owner retest passed

The owner confirmed that Smart Minutes can now be exported from the review flow in the installed app.
