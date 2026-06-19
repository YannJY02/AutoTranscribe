from pathlib import Path

from scripts.run_packaged_app_url_import_smoke import build_import_url, job_matches_sample


def test_build_import_url_percent_encodes_local_path():
    url = build_import_url(Path("/tmp/InsightKit Sample 1.m4a"))

    assert url == "insightkit://import?path=%2Ftmp%2FInsightKit%20Sample%201.m4a"


def test_job_matches_sample_by_resolved_source_path(tmp_path):
    sample = tmp_path / "meeting.m4a"
    sample.write_bytes(b"audio")

    assert job_matches_sample({"source_path": str(sample)}, sample)
    assert not job_matches_sample({"source_path": str(tmp_path / "other.m4a")}, sample)
    assert not job_matches_sample({}, sample)
