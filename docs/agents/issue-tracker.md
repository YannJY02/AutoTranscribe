# Issue tracker: Local Markdown

Issues and PRDs for this repo live as markdown files in `.scratch/`.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The PRD is `.scratch/<feature-slug>/PRD.md`
- Implementation issues are `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`
- Triage state is recorded as a `Status:` line near the top of each issue file (see `triage-labels.md` for the role strings)
- Comments and conversation history append to the bottom of the file under a `## Comments` heading

## When a skill says "publish to the issue tracker"

Create a new file under `.scratch/<feature-slug>/` (creating the directory if needed).

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path or the issue number directly.

## Legacy workflow assets

Historical issue-style files under `docs/Legacy/matt-workflow-library/converted-assets/` are not the active issue tracker. They are reference material.

If a historical item is still useful after checking current code, context docs, ADRs, and proof, promote it by creating a current `.scratch/<feature>/PRD.md` and `.scratch/<feature>/issues/<NN>-<slug>.md`. If the code already implements or supersedes it, leave it as Legacy reference and point to the current authority instead.
