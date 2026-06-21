# Reference Output Patterns

Status: historical-reference

## Purpose

This file converts the historical product images and example PDF into privacy-safe output structure patterns for InsightKit.

It does not preserve meeting-specific people, tasks, business context, screenshots as product truth, or third-party UI layout. It only records reusable structure that can guide future Smart Minutes work.

## Source Inputs

- `docs/Legacy/matt-workflow-library/original-assets/docs/Legacy/image.png`
- `docs/Legacy/matt-workflow-library/original-assets/docs/Legacy/image-1.png`
- `docs/Legacy/matt-workflow-library/original-assets/docs/Legacy/image-2.png`
- `docs/Legacy/matt-workflow-library/original-assets/docs/Legacy/智能纪要：示例集重构-新手任务清单 2026年2月3日.pdf`

## Current Reading Rule

Use `docs/contexts/product/CONTEXT.md` for current product language. Use this file only as a structural reference for Smart Minutes output design.

Do not use the historical images or PDF as automated test fixtures unless the project owner explicitly approves a separate fixture-cleaning pass. A fixture is a sample file used repeatedly by automated tests; these historical examples contain external meeting content and should not be silently reused that way.

## Extracted Structure Patterns

### Smart Minutes Module Set

A complete Smart Minutes surface can be organized as a small set of named modules:

- Session Overview: a short top-level summary of the meeting.
- Highlight Insights: selected high-signal moments with explanation of why they matter.
- Speaker Perspectives: participant-centered viewpoints or themes.
- Decision Ledger: decisions, problems, options, rationale, and follow-up context.
- Action Track: tasks, owners, deadlines, and source context when known.
- Timeline Beats: timestamped chapters that help users navigate the source media.
- Related Links Section: links back to the record, transcript, media, or other provenance.

### Meeting Envelope

Exports should start with a stable envelope:

- document or record title;
- meeting time when available;
- participants or speaker fallback;
- media/source type;
- AI Review Notice;
- optional provenance links.

### Evidence-First Sections

Insight, decision, and action modules should be easy to check against source material. When the runtime has enough information, each generated item should prefer:

- an Evidence Span or timestamp;
- a speaker or participant reference when reliable;
- a short rationale instead of only a label;
- a clear distinction between what was said, inferred, or assigned as follow-up.

### Decision Shape

A decision entry is stronger when it separates:

- the decision;
- the problem being solved;
- options or discussion points;
- rationale;
- owner or next step when known.

### Action Shape

An action entry is stronger when it separates:

- task;
- owner;
- due date or timing if stated;
- source context;
- completion state if later tracked.

### Navigation Shape

Long meeting output should not be a single summary block. It should expose:

- module navigation;
- topic hierarchy;
- timestamped timeline;
- related links back to the record and transcript.

## What Not To Promote

- Historical personal names, meeting participants, and task details.
- Third-party product names as current InsightKit product language.
- Exact colors, spacing, card styling, or screenshots as current design authority.
- Any claim that InsightKit already implements every visual pattern shown in the historical examples.
- Any legal, privacy, or release claim.

## Matt Workflow Use

When future Matt workflow work touches Smart Minutes output:

1. Start from `docs/contexts/product/CONTEXT.md`.
2. Use this file to compare whether the planned output covers the expected modules.
3. Create a current `.scratch` PRD or issue if a missing module becomes active work.
4. Verify current behavior through tests, proof JSON, app evidence, or exported records.

