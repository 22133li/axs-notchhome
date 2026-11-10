#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Per-modifier transition state, mirroring the audited NHZoomState:
// attached to each modifier instance as an associated object.
// Tri-state cache fields use 0 = NO, 1 = YES, 2 = unknown (the audited
// original used the byte value 2 as its "unknown" sentinel).
@interface AxsNotchHomeZoomState : NSObject
@property (nonatomic, assign) NSInteger startedAtHomeCache;
@property (nonatomic, assign) NSInteger effectivelyHomeCache;
@property (nonatomic, assign) BOOL began;
@property (nonatomic, assign) BOOL ended;
@property (nonatomic, assign) BOOL finishing;
@property (nonatomic, assign) NSInteger mutationDepth;
@property (nonatomic, assign) CGRect cachedBounds;
@property (nonatomic, assign) BOOL cachedBoundsValid;
@property (nonatomic, assign) double lastOrigScale0;
@property (nonatomic, assign) double lastOrigScale1;
@property (nonatomic, weak) UIWindow *targetWindow;
@property (nonatomic, weak) id appLayout;
@end

#ifdef __cplusplus
extern "C" {
#endif
// Returns the state attached to the object, optionally creating it.
AxsNotchHomeZoomState *axs_notchhome_stateForObject(id object, BOOL create);

// Enable gate, computed once at load (mirrors NHStart):
// process is SpringBoard (guaranteed by the filter plist, rechecked),
// hw.machine is in the audited 19-model notch list, and the sentinel
// file /var/mobile/Library/Logs/NotchHome/disable-repair does not exist.
BOOL axs_notchhome_computeEnabled(void);

// Finds SpringBoard's switcher or home-screen window, mirroring the
// audited window search (connectedScenes -> windows -> class name).
UIWindow *axs_notchhome_findSwitcherWindow(void);

// Plausibility check for a captured bounds rect, mirroring the audited
// validator (finite, width between 300 and 500 points).
BOOL axs_notchhome_isPlausibleBounds(CGRect rect);
NSString *axs_notchhome_machineName(void);
BOOL axs_notchhome_sentinelExists(void);
#ifdef __cplusplus
}
#endif
