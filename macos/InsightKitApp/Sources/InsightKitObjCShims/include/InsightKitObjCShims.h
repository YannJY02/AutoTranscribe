#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const IKObjCExceptionErrorDomain;
FOUNDATION_EXPORT NSString * const IKObjCExceptionNameKey;
FOUNDATION_EXPORT NSString * const IKObjCExceptionReasonKey;

BOOL IKCatchObjCException(void (^operation)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
