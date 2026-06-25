# Speaker diarization can fail or label speakers incorrectly

Status: needs-info

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

During some runs, InsightKit does not correctly separate or label speakers. Transcript rows and Smart Minutes can end up with missing, generic, or incorrect speaker labels.

The owner described this as the app sometimes being unable to correctly recognize or identify speakers.

## What I expected

When speaker diarization is available, InsightKit should label speaker turns consistently enough for Transcript Segments, Speaker Perspectives, and exports to be useful.

When speaker diarization is not reliable for a session, the app should make that degraded state clear instead of silently presenting misleading speaker labels.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Capture a session with more than one speaker, or use a recording where speaker changes should be visible.
4. Review the Transcript Segments and Smart Minutes.
5. Observe whether speaker labels are missing, generic, inconsistent, or assigned to the wrong person.

## Additional context

Reported after owner retest of installed build `20260625165436`.

Use the project term `speaker diarization` for this issue. This issue is about automatic speaker separation and labeling quality. Manual correction is tracked separately in issue 16.

## Comments

### 2026-06-25 - Manual QA

The owner reported intermittent cases where InsightKit cannot correctly identify or separate speakers during transcription and review.

### 2026-06-25 - Batch triage

Classification: `needs-info`.

Why:

- The issue is clear as a user-visible problem, but improving automatic speaker diarization quality requires a concrete failing sample.
- A useful sample should include the relevant Record or audio clip, the current transcript speaker labels, and the expected speaker labels.
- Without that evidence, an agent can only add degradation warnings, but cannot safely verify that diarization quality improved.

Dependency:

- Issue 16 is still independently actionable because manual speaker correction is useful even when automatic diarization improves.

Needed evidence:

- One reproducible Record, audio clip, or transcript excerpt where speaker labels are wrong.
- A short expected mapping, such as `SPEAKER_00 = me`, `SPEAKER_01 = guest`, or the specific rows that should change speaker.

Suggested follow-up:

- If the desired first fix is only to show clearer diarization degraded/disabled status, file or promote a separate bounded issue for diarization status presentation.
