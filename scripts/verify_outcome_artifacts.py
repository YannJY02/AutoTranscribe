#!/usr/bin/env python3
"""Validate GH-74 claim labels, source links, and privacy-safe references."""

from __future__ import annotations

import re
import sys
from collections.abc import Sequence
from pathlib import Path
from urllib.parse import unquote, urlparse

if __package__:
    from .evidence_ledger import _contains_secret
else:
    from evidence_ledger import _contains_secret

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = (
    ROOT / "docs/outcomes/GH-74/outcome-review.md",
    ROOT / "docs/outcomes/GH-74/ai-product-manager-case.md",
)
LABELS = {"Observed", "Accepted intent", "Inference", "Unknown", "Future work"}
CLAIM = re.compile(r"^- \[([^]]+)] (.+)$")
LINK = re.compile(r"\[([^]]+)]\(([^)]+)\)")
PRIVATE = re.compile(
    r"(?:"
    r"(?<!\S)/(?!/)[^\s)>,]+"
    r"|[A-Za-z]:\\[^\s]+"
    r"|\\\\[^\\\s]+\\[^\s]+"
    r"|file://"
    r"|https?://[^/\s:@]+:[^@\s/]+@"
    r"|-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"
    r"|(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|password|passwd)\s*[:=]"
    r"|\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"
    r")",
    re.IGNORECASE,
)
ALLOWED_HOSTS = {"github.com", "linear.app", "www.figma.com"}


def _display(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return path.name


def validate(artifacts: Sequence[Path] = ARTIFACTS) -> list[str]:
    errors: list[str] = []
    for artifact in artifacts:
        if not artifact.is_file():
            errors.append(f"missing artifact: {_display(artifact)}")
            continue
        text = artifact.read_text(encoding="utf-8")
        privacy_text = LINK.sub(lambda match: match.group(1), text)
        if PRIVATE.search(privacy_text) or _contains_secret(privacy_text):
            errors.append(f"{_display(artifact)}: private path or secret-like text")
        claims = 0
        for line_number, line in enumerate(text.splitlines(), 1):
            if not line or line.startswith("#"):
                continue
            if not line.startswith("- "):
                errors.append(f"{_display(artifact)}:{line_number}: prose outside classified claim grammar")
                continue
            match = CLAIM.fullmatch(line)
            if not match:
                errors.append(f"{_display(artifact)}:{line_number}: unlabeled claim")
                continue
            claims += 1
            label, body = match.groups()
            if label not in LABELS:
                errors.append(f"{_display(artifact)}:{line_number}: invalid claim label {label!r}")
            if "([Sources:" not in body:
                errors.append(f"{_display(artifact)}:{line_number}: missing Sources block")
            links = [target for _, target in LINK.findall(body)]
            if not links:
                errors.append(f"{_display(artifact)}:{line_number}: missing evidence link")
            for target in links:
                parsed = urlparse(target)
                if parsed.scheme:
                    if (
                        parsed.scheme != "https"
                        or parsed.hostname not in ALLOWED_HOSTS
                        or parsed.username is not None
                        or parsed.password is not None
                        or _contains_secret(unquote(target))
                        or PRIVATE.search(unquote(parsed.query))
                        or PRIVATE.search(unquote(parsed.fragment))
                    ):
                        errors.append(f"{_display(artifact)}:{line_number}: disallowed external link {target}")
                else:
                    resolved = (artifact.parent / target).resolve()
                    if ROOT not in resolved.parents or not resolved.exists():
                        errors.append(f"{_display(artifact)}:{line_number}: missing repository link {target}")
        if claims == 0:
            errors.append(f"{_display(artifact)}: no classified claims")
    return errors


def main() -> int:
    errors = validate()
    if errors:
        print("outcome artifact verification failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"outcome artifact verification passed: {len(ARTIFACTS)} artifacts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
