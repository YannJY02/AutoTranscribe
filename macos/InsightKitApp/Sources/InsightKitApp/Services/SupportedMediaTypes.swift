import Foundation
import AppKit
import UniformTypeIdentifiers

enum SupportedMediaTypes {
    static let filenameExtensions = ["mp3", "m4a", "wav", "mp4", "mov", "mkv"]

    enum LocalFileValidationError: Error, Equatable {
        case empty
        case missing(String)
        case directory(String)
        case unsupported(String)
        case unreadable(String)

        var userMessage: String {
            switch self {
            case .empty:
                return "请输入本地音频或视频文件路径。"
            case .missing(let path):
                return "找不到文件：\(path)"
            case .directory(let path):
                return "请选择文件而不是文件夹：\(path)"
            case .unsupported(let pathExtension):
                return "不支持的文件格式：.\(pathExtension)。请选择 mp3、m4a、wav、mp4、mov 或 mkv。"
            case .unreadable(let path):
                return "无法读取文件：\(path)。请检查文件权限或重新选择。"
            }
        }
    }

    static let contentTypes: [UTType] = {
        var seen = Set<String>()
        let explicitTypes = filenameExtensions.compactMap { UTType(filenameExtension: $0) }
        let broadTypes: [UTType] = [.audio, .movie, .mpeg4Movie, .mp3, .wav]
        return (explicitTypes + broadTypes).filter { type in
            seen.insert(type.identifier).inserted
        }
    }()

    static func isSupportedFile(_ url: URL) -> Bool {
        isSupportedExtension(url.pathExtension)
    }

    static func isSupportedExtension(_ pathExtension: String) -> Bool {
        filenameExtensions.contains(pathExtension.lowercased())
    }

    static func localFileURL(from input: String) -> URL? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        if let url = URL(string: value), url.isFileURL {
            return url.standardizedFileURL
        }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
    }

    static func validateLocalMediaFileURL(
        from input: String,
        fileManager: FileManager = .default
    ) -> Result<URL, LocalFileValidationError> {
        guard let url = localFileURL(from: input) else {
            return .failure(.empty)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure(.missing(url.path))
        }
        guard !isDirectory.boolValue else {
            return .failure(.directory(url.path))
        }
        guard isSupportedFile(url) else {
            return .failure(.unsupported(url.pathExtension.lowercased()))
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            return .failure(.unreadable(url.path))
        }
        return .success(url)
    }

    static func configureOpenPanel(_ panel: NSOpenPanel, allowsMultipleSelection: Bool = false) {
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // Keep system filtering broad, then validate exact extensions in app code.
        // This macOS runtime exposes m4a as a dynamic type that conforms to
        // public.data but not public.audio/public.mpeg-4-audio, which can leave
        // a valid file selected while the OK button remains disabled.
        panel.allowedContentTypes = [.data]
        panel.message = "选择音频或视频文件：mp3、m4a、wav、mp4、mov、mkv。"
        panel.prompt = "导入"
    }
}
