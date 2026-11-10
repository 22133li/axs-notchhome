#import "AxsNotchHomeState.h"
#import <objc/runtime.h>
#include <sys/sysctl.h>
#include <string.h>
#include <math.h>

@implementation AxsNotchHomeZoomState

- (instancetype)init {
    self = [super init];
    if (self) {
        _startedAtHomeCache = 2;
        _effectivelyHomeCache = 2;
        _cachedBounds = CGRectZero;
    }
    return self;
}

@end

static const void *kAxsNotchHomeStateKey = &kAxsNotchHomeStateKey;

AxsNotchHomeZoomState *axs_notchhome_stateForObject(id object, BOOL create) {
    if (!object) {
        return nil;
    }
    AxsNotchHomeZoomState *state = objc_getAssociatedObject(object, kAxsNotchHomeStateKey);
    if (!state && create) {
        state = [[AxsNotchHomeZoomState alloc] init];
        objc_setAssociatedObject(object, kAxsNotchHomeStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

NSString *axs_notchhome_machineName(void) {
    char machine[128] = {0};
    size_t size = sizeof(machine) - 1;
    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) != 0) {
        return @"?";
    }
    return [NSString stringWithUTF8String:machine];
}

BOOL axs_notchhome_sentinelExists(void) {
    return [[NSFileManager defaultManager]
        fileExistsAtPath:@"/var/mobile/Library/Logs/NotchHome/disable-repair"];
}

BOOL axs_notchhome_computeEnabled(void) {
    char machine[128] = {0};
    size_t size = sizeof(machine) - 1;
    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) != 0) {
        return NO;
    }
    // The audited 19-model notch list (iPhone X through 14, plus 17,5).
    static const char *const kModels[] = {
        "iPhone10,3", "iPhone10,6",
        "iPhone11,2", "iPhone11,4", "iPhone11,6", "iPhone11,8",
        "iPhone12,1", "iPhone12,3", "iPhone12,5",
        "iPhone13,1", "iPhone13,2", "iPhone13,3", "iPhone13,4",
        "iPhone14,2", "iPhone14,3", "iPhone14,4", "iPhone14,5",
        "iPhone14,7", "iPhone14,8",
        "iPhone17,5",
    };
    BOOL isNotch = NO;
    for (NSUInteger i = 0; i < sizeof(kModels) / sizeof(kModels[0]); i++) {
        if (strcmp(machine, kModels[i]) == 0) {
            isNotch = YES;
            break;
        }
    }
    if (!isNotch) {
        return NO;
    }
    BOOL disabled = [[NSFileManager defaultManager]
        fileExistsAtPath:@"/var/mobile/Library/Logs/NotchHome/disable-repair"];
    return !disabled;
}

UIWindow *axs_notchhome_findSwitcherWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *window in [(UIWindowScene *)scene windows]) {
            NSString *name = NSStringFromClass([window class]);
            if ([name isEqualToString:@"SBMainSwitcherWindow"] ||
                [name isEqualToString:@"SBHomeScreenWindow"]) {
                return window;
            }
        }
    }
    return nil;
}

BOOL axs_notchhome_isPlausibleBounds(CGRect rect) {
    CGFloat width = CGRectGetWidth(rect);
    CGFloat height = CGRectGetHeight(rect);
    if (!isfinite(width) || !isfinite(height)) {
        return NO;
    }
    if (width < 300.0 || width > 500.0 || height <= 0.0) {
        return NO;
    }
    return YES;
}
