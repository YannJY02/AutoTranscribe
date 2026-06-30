# Persist presentation status in saved Records

Status: needs-info

## Parent

`.scratch/simultaneous-visual-presentation/PRD.md`

## What to build

Save lightweight presentation status with a Record created from simultaneous visual presentation, so later review can tell whether camera presence was captured by Presenter Overlay or the session fell back to screen-only recording.

The status should be enough for Record Review and QA to distinguish expected fallback from a bug. It should not introduce a broad new Record schema or require users to choose between separate visual sources.

User stories covered: 8, 9, 10, 12.

## Acceptance criteria

- [ ] A saved Record can represent `presenter overlay captured`.
- [ ] A saved Record can represent `screen-only fallback`.
- [ ] Missing or unknown presentation status does not break older Records.
- [ ] The presentation status is lightweight metadata, not a new multi-source media model.
- [ ] The saved Record still presents one reviewable media asset aligned to the Media Timeline.
- [ ] The status can be read by Record Review without making Record Review choose between separate visual source files.
- [ ] Automated tests cover saving and reading Presenter Overlay status, screen-only fallback status, and older Records without the status.

## Blocked by

- `.scratch/simultaneous-visual-presentation/issues/02-route-both-visual-toggles-to-presenter-overlay-guidance.md`
