# Record default names are hard to read

Status: ready-for-agent

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

Saved transcription records can appear with technical or low-information names that are hard to read and hard to distinguish in the Records Workspace.

The owner reported that transcription record names are not readable enough for everyday use.

## What I expected

Record names should help the user identify the meeting asset without opening each Record.

A default Record name should be readable and should preferably reflect the meeting time, source, first topic, or Smart Minutes summary when available.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Create one or more Live Session Records or imported transcription Records.
3. Open the Records Workspace.
4. Review the names shown in the Record Index.
5. Observe that the names can be difficult to understand or distinguish.

## Additional context

Reported after owner retest of installed build `20260625165436`.

This issue covers default naming quality. Manual renaming is tracked separately in issue 19.

## Comments

### 2026-06-25 - Manual QA

The owner reported that transcription record names have poor readability.

### 2026-06-25 - Batch triage

Classification: `ready-for-agent`.

Why:

- Current Record list surfaces can display technical identifiers, while metadata already includes fields such as creation time, source, duration, tags, and summary preview.
- A bounded implementation can improve the display name without requiring manual rename support first.

Dependency:

- Related to issue 19, but not blocked by it.
- If issue 19 later adds a user-defined title, that title should override the generated default display name.

Implementation boundary:

- Improve default Record display names in the Record Index and Record Review.
- Prefer human-readable context such as Smart Minutes summary preview, source, and date/time.
- Preserve stable Record IDs for storage and internal lookup; do not rename folders as part of this issue.

Suggested verification:

- Add a pure display-name test for Records with and without `summaryPreview`.
- Owner retest should confirm Records are distinguishable in the Records Workspace without opening every Record.
