import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import InsightKitApp

final class SupportedMediaTypesTests: XCTestCase {
    func testAdvertisedAudioAndVideoExtensionsAreSupported() {
        for pathExtension in ["mp3", "m4a", "wav", "mp4", "mov", "mkv"] {
            XCTAssertTrue(
                SupportedMediaTypes.isSupportedExtension(pathExtension),
                "Expected \(pathExtension) to match the import UI support text"
            )
        }
    }

    func testOpenPanelTypesIncludeM4AWhenSystemExposesAType() throws {
        let m4aType = try XCTUnwrap(UTType(filenameExtension: "m4a"))
        XCTAssertTrue(
            SupportedMediaTypes.contentTypes.contains { $0.identifier == m4aType.identifier },
            "The app import panel should explicitly allow m4a files"
        )
    }

    func testOpenPanelDefaultsToOneFileForSerializedPilotAttempts() {
        let panel = NSOpenPanel()
        SupportedMediaTypes.configureOpenPanel(panel)

        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertTrue(
            panel.allowedContentTypes.contains(.data),
            "The open panel should allow dynamic m4a types that conform to public.data and defer exact media validation to app code."
        )
        XCTAssertEqual(panel.prompt, "导入")
    }

    func testLocalFileURLNormalizesQuotedAndFileSchemePaths() throws {
        let quoted = SupportedMediaTypes.localFileURL(from: "\"~/Downloads/meeting sample.m4a\"")
        XCTAssertEqual(
            quoted?.path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/meeting sample.m4a")
                .standardizedFileURL
                .path
        )

        let fileURL = try XCTUnwrap(URL(string: "file:///tmp/InsightKit%20Sample.wav"))
        XCTAssertEqual(
            SupportedMediaTypes.localFileURL(from: fileURL.absoluteString)?.path,
            "/tmp/InsightKit Sample.wav"
        )
    }

    func testValidateLocalMediaFileURLAcceptsExistingSupportedMedia() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = root.appendingPathComponent("sample.m4a")
        try Data("real path validation sample".utf8).write(to: audio)

        switch SupportedMediaTypes.validateLocalMediaFileURL(from: "\"\(audio.path)\"") {
        case .success(let url):
            XCTAssertEqual(url.path, audio.standardizedFileURL.path)
        case .failure(let error):
            XCTFail("Expected supported media path, got \(error)")
        }
    }

    func testValidateLocalMediaFileURLReportsActionableErrors() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let unsupported = root.appendingPathComponent("notes.txt")
        try Data("not media".utf8).write(to: unsupported)

        XCTAssertEqual(
            try XCTUnwrap(validationError(for: "   ")).userMessage,
            "请输入本地音频或视频文件路径。"
        )
        XCTAssertEqual(
            try XCTUnwrap(validationError(for: root.path)).userMessage,
            "请选择文件而不是文件夹：\(root.standardizedFileURL.path)"
        )
        XCTAssertEqual(
            try XCTUnwrap(validationError(for: unsupported.path)).userMessage,
            "不支持的文件格式：.txt。请选择 mp3、m4a、wav、mp4、mov 或 mkv。"
        )

        let missing = root.appendingPathComponent("missing.wav")
        XCTAssertEqual(
            try XCTUnwrap(validationError(for: missing.path)).userMessage,
            "找不到文件：\(missing.standardizedFileURL.path)"
        )
    }

    func testValidateLocalMediaFileURLReportsUnreadableSupportedFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let unreadable = root.appendingPathComponent("private.m4a")
        try Data("not readable".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
        }

        XCTAssertFalse(FileManager.default.isReadableFile(atPath: unreadable.path))
        XCTAssertEqual(
            try XCTUnwrap(validationError(for: unreadable.path)).userMessage,
            "无法读取文件：\(unreadable.standardizedFileURL.path)。请检查文件权限或重新选择。"
        )
    }

    private func validationError(for input: String) -> SupportedMediaTypes.LocalFileValidationError? {
        switch SupportedMediaTypes.validateLocalMediaFileURL(from: input) {
        case .success:
            return nil
        case .failure(let error):
            return error
        }
    }
}
