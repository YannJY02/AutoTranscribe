"""Schema validation for InsightPackageV1."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

SCHEMA_PATH = Path(__file__).resolve().parent.parent / "schemas" / "insight_package_v1.json"
REQUIRED_TOP_LEVEL = {
    "session_overview",
    "highlight_insights",
    "speaker_perspectives",
    "decision_ledger",
    "action_tracks",
    "timeline_beats",
    "provenance_links",
}


class SchemaValidationError(ValueError):
    """Raised when an insight package fails validation."""



def _manual_validate(payload: dict[str, Any]) -> None:
    missing = REQUIRED_TOP_LEVEL - set(payload.keys())
    if missing:
        raise SchemaValidationError(f"missing required keys: {sorted(missing)}")

    if not isinstance(payload["session_overview"], dict):
        raise SchemaValidationError("session_overview must be object")
    for key in ["title", "overview", "topics"]:
        if key not in payload["session_overview"]:
            raise SchemaValidationError(f"session_overview.{key} is required")

    for list_key in [
        "highlight_insights",
        "speaker_perspectives",
        "decision_ledger",
        "action_tracks",
        "timeline_beats",
        "provenance_links",
    ]:
        if not isinstance(payload[list_key], list):
            raise SchemaValidationError(f"{list_key} must be array")



def validate_insight_package(payload: dict[str, Any]) -> None:
    """Validate payload against JSON schema.

    Falls back to manual checks when jsonschema isn't installed.
    """
    if not isinstance(payload, dict):
        raise SchemaValidationError("payload must be object")

    try:
        import jsonschema  # type: ignore

        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        jsonschema.validate(payload, schema)
    except ImportError:
        _manual_validate(payload)
    except Exception as exc:
        raise SchemaValidationError(str(exc)) from exc
