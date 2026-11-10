#pragma once

#import <Foundation/Foundation.h>

// Diagnostic build support: appends plain-text lines to
// /var/mobile/Library/Logs/AxsNotchHome/diag.txt so an on-device run can
// report which link of the chain (gate, install, state, geometry) failed.
#ifdef __cplusplus
extern "C" {
#endif
void axs_notchhome_diagLogF(const char *format, ...);
extern NSUInteger axs_notchhome_diagWillBegin;
extern NSUInteger axs_notchhome_diagDidEnd;
extern NSUInteger axs_notchhome_diagFrameCalls;
extern NSUInteger axs_notchhome_diagFrameActive;
extern NSUInteger axs_notchhome_diagIconOK;
extern NSUInteger axs_notchhome_diagScaleCalls;
extern NSUInteger axs_notchhome_diagCornerCalls;
extern NSUInteger axs_notchhome_diagMatchCalls;
extern NSUInteger axs_notchhome_diagAnimCalls;
extern NSUInteger axs_notchhome_diagAnimSkip;
extern NSUInteger axs_notchhome_diagAnimResp;
extern NSInteger axs_notchhome_diagLastStartedAtHome;
extern NSInteger axs_notchhome_diagLastBoundsOK;
#ifdef __cplusplus
}
#endif
