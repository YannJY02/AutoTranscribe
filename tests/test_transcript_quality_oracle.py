from __future__ import annotations

import json
from hashlib import sha256

from scripts.run_real_import_e2e import (
    evaluate_transcript_oracle,
    first_search_token,
    validate_frozen_fixture_pair,
)


def write_reference(tmp_path, *, language: str, text: str):
    path = tmp_path / "reference.json"
    path.write_text(
        json.dumps(
            {
                "fixture_id": "test-fixture",
                "language": language,
                "segments": [{"text": text}],
            }
        ),
        encoding="utf-8",
    )
    return path


def test_transcript_oracle_records_english_wer(tmp_path):
    reference = write_reference(tmp_path, language="English", text="The quick brown fox.")

    result = evaluate_transcript_oracle(
        reference,
        [{"text": "the quick blue fox"}],
    )

    assert result["passed"] is True
    assert result["metrics"] == {"asr.wer_pct": 25.0}
    assert result["quality_budget"] == "not_set"


def test_transcript_oracle_records_chinese_cer(tmp_path):
    reference = write_reference(tmp_path, language="Chinese", text="你好，世界。")

    result = evaluate_transcript_oracle(
        reference,
        [{"text": "你好世间"}],
    )

    assert result["passed"] is True
    assert result["metrics"] == {"asr.cer_pct": 25.0}


def test_transcript_oracle_rejects_empty_hypothesis(tmp_path):
    reference = write_reference(tmp_path, language="English", text="hello world")

    result = evaluate_transcript_oracle(reference, [{"text": "  "}])

    assert result["passed"] is False
    assert result["failed_assertions"] == ["hypothesis_text_present"]


def test_fts_search_token_supports_chinese_transcripts():
    assert first_search_token([{"text": "我们先确认今天的目标。"}]) == "我们先确认今天的目标"


def test_frozen_manifest_rejects_mismatched_media_and_reference(tmp_path):
    media = tmp_path / "short-en.m4a"
    media.write_bytes(b"english media")
    reference = write_reference(tmp_path, language="English", text="hello world")
    other_media = tmp_path / "short-zh.m4a"
    other_media.write_bytes(b"chinese media")
    other_reference = tmp_path / "short-zh.json"
    other_reference.write_text(reference.read_text(encoding="utf-8"), encoding="utf-8")

    def pin(path):
        content = path.read_bytes()
        return {
            "absolute_path": str(path.resolve()),
            "byte_size": len(content),
            "sha256": sha256(content).hexdigest(),
        }

    manifest = tmp_path / "manifest.json"
    manifest.write_text(
        json.dumps(
            {
                "status": "frozen",
                "safety": {"synthetic_only": True},
                "fixtures": [
                    {
                        "fixture_id": "short-en",
                        "media": [pin(media)],
                        "reference_transcript": pin(reference),
                    },
                    {
                        "fixture_id": "short-zh",
                        "media": [pin(other_media)],
                        "reference_transcript": pin(other_reference),
                    },
                ],
            }
        ),
        encoding="utf-8",
    )

    try:
        validate_frozen_fixture_pair(manifest, media, other_reference)
    except ValueError as exc:
        assert "same frozen fixture" in str(exc)
    else:
        raise AssertionError("mismatched frozen fixture pair was accepted")

    other_reference.write_text("{}", encoding="utf-8")
    try:
        validate_frozen_fixture_pair(manifest, other_media, other_reference)
    except ValueError as exc:
        assert "hash drift" in str(exc)
    else:
        raise AssertionError("modified frozen reference was accepted")


def test_transcript_oracle_rejects_mixed_language_until_scoring_is_defined(tmp_path):
    reference = write_reference(tmp_path, language="Chinese/English", text="你好 hello")

    result = evaluate_transcript_oracle(reference, [{"text": "您好 hello"}])

    assert result["passed"] is False
    assert result["failed_assertions"] == ["language_supported"]
