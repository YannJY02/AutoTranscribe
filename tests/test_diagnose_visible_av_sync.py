import math

import pytest

from scripts.diagnose_visible_av_sync import measure_offset


def test_reports_video_lag_in_milliseconds():
    offset_ms, direction, passed = measure_offset(4.400625, 4.835)

    assert offset_ms == pytest.approx(434.375)
    assert direction == "video_lags_audio"
    assert passed is False


def test_reports_video_lead():
    offset_ms, direction, passed = measure_offset(1.2, 1.0)

    assert offset_ms == pytest.approx(-200)
    assert direction == "video_leads_audio"
    assert passed is False


def test_requires_offset_strictly_under_tolerance():
    assert measure_offset(1.0, 1.1499)[2] is True
    assert measure_offset(1.0, 1.15)[2] is False


@pytest.mark.parametrize("value", [math.nan, math.inf, -math.inf])
def test_rejects_non_finite_values(value):
    with pytest.raises(ValueError, match="must be finite"):
        measure_offset(1.0, value)


@pytest.mark.parametrize("audio_event_sec, video_event_sec", [(-0.1, 1.0), (1.0, -0.1)])
def test_rejects_negative_event_times(audio_event_sec, video_event_sec):
    with pytest.raises(ValueError, match="must be non-negative"):
        measure_offset(audio_event_sec, video_event_sec)


@pytest.mark.parametrize("tolerance_ms", [0, -1])
def test_rejects_non_positive_tolerance(tolerance_ms):
    with pytest.raises(ValueError, match="must be positive"):
        measure_offset(1.0, 1.0, tolerance_ms)
