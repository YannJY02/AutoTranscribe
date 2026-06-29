# Create Action-Specific Swift RPC Seams

Status: ready-for-human

## Parent

`.scratch/swift-rpc-action-client/PRD.md`

## What to build

Create the first slice of action-specific Swift RPC seams for the runtime actions needed by Live Session Finalization, Transcript Recovery, Canonical Meeting Asset Source, and Smart Minutes generation.

This issue should introduce small action entrypoints while keeping the existing broad RPC client available for legacy code. It should not migrate the entire app.

## Product Behavior

- New or refactored modules ask for product actions such as saving a Record, recovering a transcript, transcribing final media, replacing runtime transcript, or generating Smart Minutes.
- UI and business modules receive product-level outcomes and capability state, not raw JSON-RPC method details.
- Runtime capability gaps should produce clear unavailable/degraded states.
- Low-level RPC errors should be logged or diagnosed, then translated into user-facing outcomes.
- Existing unrelated RPC behavior should keep working.

## Acceptance Criteria

- [x] A `Record Save Action` seam exists for saving official Records through the runtime Record Save Action.
- [x] A `Transcript Recovery Action` seam exists for regenerating official transcript content from saved media.
- [x] A `Final Media Transcription Action` seam exists for creating media-timed transcript segments from final review media.
- [x] A `Runtime Transcript Replacement Action` seam exists for replacing runtime transcript state with official media-timed segments.
- [x] A `Smart Minutes Generation Action` seam exists for generating or regenerating official Insight Package data.
- [x] Each action seam is named around the product action, not the low-level JSON-RPC method.
- [x] Each action seam owns input validation and capability checks for its action.
- [x] Each action seam maps low-level RPC success/failure into product-level outcomes.
- [x] Product outcomes distinguish success, unavailable capability, retryable failure, incomplete input, and technical failure where relevant.
- [x] The first action seams may share one low-level RPC client adapter internally.
- [x] New or refactored business modules receive action seams as dependencies instead of directly depending on the broad RPC client.
- [x] Existing broad RPC client usage remains available for legacy paths.
- [x] The slice does not attempt a full migration of every RPC call.
- [x] Focused Swift tests cover action outcome mapping, capability checks, input validation, and fake-action usage by at least one business module.
- [x] A short installed-app retest checklist is appended before moving this issue to `ready-for-human` if user-visible behavior changes.

## Suggested Files

- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/RPCClientProtocol.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/InsightRPCClient.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel+Records.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/RecordReviewDataSource.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/Services/FinalMediaTranscriber.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/Services/RecordDocumentExporter.swift`
- `macos/InsightKitApp/Tests/InsightKitAppTests/LiveSessionViewModelTests.swift`
- `macos/InsightKitApp/Tests/InsightKitAppTests/RecordReviewDataSourceTests.swift`
- `macos/InsightKitApp/Tests/InsightKitAppTests/RPCClientTests.swift`

## Constraints

- Preserve ADR-0001: native SwiftUI app plus Python Sidecar.
- Preserve ADR-0002: Unix socket JSON-RPC.
- Preserve ADR-0004: local Record Folders written through the Python Record Writer.
- Preserve ADR-0005: saved transcript timestamps use the final Media Timeline.
- Do not replace the entire broad RPC client in this slice.
- Do not migrate unrelated RPC calls.
- Do not duplicate socket transport or JSON-RPC encoding logic across action seams.
- Do not claim public Distribution Ready.

## Verification Plan

- Run focused Swift tests for new action seams.
- Run Live Session Finalization and Transcript Recovery tests if these seams are wired there in the same implementation pass.
- Run Record Review tests if action seams are wired there.
- Run existing RPC client tests.
- Run `git diff --check`.
- Run `python3 scripts/verify_project_normalization.py`.
- Sync to `/Users/yann.jy/Applications/InsightKit.app` before owner retest if user-visible behavior changes.

## Owner Retest Checklist To Fill After Implementation

No owner retest required for this slice because it adds internal Swift action seams and keeps existing user-visible flows on their current behavior. Installed-app retest should be required when later issues wire these seams into new Transcript Recovery, Record Save, or Smart Minutes UI flows.

## Blocked by

None - owner accepted the product decisions on 2026-06-29.

## Comments

### 2026-06-29 - Codex

Created from the accepted Swift RPC Action Client architecture discussion.

### 2026-06-29 - Codex

Implemented the first Swift action seam slice.

- Added `RuntimeActionClients.swift` with `RecordSaveAction`, `TranscriptRecoveryAction`, `FinalMediaTranscriptionAction`, `RuntimeTranscriptReplacementAction`, `SmartMinutesGenerationAction`, shared `InsightRuntimeActionRPCAdapter`, product-level availability states, and product-level outcomes.
- Kept the broad `InsightRPCClientProtocol` available for legacy paths.
- Routed `FinalMediaTranscriptionRouter` through the new final-media action seam while preserving its existing public initializer and Apple Speech prototype behavior.
- Updated `RPCClientMock` so its default capabilities represent a normal available runtime; tests can still override capabilities for unavailable/unsupported cases.
- Added `RuntimeActionClientsTests` covering capability alias mapping, registry preference, input validation, segment mapping, unavailable capability behavior, retryable timeout mapping, and fake-action injection.

Verification:

- `swift test --filter RuntimeActionClientsTests` - passed, 7 tests.
- `swift test --filter FinalMedia` - passed, 8 tests.
- `swift test --filter WorkflowCoordinatorTests` - passed, 8 tests.
- `swift test --filter InsightRPCClientFinalInsightTimeoutTests` - passed, 1 test.
- `swift test` - passed, 223 tests.
