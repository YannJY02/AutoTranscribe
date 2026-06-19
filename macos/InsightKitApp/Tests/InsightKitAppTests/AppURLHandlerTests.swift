import XCTest
@testable import InsightKitApp

final class AppURLHandlerTests: XCTestCase {
    func testParsesImportPathQuery() throws {
        let url = try XCTUnwrap(URL(string: "insightkit://import?path=/tmp/meeting%20sample.m4a"))

        XCTAssertEqual(
            AppURLHandler.action(from: url),
            .importFile(URL(fileURLWithPath: "/tmp/meeting sample.m4a").standardizedFileURL)
        )
    }

    func testParsesImportFileURLQuery() throws {
        let url = try XCTUnwrap(URL(string: "insightkit://import?file=file:///tmp/InsightKit%20Sample.wav"))

        XCTAssertEqual(
            AppURLHandler.action(from: url),
            .importFile(URL(fileURLWithPath: "/tmp/InsightKit Sample.wav").standardizedFileURL)
        )
    }

    func testRejectsUnsupportedSchemeOrMissingPath() throws {
        XCTAssertNil(AppURLHandler.action(from: try XCTUnwrap(URL(string: "https://import?path=/tmp/a.m4a"))))
        XCTAssertNil(AppURLHandler.action(from: try XCTUnwrap(URL(string: "insightkit://import"))))
        XCTAssertNil(AppURLHandler.action(from: try XCTUnwrap(URL(string: "insightkit://settings"))))
    }
}
