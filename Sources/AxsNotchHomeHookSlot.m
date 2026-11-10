#import "AxsNotchHomeHookSlot.h"
#include <string.h>
#include <stdlib.h>

#import <substrate.h>

static BOOL axs_notchhome_typeMatches(const char *actual, NSString *expected) {
    if (!actual || !expected) {
        return NO;
    }
    // "@" as the expected type is a wildcard for any object type.
    if ([expected isEqualToString:@"@"]) {
        return actual[0] == '@';
    }
    return strcmp(actual, expected.UTF8String) == 0;
}

static BOOL axs_notchhome_validateMethod(Method method, const char *returnType,
                                       NSArray<NSString *> *argumentTypes) {
    if (!method) {
        return NO;
    }
    if (method_getNumberOfArguments(method) != (unsigned)(argumentTypes.count + 2)) {
        return NO;
    }
    char *actualReturn = method_copyReturnType(method);
    BOOL returnOK = actualReturn && strcmp(actualReturn, returnType) == 0;
    free(actualReturn);
    if (!returnOK) {
        return NO;
    }
    for (NSUInteger i = 0; i < argumentTypes.count; i++) {
        char *actualArg = method_copyArgumentType(method, (unsigned)(i + 2));
        BOOL argOK = axs_notchhome_typeMatches(actualArg, argumentTypes[i]);
        free(actualArg);
        if (!argOK) {
            return NO;
        }
    }
    return YES;
}

@interface AxsNotchHomeHookSlot ()
@property (nonatomic, copy, readwrite) NSString *className;
@property (nonatomic, copy, readwrite) NSString *selectorName;
@property (nonatomic, strong, readwrite) NSLock *lock;
@property (nonatomic, assign, readwrite) IMP saved;
@property (nonatomic, assign, readwrite) BOOL installed;
@end

@implementation AxsNotchHomeHookSlot

+ (instancetype)axs_notchhome_slotWithClassName:(NSString *)className selectorName:(NSString *)selectorName {
    AxsNotchHomeHookSlot *slot = [[self alloc] init];
    slot.className = className;
    slot.selectorName = selectorName;
    slot.lock = [[NSLock alloc] init];
    slot.saved = NULL;
    slot.installed = NO;
    return slot;
}

- (BOOL)axs_notchhome_installWithReplacement:(IMP)replacement
                                  returnType:(const char *)returnType
                               argumentTypes:(NSArray<NSString *> *)argumentTypes {
    [self.lock lock];
    BOOL already = self.installed;
    [self.lock unlock];
    if (already || !replacement || !returnType) {
        return already;
    }
    Class cls = NSClassFromString(self.className);
    SEL sel = NSSelectorFromString(self.selectorName);
    if (!cls || !sel) {
        return NO;
    }
    Method method = class_getInstanceMethod(cls, sel);
    if (!axs_notchhome_validateMethod(method, returnType, argumentTypes)) {
        return NO;
    }
    [self.lock lock];
    self.saved = method_getImplementation(method);
    [self.lock unlock];
    IMP original = NULL;
    MSHookMessageEx(cls, sel, replacement, &original);
    [self.lock lock];
    if (original) {
        self.saved = original;
    }
    self.installed = YES;
    [self.lock unlock];
    return YES;
}

@end

IMP axs_notchhome_lookupIMP(NSString *className, NSString *selectorName,
                            const char *returnType, NSArray<NSString *> *argumentTypes) {
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(selectorName);
    if (!cls || !sel || !returnType) {
        return NULL;
    }
    Method method = class_getInstanceMethod(cls, sel);
    if (!axs_notchhome_validateMethod(method, returnType, argumentTypes)) {
        return NULL;
    }
    return method_getImplementation(method);
}
