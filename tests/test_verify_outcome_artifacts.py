from pathlib import Path

import pytest

from scripts.verify_outcome_artifacts import ARTIFACTS, validate


def test_outcome_artifacts_are_classified_linked_and_privacy_safe():
    assert validate() == []
    assert all(path.is_file() for path in ARTIFACTS)


def write_artifact(tmp_path: Path, body: str) -> Path:
    artifact = tmp_path / "artifact.md"
    artifact.write_text(f"# Test\n\n{body}\n", encoding="utf-8")
    return artifact


@pytest.mark.parametrize(
    ("body", "message"),
    [
        ("Unclassified result.", "prose outside classified claim grammar"),
        ("- [Observed] Result without evidence.", "missing Sources block"),
        ("- [Claim] Result. ([Sources: issue](https://github.com/org/repo/issues/1))", "invalid claim label"),
        ("- [Observed] Result. ([Sources: missing](missing.json))", "missing repository link"),
        ("- [Observed] Result from /private/tmp/run. ([Sources: issue](https://github.com/org/repo/issues/1))", "private path or secret-like text"),
        ("- [Observed] Result from /Applications/App.app. ([Sources: issue](https://github.com/org/repo/issues/1))", "private path or secret-like text"),
        ("- [Observed] Result from /secret.txt. ([Sources: issue](https://github.com/org/repo/issues/1))", "private path or secret-like text"),
        (r"- [Observed] Result from C:\Temp\run.log. ([Sources: issue](https://github.com/org/repo/issues/1))", "private path or secret-like text"),
        (r"- [Observed] Result from \\server\share\run.log. ([Sources: issue](https://github.com/org/repo/issues/1))", "private path or secret-like text"),
        ("- [Observed] Result. ([Sources: credential](https://user:secret@github.com/org/repo))", "disallowed external link"),
        ("- [Observed] Result. ([Sources: credential](https://github.com/org/repo?access_token=secretvalue))", "disallowed external link"),
        ("- [Observed] [api_key=sk-supersecret](https://github.com/org/repo) result. ([Sources: issue](https://github.com/org/repo/issues/1))", "private path or secret-like text"),
        ("- [Observed] ghp_abcdefghijklmnopqrstuvwxyz1234567890. ([Sources: issue](https://github.com/org/repo/issues/1))", "private path or secret-like text"),
        ("- [Observed] [sk-abcdefghijklmnopqrstuvwxyz1234567890](https://github.com/org/repo) result. ([Sources: issue](https://github.com/org/repo/issues/1))", "private path or secret-like text"),
    ],
)
def test_validator_rejects_unclassified_unlinked_or_private_claims(tmp_path, body, message):
    errors = validate((write_artifact(tmp_path, body),))
    assert any(message in error for error in errors)
