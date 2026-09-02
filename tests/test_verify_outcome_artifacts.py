from pathlib import Path

import pytest

from scripts.verify_outcome_artifacts import ARTIFACTS, validate

FAKE_GITHUB_TOKEN = "gh" + "p_" + "abcdefghijklmnopqrstuvwxyz1234567890"
FAKE_OPENAI_KEY = "s" + "k-" + "abcdefghijklmnopqrstuvwxyz1234567890"
FAKE_PASSWORD_PATH = "pass" + "word=supersecretvalue"


def test_outcome_artifacts_are_classified_linked_and_privacy_safe():
    assert validate() == []
    assert all(path.is_file() for path in ARTIFACTS)


def write_artifact(tmp_path: Path, body: str) -> Path:
    artifact = tmp_path / "artifact.md"
    artifact.write_text(f"# Test\n\n{body}\n", encoding="utf-8")
    return artifact


def test_validator_allows_exact_figma_evidence_host(tmp_path):
    artifact = write_artifact(
        tmp_path,
        "- [Observed] Journey source. ([Sources: FigJam](https://www.figma.com/board/example))",
    )

    assert validate((artifact,)) == []


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
        (f"- [Observed] {FAKE_GITHUB_TOKEN}. ([Sources: issue](https://github.com/org/repo/issues/1))", "private path or secret-like text"),
        (f"- [Observed] [{FAKE_OPENAI_KEY}](https://github.com/org/repo) result. ([Sources: issue](https://github.com/org/repo/issues/1))", "private path or secret-like text"),
        (f"- [Observed] Result. ([Sources: credential](https://github.com/{FAKE_GITHUB_TOKEN}))", "disallowed external link"),
        ("- [Observed] Result. ([Sources: lookalike](https://figma.com.example.org/board/1))", "disallowed external link"),
        (f"- [Observed] Result. ([Sources: credential](https://www.figma.com/board/{FAKE_PASSWORD_PATH}))", "disallowed external link"),
        ("- [Observed] Result. ([Sources: path](https://github.com/org/repo?%2Fprivate%2Ftmp%2Frun))", "disallowed external link"),
        ("- [Observed] Result. ([Sources: path](https://github.com/org/repo#%2Fprivate%2Ftmp%2Frun))", "disallowed external link"),
        ("- [Observed] Result. ([Sources: path](https://github.com/org/repo?path=%2FUsers%2Falice%2Fprivate.txt))", "disallowed external link"),
        ("- [Observed] Result. ([Sources: path](https://github.com/org/repo#path=%2Fprivate%2Ftmp))", "disallowed external link"),
        (f"- [Observed] Result. ([Sources: credential](https://github.com/org/repo?value=%2567{FAKE_GITHUB_TOKEN[1:]}))", "disallowed external link"),
        (f"- [Observed] Result. ([Sources: credential](https://github.com/org/repo#value=%2567{FAKE_GITHUB_TOKEN[1:]}))", "disallowed external link"),
        (f"- [Observed] Result. ([Sources: credential](https://www.figma.com/%2567{FAKE_GITHUB_TOKEN[1:]}))", "disallowed external link"),
        ("- [Observed] Result. ([Sources: path](https://www.figma.com/%2FUsers%2Falice%2Fprivate.txt))", "disallowed external link"),
        ("- [Observed] Result. ([Sources: path](https://www.figma.com/%252Fprivate%252Ftmp%252Frun))", "disallowed external link"),
        ("- [Observed] Result. ([Sources: path](https://www.figma.com/%25252FUsers%25252Falice%25252Fprivate.txt))", "disallowed external link"),
        ("- [Observed] Result. ([Sources: path](https://www.figma.com/board/%252Fprivate%252Ftmp%252Frun))", "disallowed external link"),
        ("- [Observed] Result. ([Sources: path](https://www.figma.com/board%2F%2FUsers%2Falice%2Fprivate.txt))", "disallowed external link"),
        ("- [Observed] Result. ([Sources: path](https://www.figma.com/board%252F%252Fprivate%252Ftmp%252Frun))", "disallowed external link"),
        ("- [Observed] Result. ([Sources: path](https://www.figma.com/board%25252F%25252FUsers%25252Falice%25252Fprivate.txt))", "disallowed external link"),
        ("- [Observed] Result. ([Sources: port](https://www.figma.com:444/board/1))", "disallowed external link"),
        ("- [Observed] Result. ([Sources: port](https://www.figma.com:bad/board/1))", "disallowed external link"),
    ],
)
def test_validator_rejects_unclassified_unlinked_or_private_claims(tmp_path, body, message):
    errors = validate((write_artifact(tmp_path, body),))
    assert any(message in error for error in errors)
