#pragma once

#import <Foundation/Foundation.h>

@interface AxsNotchHomeConfig : NSObject
+ (instancetype)axs_notchhome_shared;
- (BOOL)axs_notchhome_isEnabled;
- (id)axs_notchhome_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_notchhome_reload;
@end
