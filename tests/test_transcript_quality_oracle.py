from __future__ import annotations

import json

from scripts.run_real_import_e2e import evaluate_transcript_oracle


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
