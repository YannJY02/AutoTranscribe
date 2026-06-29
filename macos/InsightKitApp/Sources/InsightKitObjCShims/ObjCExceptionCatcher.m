#import "InsightKitObjCShims.h"

NSErrorDomain const IKObjCExceptionErrorDomain = @"com.yannjy.insightkit.objc-exception";
NSString * const IKObjCExceptionNameKey = @"IKObjCExceptionName";
NSString * const IKObjCExceptionReasonKey = @"IKObjCExceptionReason";

BOOL IKCatchObjCException(void (^operation)(void), NSError **error) {
    @try {
        if (operation) {
            operation();
        }
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *name = exception.name ?: NSGenericException;
            NSString *reason = exception.reason ?: @"Objective-C exception";
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", name, reason],
                IKObjCExceptionNameKey: name,
                IKObjCExceptionReasonKey: reason
            };
            *error = [NSError errorWithDomain:IKObjCExceptionErrorDomain code:1 userInfo:userInfo];
        }
        return NO;
    }
}
