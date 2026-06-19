import Foundation

enum AppURLAction: Equatable {
    case importFile(URL)
}

enum AppURLHandler {
    static let scheme = "insightkit"

    static func action(from url: URL) -> AppURLAction? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        let command = normalizedCommand(from: url)
        switch command {
        case "import":
            guard let value = queryValue(named: "path", in: url) ?? queryValue(named: "file", in: url),
                  let fileURL = SupportedMediaTypes.localFileURL(from: value) else {
                return nil
            }
            return .importFile(fileURL)
        default:
            return nil
        }
    }

    private static func normalizedCommand(from url: URL) -> String {
        if let host = url.host, !host.isEmpty {
            return host.lowercased()
        }
        return url.pathComponents
            .first { $0 != "/" }
            .map { $0.lowercased() } ?? ""
    }

    private static func queryValue(named name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
