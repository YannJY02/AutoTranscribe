import Foundation
import Darwin

enum InsightRuntimeDefaults {
    static var socketPath: String {
        resolvedSocketPath(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    static func resolvedSocketPath(environment: [String: String], arguments: [String] = []) -> String {
        if let context = UITestStorageContext.resolve(environment: environment, arguments: arguments) {
            return context.socketPath
        }
        if let custom = environment["INSIGHTKIT_SOCKET"], !custom.isEmpty {
            return custom
        }
        return "/tmp/insightkit-app-\(getuid()).sock"
    }
}
