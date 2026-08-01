# Installed-App Benchmark Fixture Corpus

Status: frozen v1

The canonical local corpus is rooted at:

```text
/Users/yann.jy/Library/Application Support/InsightKit/BenchmarkFixtures/v1
```

The committed [manifest](./fixture-corpus-manifest.json) pins every media file,
reference transcript, replay trace, Record Folder inventory, generator input,
and tool environment. The media and generated Record Folders stay outside Git.

## Use the frozen corpus

Verify it before any baseline run:

```bash
PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 \
  scripts/performance_fixture_corpus.py verify \
  --manifest docs/performance/fixture-corpus-manifest.json
```

Expected result:

```json
{"fixture_assets_verified": 6, "record_folders_verified": 1100, "status": "passed"}
```

Do not run a benchmark after a verification failure. Preserve the failed state
as evidence and repair or create a new cohort first.

## Reproduce or reacquire

The exact frozen files already exist at the canonical local root. A fresh task
on this Mac should reacquire them from that root and verify the committed pins,
not regenerate them by default.

To create a replacement candidate from source, use a clean checkout containing
generator revision `6dff2524c06433de01e78821e641596481145a46`, macOS build
`26A5388g`, FFmpeg 8.0.1, Python 3.11, and the four voices recorded in the
manifest:

```bash
PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 \
  scripts/performance_fixture_corpus.py materialize \
  --output-root "/Users/yann.jy/Library/Application Support/InsightKit/BenchmarkFixtures/v1-candidate" \
  --manifest-out /tmp/insightkit-fixture-candidate-manifest.json \
  --generator-revision 6dff2524c06433de01e78821e641596481145a46
```

Apple voice or encoder output can change across system revisions. A candidate
whose hashes differ from the frozen manifest is a new corpus cohort; do not
overwrite the v1 pins. `--force` only replaces the explicitly selected generated
output root and should not be used on the frozen root during baseline work.

## Corpus boundaries

- All speech and meeting content is synthetic.
- No private Record Folder is read or copied.
- M4A is canonical for all four fixtures. The two MP4 companions contain the
  copied AAC packet stream from their matching M4A.
- The 100 and 1,000 Record Folder collections use seed `20260801`. Their media
  entries are hard links to the mixed MP4 companions, so the on-disk corpus is
  about 65 MB while every folder remains complete and independently parseable.
- This corpus does not contain baseline measurements or optimizations.
