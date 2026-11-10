#import "AxsNotchHomeConfig.h"
#import "AxsNotchHomePreferences.h"

@interface AxsNotchHomeConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void axs_notchhome_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef info) {
    AxsNotchHomeConfig *config = (__bridge AxsNotchHomeConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config axs_notchhome_reload];
    });
}

@implementation AxsNotchHomeConfig

+ (instancetype)axs_notchhome_shared {
    static AxsNotchHomeConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reloadQueue = dispatch_queue_create("com.axs.notchhome.preferences", DISPATCH_QUEUE_SERIAL);
        [self axs_notchhome_reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, axs_notchhome_preferencesDidChange,
            (__bridge CFStringRef)AxsNotchHomePreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // Close the window between the first read and observer registration.
        dispatch_async(_reloadQueue, ^{ [self axs_notchhome_reload]; });
    }
    return self;
}

- (void)axs_notchhome_reload {
    self.snapshot = axs_notchhome_readPreferences();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AxsNotchHomePreferencesChanged object:self];
    });
}

- (id)axs_notchhome_valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    return self.snapshot[key] ?: defaultValue;
}

- (BOOL)axs_notchhome_isEnabled {
    id value = [self axs_notchhome_valueForKey:@"enabled" defaultValue:@(YES)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
