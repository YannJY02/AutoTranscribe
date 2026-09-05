# Sealed GH-73 Harness history

`gh-73-harness.bundle` preserves the two real commits from
`5aba6bf71c67e8f69281f2827a5f772bab00a62a` (exclusive) through
`ac87aece21c073078589cb96873aed422d61df47` (inclusive), under the bundle ref
`refs/heads/gh-73-sealed-harness`. Its SHA-256 is pinned in
`tests/test_lifecycle_pilot.py`.

The sealed Pilot manifest and repository proof identify `ac87aece...` as the
historical Harness revision. PR #96 was squash-merged, so this revision is not
an ancestor of `main`. A fresh clone therefore cannot resolve it, even with
full `main` history. Local shared clones can hide this dependency by borrowing
objects retained from the old PR branch.

The incremental bundle contains the original commit/tree/blob objects and
requires the durable main ancestor above. Tests verify the bundle checksum,
advertised commit, and Git prerequisites before fetching it into temporary
fixture repositories. They still validate the original immutable commit,
Harness gate plan, changed files, and protected-file invalidation. No current
revision is substituted and no external network fetch is required by tests.

CI and fresh Symphony workspaces fetch complete main history. Resumed legacy
shallow workspaces must first use the credential-free worker history refresh in
`WORKFLOW.md`; fixture helpers do not fetch missing ancestry from the network.

The clean-history regression fetches only the prerequisite's ancestry into an
isolated object database, proves that the sealed commit is absent, then runs
the full historical proof validator after fixture restoration. It also checks
that restoration did not modify the source object database.

To reproduce the fixture from a repository retaining the original objects,
create a temporary clone, set the bundle ref there to the sealed commit, then
run in that temporary clone:

```sh
git bundle create gh-73-harness.bundle \
  refs/heads/gh-73-sealed-harness \
  ^5aba6bf71c67e8f69281f2827a5f772bab00a62a
```

Pack bytes can differ between Git versions; regeneration requires reviewing
the advertised ref, prerequisites, and contained history before updating the
checksum. The checked-in bundle is a fixed test asset, not a mechanism for
reattesting or rewriting the historical Pilot evidence.
