import Foundation
import InsightKitObjCShims

enum ObjCExceptionBridge {
    static func perform(_ operation: @escaping () -> Void) throws {
        var error: NSError?
        let ok = IKCatchObjCException(operation, &error)
        if ok {
            return
        }

        throw error ?? NSError(
            domain: IKObjCExceptionErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Objective-C exception"]
        )
    }
}
