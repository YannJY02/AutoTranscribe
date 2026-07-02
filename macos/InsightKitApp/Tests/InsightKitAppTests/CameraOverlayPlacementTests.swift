import AppKit
import XCTest
@testable import InsightKitApp

final class CameraOverlayPlacementTests: XCTestCase {
    func testDefaultFrameUsesStableCapturedOverlaySize() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1600, height: 1000)

        let frame = CameraOverlayPlacement.defaultFrame(in: visibleFrame)

        XCTAssertEqual(frame.width, 256, accuracy: 0.001)
        XCTAssertEqual(frame.height, 192, accuracy: 0.001)
        XCTAssertEqual(frame.minX, 32, accuracy: 0.001)
        XCTAssertEqual(frame.minY, 32, accuracy: 0.001)
    }

    func testStoredFrameRestoresPerDisplayAndClampsIntoVisibleFrame() {
        let suiteName = "CameraOverlayPlacementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CameraOverlayPlacementStore(defaults: defaults)
        let visibleFrame = NSRect(x: 100, y: 200, width: 1200, height: 800)
        let offscreenFrame = NSRect(x: 2000, y: -500, width: 300, height: 225)

        store.save(frame: offscreenFrame, displayID: 42, visibleFrame: visibleFrame)

        let restored = store.frame(for: 42, visibleFrame: visibleFrame)
        XCTAssertEqual(restored.width, 300, accuracy: 0.001)
        XCTAssertEqual(restored.height, 225, accuracy: 0.001)
        XCTAssertLessThanOrEqual(restored.maxX, visibleFrame.maxX)
        XCTAssertGreaterThanOrEqual(restored.minX, visibleFrame.minX)
        XCTAssertLessThanOrEqual(restored.maxY, visibleFrame.maxY)
        XCTAssertGreaterThanOrEqual(restored.minY, visibleFrame.minY)
    }

    func testStoredFrameDoesNotLeakAcrossDisplays() {
        let suiteName = "CameraOverlayPlacementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CameraOverlayPlacementStore(defaults: defaults)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let customFrame = NSRect(x: 600, y: 400, width: 320, height: 240)

        store.save(frame: customFrame, displayID: 1, visibleFrame: visibleFrame)

        XCTAssertEqual(store.frame(for: 1, visibleFrame: visibleFrame), customFrame)
        XCTAssertNotEqual(store.frame(for: 2, visibleFrame: visibleFrame), customFrame)
    }
}
