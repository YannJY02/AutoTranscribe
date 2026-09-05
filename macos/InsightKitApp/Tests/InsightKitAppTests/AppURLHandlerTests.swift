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

    func testParsesIsolatedSchemeOnlyForRecognizedUITestContexts() throws {
        let url = try XCTUnwrap(URL(string: "insightkit-uitest://import?path=/tmp/isolated%20sample.m4a"))
        let expected = AppURLAction.importFile(URL(fileURLWithPath: "/tmp/isolated sample.m4a").standardizedFileURL)
        let contexts: [([String: String], [String])] = [
            ([UITestStorageContext.sessionIDEnvironmentKey: UUID().uuidString], []),
            (["INSIGHTKIT_UI_TEST_MODE": "1"], []),
            ([:], ["InsightKitApp", "--ui-test-mode"]),
            ([:], ["InsightKitApp", "-INSIGHTKIT_UI_TEST_MODE", "1"]),
        ]

        for (environment, arguments) in contexts {
            XCTAssertEqual(AppURLHandler.action(from: url, environment: environment, arguments: arguments), expected)
        }
        XCTAssertNil(AppURLHandler.action(from: url, environment: [:], arguments: []))
        XCTAssertNil(AppURLHandler.action(from: url, environment: ["INSIGHTKIT_UI_TEST_MODE": "0"], arguments: []))
        XCTAssertNil(AppURLHandler.action(from: url, environment: [:], arguments: ["-INSIGHTKIT_UI_TEST_MODE", "0"]))
    }

    func testProductionSchemeAndImportValidationRemainUnchangedInUITestContext() throws {
        let environment = [UITestStorageContext.sessionIDEnvironmentKey: UUID().uuidString]
        let url = try XCTUnwrap(URL(string: "INSIGHTKIT://import?file=file:///tmp/sample.wav"))
        let expected = AppURLAction.importFile(URL(fileURLWithPath: "/tmp/sample.wav").standardizedFileURL)
        XCTAssertEqual(AppURLHandler.action(from: url, environment: [:], arguments: []), expected)
        XCTAssertEqual(AppURLHandler.action(from: url, environment: environment, arguments: []), expected)

        let isolatedURL = try XCTUnwrap(URL(string: "INSIGHTKIT-UITEST://import?file=file:///tmp/sample.wav"))
        XCTAssertEqual(AppURLHandler.action(from: isolatedURL, environment: environment, arguments: []), expected)
        for value in ["insightkit-uitest://import", "insightkit-uitest://settings", "https://import?path=/tmp/a.m4a"] {
            XCTAssertNil(AppURLHandler.action(from: try XCTUnwrap(URL(string: value)), environment: environment, arguments: []))
        }
    }
}
