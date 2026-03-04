import Foundation
import Darwin

enum InsightRuntimeDefaults {
    static var socketPath: String {
        if let custom = ProcessInfo.processInfo.environment["INSIGHTKIT_SOCKET"], !custom.isEmpty {
            return custom
        }
        return "/tmp/insightkit-app-\(getuid()).sock"
    }
}
