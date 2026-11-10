#pragma once

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Signature-checked hook slot, mirroring the audited NHHookSlot design:
// a hook is installed with MSHookMessageEx only when the target class and
// method exist and the live type encodings match the expected return and
// argument types ("@" as an expected argument type accepts any object type).
@interface AxsNotchHomeHookSlot : NSObject
@property (nonatomic, copy, readonly) NSString *className;
@property (nonatomic, copy, readonly) NSString *selectorName;
@property (nonatomic, strong, readonly) NSLock *lock;
@property (nonatomic, assign, readonly) IMP saved;
@property (nonatomic, assign, readonly) BOOL installed;
+ (instancetype)axs_notchhome_slotWithClassName:(NSString *)className selectorName:(NSString *)selectorName;
- (BOOL)axs_notchhome_installWithReplacement:(IMP)replacement
                                  returnType:(const char *)returnType
                               argumentTypes:(NSArray<NSString *> *)argumentTypes;
@end

// Validates a method signature the same way and returns its IMP without
// installing any hook (used for the original's direct-lookup helpers).
#ifdef __cplusplus
extern "C" {
#endif
IMP axs_notchhome_lookupIMP(NSString *className, NSString *selectorName,
                            const char *returnType, NSArray<NSString *> *argumentTypes);
#ifdef __cplusplus
}
#endif
