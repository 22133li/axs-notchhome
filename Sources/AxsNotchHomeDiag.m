#import "AxsNotchHomeDiag.h"
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

NSUInteger axs_notchhome_diagWillBegin = 0;
NSUInteger axs_notchhome_diagDidEnd = 0;
NSUInteger axs_notchhome_diagFrameCalls = 0;
NSUInteger axs_notchhome_diagFrameActive = 0;
NSUInteger axs_notchhome_diagIconOK = 0;
NSUInteger axs_notchhome_diagScaleCalls = 0;
NSUInteger axs_notchhome_diagCornerCalls = 0;
NSUInteger axs_notchhome_diagMatchCalls = 0;
NSUInteger axs_notchhome_diagAnimCalls = 0;
NSUInteger axs_notchhome_diagAnimSkip = 0;
NSUInteger axs_notchhome_diagAnimResp = 0;
NSUInteger axs_notchhome_diagLayoutResp = 0;
NSInteger axs_notchhome_diagLastStartedAtHome = -99;
NSInteger axs_notchhome_diagLastBoundsOK = -99;

static NSString *axs_notchhome_diagPath(void) {
    NSString *dir = @"/var/mobile/Library/Logs/AxsNotchHome";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"diag.txt"];
}

void axs_notchhome_diagLogF(const char *format, ...) {
    char buffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    NSString *path = axs_notchhome_diagPath();
    NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                       dateStyle:NSDateFormatterNoStyle
                                                       timeStyle:NSDateFormatterMediumStyle];
    NSString *line = [NSString stringWithFormat:@"%@ %s\n", stamp, buffer];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle) {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    } else {
        [data writeToFile:path atomically:YES];
    }
}
