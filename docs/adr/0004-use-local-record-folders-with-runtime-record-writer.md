# Use local record folders with runtime RecordWriter

Status: accepted

## Context

Historical Phase 5 plans identified a mismatch between the app's record-review UI and the runtime's storage path. The app needed local folders containing `metadata.json`, `transcript.json`, `minutes.json`, `insight_package.json`, `notes.md`, and `recording.*`, while the runtime originally leaned on SQLite and did not always produce a self-contained record folder for live and import workflows.

## Decision

InsightKit represents a saved meeting asset as a local Record Folder and writes it through the Python runtime's `RecordWriter`. Live and import workflows call the `records.save` RPC action instead of having Swift write duplicate JSON structures directly.

The local record folder is the app-reopenable package for a record. SQLite/FTS remains useful for runtime search and proof workflows, but the folder is the durable user-facing recovery and export surface.

## Consequences

- Live and import paths share one record-writing contract for media, metadata, transcript, minutes, insight package, and notes.
- Swift can index and reopen records through `RecordsIndexService` without owning the canonical write format.
- Export and recovery checks should verify the record folder shape as well as any SQLite/FTS evidence.
- App Store sandbox work must preserve this record-root model with user-selected access, app-scoped security-scoped bookmarks, or an app-container default record root.
