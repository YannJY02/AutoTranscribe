#!/usr/bin/env python3
"""Validate GH-74 claim labels, source links, and privacy-safe references."""

from __future__ import annotations

import re
import sys
from collections.abc import Sequence
from html import unescape
from pathlib import Path
from urllib.parse import parse_qsl, unquote, urlparse

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


def _decode_once(value: str) -> str:
    return unquote(unescape(value))


def _fully_decode(value: str) -> str:
    while True:
        decoded = _decode_once(value)
        if decoded == value:
            return value
        value = decoded


def _contains_private_or_secret(value: str, *, reject_double_slash: bool = False) -> bool:
    while True:
        decoded = _decode_once(value)
        if (reject_double_slash and "//" in decoded) or PRIVATE.search(decoded) or _contains_secret(decoded):
            return True
        if decoded == value:
            return False
        value = decoded


def _contains_private_component(component: str) -> bool:
    while True:
        decoded = _decode_once(component)
        values = [decoded]
        values.extend(value for pair in parse_qsl(decoded, keep_blank_values=True) for value in pair)
        if any(_contains_private_or_secret(value) for value in values):
            return True
        if decoded == component:
            return False
        component = decoded


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
                try:
                    parsed = urlparse(target)
                except ValueError:
                    errors.append(f"{_display(artifact)}:{line_number}: disallowed external link {target}")
                    continue
                if parsed.scheme:
                    try:
                        parsed_urls = (parsed, urlparse(_fully_decode(target)))
                        allowed_identity = all(
                            url.scheme == "https"
                            and url.hostname in ALLOWED_HOSTS
                            and url.port in {None, 443}
                            and url.username is None
                            and url.password is None
                            for url in parsed_urls
                        )
                    except ValueError:
                        parsed_urls = (parsed,)
                        allowed_identity = False
                    if (
                        not allowed_identity
                        or _contains_private_or_secret(target)
                        or any(
                            _contains_private_or_secret(
                                url.path.removeprefix("/"), reject_double_slash=True
                            )
                            for url in parsed_urls
                        )
                        or any(
                            _contains_private_component(component)
                            for url in parsed_urls
                            for component in (
                                url.path.removeprefix("/"),
                                url.query,
                                url.fragment,
                            )
                        )
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
