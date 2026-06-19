from scripts.notifier import (
    ROUTE_DETAILS,
    ROUTE_OPTIONS,
    ROUTE_RECOMMENDATIONS,
    _route_help_text,
    route_from_dialog_result,
)


def test_route_labels_map_to_supported_engines():
    assert route_from_dialog_result("Whisper Turbo（通用/快速）") == "whisper"
    assert route_from_dialog_result("FunASR（中文优先）") == "funasr"
    assert route_from_dialog_result("Qwen3-ASR MLX（能力上限）") == "qwen-mlx"
    assert route_from_dialog_result("qwen-mlx") == "qwen-mlx"
    assert route_from_dialog_result("") == ""
    assert set(ROUTE_OPTIONS.values()) == {"whisper", "funasr", "qwen-mlx"}


def test_route_recommendations_are_short_and_complete():
    assert set(ROUTE_RECOMMENDATIONS) == set(ROUTE_OPTIONS)
    assert all(route.recommendation for route in ROUTE_DETAILS)
    assert ROUTE_RECOMMENDATIONS["Whisper Turbo（通用/快速）"] == "默认推荐：速度快、通用、最稳。"
    assert ROUTE_RECOMMENDATIONS["FunASR（中文优先）"] == "中文长音频/会议优先。"
    assert ROUTE_RECOMMENDATIONS["Qwen3-ASR MLX（能力上限）"] == "准确率上限：复杂中英混合。"


def test_route_mapping_accepts_multiline_display_text():
    for route in ROUTE_DETAILS:
        display_text = f"{route.label}\n  {route.recommendation}"
        assert route_from_dialog_result(display_text) == route.engine


def test_applescript_fallback_help_text_includes_each_route_hint():
    help_text = _route_help_text()
    for route in ROUTE_DETAILS:
        assert route.label in help_text
        assert route.recommendation in help_text
