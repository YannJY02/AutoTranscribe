from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTENT_VIEW = ROOT / "macos/InsightKitApp/Sources/InsightKitApp/ContentView.swift"
WORKFLOW_COORDINATOR = ROOT / "macos/InsightKitApp/Sources/InsightKitApp/ViewModels/WorkflowCoordinator.swift"


def test_computed_error_banner_passes_its_action_route_to_coordinator():
    source = CONTENT_VIEW.read_text(encoding="utf-8")

    assert 'actionRoute: "open_settings"' in source
    assert "coordinator.performBannerAction(for: banner.actionRoute)" in source


def test_workflow_coordinator_can_perform_explicit_banner_action_route():
    source = WORKFLOW_COORDINATOR.read_text(encoding="utf-8")

    assert "func performBannerAction(for actionRoute: String? = nil)" in source
    assert 'let route = actionRoute ?? bannerMessage?.actionRoute ?? ""' in source
    assert "guard let bannerMessage else { return }" not in source
