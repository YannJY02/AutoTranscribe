import XCTest
@testable import InsightKitApp

final class TimestampNormalizerTests: XCTestCase {
    func testParsesMinuteAndHourTimestamps() {
        XCTAssertEqual(TimestampNormalizer.parse("00:13"), 13)
        XCTAssertEqual(TimestampNormalizer.parse("01:02:03"), 3723)
    }

    func testNormalizesShortClipProviderOvershoot() {
        XCTAssertEqual(TimestampNormalizer.normalize("01:13", duration: 30), 13)
        XCTAssertEqual(TimestampNormalizer.normalize("03:45", duration: 29.735), 29.735)
    }

    func testKeepsValidTimestampInsideDuration() {
        XCTAssertEqual(TimestampNormalizer.normalize("00:11", duration: 30), 11)
    }
}
