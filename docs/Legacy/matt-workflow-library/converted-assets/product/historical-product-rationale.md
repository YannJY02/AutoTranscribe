# Historical Product Rationale

Status: historical-reference

## Purpose

This file translates the old product rationale into current InsightKit language.

The original product material lives at:

- `docs/Legacy/matt-workflow-library/original-assets/docs/Legacy/overview.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/Legacy/image.png`
- `docs/Legacy/matt-workflow-library/original-assets/docs/Legacy/image-1.png`
- `docs/Legacy/matt-workflow-library/original-assets/docs/Legacy/image-2.png`
- `docs/Legacy/matt-workflow-library/original-assets/docs/Legacy/智能纪要：示例集重构-新手任务清单 2026年2月3日.pdf`

## Current Reading Rule

Use `docs/contexts/product/CONTEXT.md` for current product language. Use the original overview only as historical rationale for why InsightKit cares about meeting assets, Smart Minutes, timestamped transcripts, media-linked notes, and exports.

Use `docs/Legacy/matt-workflow-library/converted-assets/product/reference-output-patterns.md` for the privacy-safe structure patterns extracted from the historical images and example PDF.

## Historical Goal

The old product direction aimed to recreate the useful parts of Feishu/Lark Minutes for a personal local workflow:

- a readable AI summary;
- timestamped transcript and speaker turns;
- meeting quotes, decisions, action items, and chapters;
- media playback linked to transcript or notes;
- exportable minutes for sharing or review.

## Current Translation

| Historical idea | Current InsightKit term | Current authority |
| --- | --- | --- |
| Feishu/Lark Minutes-style meeting output | Meeting Asset | `docs/contexts/product/CONTEXT.md` |
| AI summary or meeting minutes | Smart Minutes | `docs/contexts/product/CONTEXT.md` |
| Raw transcript with timestamps | Transcript Segment | `docs/contexts/product/CONTEXT.md` and `docs/contexts/macos-app/CONTEXT.md` |
| Meeting playback jump | Media Seek | `docs/contexts/macos-app/CONTEXT.md` |
| Local saved meeting package | Record | `docs/contexts/product/CONTEXT.md` |
| Personal replacement for cloud meeting notes | Local-first InsightKit workflow | `docs/adr/0001-keep-native-macos-shell-with-python-sidecar.md` |

## What This Should Not Override

- It does not override current product naming.
- It does not prove release readiness.
- It does not define current architecture.
- It does not replace the current `.scratch/` PRDs and issues.

## Matt Workflow Use

When using this historical rationale in a future Matt workflow:

1. Treat it as context, not a current spec.
2. Translate old product wording into current context vocabulary.
3. Create a fresh PRD or issue if a historical idea becomes active work again.
4. Verify current behavior through tests, proof JSON, or app evidence instead of relying on historical prose.
