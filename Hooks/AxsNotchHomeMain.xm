#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AxsNotchHomeConfig.h"
#import "AxsNotchHomePrivate.h"
#import "AxsNotchHomeHookSlot.h"
#import "AxsNotchHomeState.h"
#import "AxsNotchHomeDiag.h"
#include <string.h>
#include <stdlib.h>

// Compatible reimplementation of NotchHome 0.5.0, built from the static
// audit in NotchHome-0.5.0-audit.md. Architecture mirrors the original:
// a SpringBoard/load gate, signature-checked MSHookMessageEx slots, a
// per-modifier state object, and two install passes (now and +5s).
// Documented deviations: a missing original IMP degrades to a safe
// fallback instead of the original's trap, and the two unclosed
// parameterized installs of the original are not reproduced.

static NSString *const kAxsNotchHomeModifierClass = @"SBFullScreenToHomeIconZoomSwitcherModifier";
static NSString *const kAxsNotchHomeFluidVCClass = @"SBFluidSwitcherViewController";
static NSString *const kAxsNotchHomeGestureModifierClass = @"SBGestureInitiatedIconZoomAnimationAttributesSwitcherModifier";
static const char *const kAxsNotchHomeCGRectEncoding = "{CGRect={CGPoint=dd}{CGSize=dd}}";
static const char *const kAxsNotchHomeRadiiEncoding = "{UIRectCornerRadii=dddd}";

// Animation polish constants recovered from the original's __const table
// and applied in its animation-attributes region. Per-constant semantics
// were not statically closed, so these are the documented approximation:
// position damping 1.28, scale damping 0.97.
// Animation spring constants measured from the original tweak (wrap
// captures, 2026-11-10): during an app-to-home transition the gesture
// modifier is queried alternately for the transition's own app layout
// (set A) and the other layout element (set B); stock values are
// velocity-computed and jitter, the original's are exact constants.
// Each set is {position damping, position response, scale damping,
// scale response}; update modes stay untouched (0 in both worlds).
static const double kAxsNotchHomeZoomPosDamping = 0.979;
static const double kAxsNotchHomeZoomPosResponse = 0.788;
static const double kAxsNotchHomeZoomScaleDamping = 0.979;
static const double kAxsNotchHomeZoomScaleResponse = 0.704;
static const double kAxsNotchHomeOtherPosDamping = 0.883;
static const double kAxsNotchHomeOtherPosResponse = 0.434;
static const double kAxsNotchHomeOtherScaleDamping = 0.979;
static const double kAxsNotchHomeOtherScaleResponse = 0.550;

// The current transition's app layout (captured from the zoom modifier
// at transitionWillBegin) and whether the notch state is active; the
// gesture-modifier attributes hook uses them to pick set A vs set B.
static id sAxsNotchHomeCurrentLayout = nil;
static BOOL sAxsNotchHomeTransitionActive = NO;

// Notch suction targets, MEASURED from the original tweak's own hook
// returns (wrap capture on iPhone14,3, bounds 428x926): the original
// returns the fullscreen-sized frame recentered to (boundsW/2, -30),
// scale 0.061 (stock: 428x428 at icon center, scale 0.150), and corner
// radii = boundsW * 0.2 = 85.6 on this device.
static const double kAxsNotchHomeNotchCenterY = -30.0;
static const double kAxsNotchHomeNotchScale = 0.061;
static const double kAxsNotchHomeNotchRadiusFactor = 0.2;




static BOOL sAxsNotchHomeEnabled = NO;

static AxsNotchHomeHookSlot *sAxsNotchHomeSlotIsHome;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotWillBegin;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotDidEnd;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotInterrupt;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotFrame;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotScale;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotCorner;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotAnimAttrs;

// Direct (non-hooked) lookup: which layout index is the app being zoomed.
static IMP sAxsNotchHomeZoomCheckIMP = NULL;



static IMP axs_notchhome_savedIMP(AxsNotchHomeHookSlot *slot) {
    if (!slot) {
        return NULL;
    }
    [slot.lock lock];
    IMP saved = slot.saved;
    [slot.lock unlock];
    return saved;
}

static BOOL axs_notchhome_stateActive(AxsNotchHomeZoomState *state) {
    return sAxsNotchHomeEnabled && [NSThread isMainThread] && state &&
           state.began && !state.finishing && state.startedAtHomeCache == 0;
}

static BOOL axs_notchhome_isZoomIndex(id modifier, NSUInteger index) {
    if (sAxsNotchHomeZoomCheckIMP) {
        return ((BOOL (*)(id, SEL, NSUInteger))sAxsNotchHomeZoomCheckIMP)(
            modifier, NSSelectorFromString(@"_isIndexZoomAppLayout:"), index);
    }
    return index == 0;
}

#pragma mark - Hook implementations

static BOOL axs_notchhome_hookIsEffectivelyHome(id self, SEL _cmd) {
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotIsHome);
    BOOL result = orig ? ((BOOL (*)(id, SEL))orig)(self, _cmd) : NO;
    if ([NSThread isMainThread]) {
        AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, NO);
        if (state && state.effectivelyHomeCache == 2) {
            state.effectivelyHomeCache = result ? 1 : 0;
        }
        // Measured from the original (wrap6): during an app-to-home
        // transition _isEffectivelyHome returns YES on every call (76/0),
        // while stock leaks a couple of NO answers at the start (which
        // leave the home screen half-presented: dimmed icons, a flash of
        // the leaving app, and zoom participation missing for apps from
        // other pages and folders). Mirror the original: while the notch
        // state is active the answer is YES.
        if (axs_notchhome_stateActive(state)) {
            return YES;
        }
    }
    return result;
}

static unsigned long sStLogFrames = 0;

static void axs_notchhome_captureBegin(id self, AxsNotchHomeZoomState *state) {
    IMP origIsHome = axs_notchhome_savedIMP(sAxsNotchHomeSlotIsHome);
    if (origIsHome) {
        BOOL atHome = ((BOOL (*)(id, SEL))origIsHome)(self, NSSelectorFromString(@"_isEffectivelyHome"));
        state.startedAtHomeCache = atHome ? 1 : 0;
        state.effectivelyHomeCache = state.startedAtHomeCache;
    }
    state.began = YES;
    state.ended = NO;
    state.finishing = NO;
    UIWindow *window = axs_notchhome_findSwitcherWindow();
    state.targetWindow = window;
    CGRect bounds = window ? window.bounds : CGRectZero;
    state.cachedBounds = bounds;
    state.cachedBoundsValid = axs_notchhome_isPlausibleBounds(bounds);
    sStLogFrames = 0;
    axs_notchhome_diagLogF("stlog begin self=%p started=%lld", self,
        (long long)state.startedAtHomeCache);
}

static id axs_notchhome_hookTransitionWillBegin(id self, SEL _cmd) {
    axs_notchhome_diagWillBegin++;
    if (sAxsNotchHomeEnabled && [NSThread isMainThread]) {
        @try {
            AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, YES);
            axs_notchhome_captureBegin(self, state);
            sAxsNotchHomeTransitionActive = axs_notchhome_stateActive(state);
            sAxsNotchHomeCurrentLayout = nil;
            @try {
                sAxsNotchHomeCurrentLayout = [self valueForKey:@"appLayout"];
            } @catch (NSException *exception) {
                sAxsNotchHomeCurrentLayout = nil;
            }
            axs_notchhome_diagLastStartedAtHome = state.startedAtHomeCache;
            axs_notchhome_diagLastBoundsOK = state.cachedBoundsValid ? 1 : 0;
        } @catch (NSException *exception) {
        }
    }
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotWillBegin);
    return orig ? ((id (*)(id, SEL))orig)(self, _cmd) : nil;
}

static void axs_notchhome_preFinish(id self) {
    if ([NSThread isMainThread]) {
        AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, NO);
        if (state) {
            state.finishing = YES;
        }
    }
}

static void axs_notchhome_postFinish(id self) {
    axs_notchhome_diagDidEnd++;
    axs_notchhome_diagLogF("transition end: willBegin=%lu didEnd=%lu frame=%lu frameActive=%lu iconOK=%lu scale=%lu corner=%lu match=%lu anim=%lu animSkip=%lu animResp=%lu layoutResp=%lu lastStartedAtHome=%ld boundsOK=%ld",
        (unsigned long)axs_notchhome_diagWillBegin, (unsigned long)axs_notchhome_diagDidEnd,
        (unsigned long)axs_notchhome_diagFrameCalls, (unsigned long)axs_notchhome_diagFrameActive,
        (unsigned long)axs_notchhome_diagIconOK, (unsigned long)axs_notchhome_diagScaleCalls,
        (unsigned long)axs_notchhome_diagCornerCalls, (unsigned long)axs_notchhome_diagMatchCalls,
        (unsigned long)axs_notchhome_diagAnimCalls, (unsigned long)axs_notchhome_diagAnimSkip,
        (unsigned long)axs_notchhome_diagAnimResp, axs_notchhome_diagLayoutResp,
        (long)axs_notchhome_diagLastStartedAtHome, (long)axs_notchhome_diagLastBoundsOK);
    if ([NSThread isMainThread]) {
        AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, NO);
        if (state) {
            state.ended = YES;
            state.began = NO;
            state.finishing = NO;
            state.cachedBoundsValid = NO;
            state.cachedBounds = CGRectZero;
            state.targetWindow = nil;
            state.appLayout = nil;
        }
        sAxsNotchHomeTransitionActive = NO;
        sAxsNotchHomeCurrentLayout = nil;
    }
}

static id axs_notchhome_hookTransitionDidEnd(id self, SEL _cmd) {
    if (sAxsNotchHomeEnabled) {
        axs_notchhome_preFinish(self);
    }
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotDidEnd);
    id result = orig ? ((id (*)(id, SEL))orig)(self, _cmd) : nil;
    if (sAxsNotchHomeEnabled) {
        axs_notchhome_postFinish(self);
    }
    return result;
}

static id axs_notchhome_hookInterrupt(id self, SEL _cmd) {
    if (sAxsNotchHomeEnabled) {
        axs_notchhome_preFinish(self);
    }
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotInterrupt);
    id result = orig ? ((id (*)(id, SEL))orig)(self, _cmd) : nil;
    if (sAxsNotchHomeEnabled) {
        axs_notchhome_postFinish(self);
    }
    return result;
}

static CGRect axs_notchhome_hookFrame(id self, SEL _cmd, NSUInteger index) {
    axs_notchhome_diagFrameCalls++;
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotFrame);
    CGRect original = orig ? ((CGRect (*)(id, SEL, NSUInteger))orig)(self, _cmd, index) : CGRectZero;
    AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, NO);
    if (sStLogFrames < 3) {
        sStLogFrames++;
        axs_notchhome_diagLogF("stlog frame self=%p idx=%lu active=%d cache=%lld zoom=%d", self,
            (unsigned long)index, axs_notchhome_stateActive(state) ? 1 : 0,
            state ? (long long)state.startedAtHomeCache : -9,
            axs_notchhome_isZoomIndex(self, index) ? 1 : 0);
    }
    if (!axs_notchhome_stateActive(state)) {
        return original;
    }
    axs_notchhome_diagFrameActive++;
    if (!state.cachedBoundsValid || !axs_notchhome_isZoomIndex(self, index)) {
        return original;
    }
    static NSUInteger notchLogs = 0;
    if (notchLogs < 20) {
        notchLogs++;
        axs_notchhome_diagLogF("notch idx=%lu from=(%.0f,%.0f,%.0f,%.0f)",
            (unsigned long)index,
            CGRectGetMinX(original), CGRectGetMinY(original),
            CGRectGetWidth(original), CGRectGetHeight(original));
    }
    axs_notchhome_diagIconOK++;
    CGFloat w = CGRectGetWidth(state.cachedBounds);
    CGFloat h = CGRectGetHeight(state.cachedBounds);
    return CGRectMake(w / 2.0 - w / 2.0, kAxsNotchHomeNotchCenterY - h / 2.0, w, h);
}

static double axs_notchhome_hookScale(id self, SEL _cmd, NSUInteger index) {
    axs_notchhome_diagScaleCalls++;
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotScale);
    double original = orig ? ((double (*)(id, SEL, NSUInteger))orig)(self, _cmd, index) : 1.0;
    AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, NO);
    if (state && index == 0) {
        state.lastOrigScale0 = original;
    } else if (state && index == 1) {
        state.lastOrigScale1 = original;
    }
    if (!axs_notchhome_stateActive(state)) {
        return original;
    }
    if (!axs_notchhome_isZoomIndex(self, index)) {
        return original;
    }
    return kAxsNotchHomeNotchScale;
}

static AxsNotchHomeCornerRadii axs_notchhome_hookCorner(id self, SEL _cmd, NSUInteger index) {
    axs_notchhome_diagCornerCalls++;
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotCorner);
    AxsNotchHomeCornerRadii original = {0, 0, 0, 0};
    if (orig) {
        original = ((AxsNotchHomeCornerRadii (*)(id, SEL, NSUInteger))orig)(self, _cmd, index);
    }
    AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, NO);
    if (!axs_notchhome_stateActive(state)) {
        return original;
    }
    if (!state.cachedBoundsValid || !axs_notchhome_isZoomIndex(self, index)) {
        return original;
    }
    double radius = CGRectGetWidth(state.cachedBounds) * kAxsNotchHomeNotchRadiusFactor;
    AxsNotchHomeCornerRadii radii = {radius, radius, radius, radius};
    return radii;
}

static BOOL axs_notchhome_writeSettings(id attributes, SEL settingsGetter,
                                        double damping, double response) {
    if (![attributes respondsToSelector:settingsGetter]) {
        return NO;
    }
    id settings = ((id (*)(id, SEL))objc_msgSend)(attributes, settingsGetter);
    if (!settings || ![settings respondsToSelector:@selector(setDampingRatio:)]) {
        return NO;
    }
    // SBFFluidBehaviorSettings supports copyWithZone: but NOT
    // mutableCopyWithZone: — asking it for a mutable copy throws, which
    // silently killed every write in the -16 and -23 builds. The
    // attributes object's own mutable copy already carries its own
    // settings instances, so write in place here.
    ((void (*)(id, SEL, double))objc_msgSend)(settings, @selector(setDampingRatio:), damping);
    if ([settings respondsToSelector:@selector(setResponse:)]) {
        ((void (*)(id, SEL, double))objc_msgSend)(settings, @selector(setResponse:), response);
    }
    // Verify by reading the response back.
    if ([settings respondsToSelector:@selector(response)]) {
        double readBack = ((double (*)(id, SEL))objc_msgSend)(settings, @selector(response));
        if (readBack > response - 0.001 && readBack < response + 0.001) {
            if (settingsGetter == @selector(layoutSettings)) {
                axs_notchhome_diagLayoutResp++;
            } else {
                axs_notchhome_diagAnimResp++;
            }
        }
    }
    return YES;
}

static id axs_notchhome_hookAnimationAttributes(id self, SEL _cmd, id element) {
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotAnimAttrs);
    id result = orig ? ((id (*)(id, SEL, id))orig)(self, _cmd, element) : nil;
    if (!sAxsNotchHomeEnabled || !result || !sAxsNotchHomeTransitionActive || !element) {
        return result;
    }
    // Only SBAppLayout elements carry fluid settings in this flow; the
    // original leaves the accessory elements' attributes untouched.
    const char *elemClass = object_getClassName(element);
    if (!elemClass || strcmp(elemClass, "SBAppLayout") != 0 || !sAxsNotchHomeCurrentLayout) {
        return result;
    }
    axs_notchhome_diagAnimCalls++;
    // Every private call is guarded and no exception may escape (the
    // first build crashed SpringBoard here on iOS 15.4).
    @try {
        id copy = [result mutableCopy];
        if (!copy) {
            return result;
        }
        BOOL isZoomLayout = (element == sAxsNotchHomeCurrentLayout);
        double posDamping = isZoomLayout ? kAxsNotchHomeZoomPosDamping : kAxsNotchHomeOtherPosDamping;
        double posResponse = isZoomLayout ? kAxsNotchHomeZoomPosResponse : kAxsNotchHomeOtherPosResponse;
        double scaleDamping = isZoomLayout ? kAxsNotchHomeZoomScaleDamping : kAxsNotchHomeOtherScaleDamping;
        double scaleResponse = isZoomLayout ? kAxsNotchHomeZoomScaleResponse : kAxsNotchHomeOtherScaleResponse;
        BOOL wrotePosition = axs_notchhome_writeSettings(copy, @selector(positionSettings),
                                                         posDamping, posResponse);
        BOOL wroteScale = axs_notchhome_writeSettings(copy, @selector(scaleSettings),
                                                      scaleDamping, scaleResponse);
        // Measured from the original (wrap8): it also fixes the layout
        // settings at damping 1.100 / response 0.433 for BOTH elements,
        // where stock computes jittered values per gesture.
        axs_notchhome_writeSettings(copy, @selector(layoutSettings), 1.100, 0.433);
        if (!wrotePosition && !wroteScale) {
            axs_notchhome_diagAnimSkip++;
            return result;
        }
        return copy;
    } @catch (NSException *exception) {
        return result;
    }
}


static void axs_notchhome_diagDumpClass(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        axs_notchhome_diagLogF("dump %s: class-missing", className.UTF8String);
        return;
    }
    unsigned count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    axs_notchhome_diagLogF("dump %s: %u methods (filtered)", className.UTF8String, count);
    for (unsigned i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        NSString *lower = [name lowercaseString];
        if ([lower containsString:@"icon"] || [lower containsString:@"frame"] ||
            [lower containsString:@"radius"] || [lower containsString:@"radii"] ||
            [lower containsString:@"zoom"] || [lower containsString:@"home"] ||
            [lower containsString:@"match"] || [lower containsString:@"corner"] ||
            [lower containsString:@"layout"]) {
            const char *types = method_getTypeEncoding(methods[i]);
            axs_notchhome_diagLogF("  %s %s", name.UTF8String, types ? types : "?");
        }
    }
    free(methods);
}

#pragma mark - Installation

static AxsNotchHomeHookSlot *axs_notchhome_slot(AxsNotchHomeHookSlot *__strong *slot,
                                              NSString *className, NSString *selectorName) {
    if (!*slot) {
        *slot = [AxsNotchHomeHookSlot axs_notchhome_slotWithClassName:className selectorName:selectorName];
    }
    return *slot;
}

static void axs_notchhome_installAll(void) {
    NSString *modifier = kAxsNotchHomeModifierClass;
    static BOOL dumped = NO;
    if (!dumped) {
        dumped = YES;
        axs_notchhome_diagDumpClass(kAxsNotchHomeModifierClass);
        axs_notchhome_diagDumpClass(@"SBTransitionSwitcherModifier");
        axs_notchhome_diagDumpClass(kAxsNotchHomeGestureModifierClass);
    }

    axs_notchhome_slot(&sAxsNotchHomeSlotIsHome, modifier, @"_isEffectivelyHome");
    [sAxsNotchHomeSlotIsHome axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookIsEffectivelyHome
                                                       returnType:"B" argumentTypes:@[]];

    axs_notchhome_slot(&sAxsNotchHomeSlotWillBegin, modifier, @"transitionWillBegin");
    [sAxsNotchHomeSlotWillBegin axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookTransitionWillBegin
                                                          returnType:"@" argumentTypes:@[]];

    axs_notchhome_slot(&sAxsNotchHomeSlotDidEnd, modifier, @"transitionDidEnd");
    [sAxsNotchHomeSlotDidEnd axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookTransitionDidEnd
                                                        returnType:"@" argumentTypes:@[]];

    axs_notchhome_slot(&sAxsNotchHomeSlotInterrupt, modifier, @"interruptAndEndTransition");
    [sAxsNotchHomeSlotInterrupt axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookInterrupt
                                                          returnType:"@" argumentTypes:@[]];

    // Index arguments are NSUInteger ("Q"); fall back to "I" like the
    // original's strict check would reject, for cross-version tolerance.
    axs_notchhome_slot(&sAxsNotchHomeSlotFrame, modifier, @"frameForIndex:");
    if (![sAxsNotchHomeSlotFrame axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookFrame
                                                           returnType:kAxsNotchHomeCGRectEncoding
                                                        argumentTypes:@[@"Q"]]) {
        [sAxsNotchHomeSlotFrame axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookFrame
                                                          returnType:kAxsNotchHomeCGRectEncoding
                                                       argumentTypes:@[@"I"]];
    }

    axs_notchhome_slot(&sAxsNotchHomeSlotScale, modifier, @"scaleForIndex:");
    if (![sAxsNotchHomeSlotScale axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookScale
                                                           returnType:"d" argumentTypes:@[@"Q"]]) {
        [sAxsNotchHomeSlotScale axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookScale
                                                          returnType:"d" argumentTypes:@[@"I"]];
    }

    axs_notchhome_slot(&sAxsNotchHomeSlotCorner, modifier, @"cornerRadiiForIndex:");
    if (![sAxsNotchHomeSlotCorner axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookCorner
                                                            returnType:kAxsNotchHomeRadiiEncoding
                                                         argumentTypes:@[@"Q"]]) {
        [sAxsNotchHomeSlotCorner axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookCorner
                                                           returnType:kAxsNotchHomeRadiiEncoding
                                                        argumentTypes:@[@"I"]];
    }

    // The audit could not statically pin shouldMatchMoveToIconView to one
    // class; try the modifier first, then the fluid switcher controller.
    axs_notchhome_slot(&sAxsNotchHomeSlotAnimAttrs, kAxsNotchHomeGestureModifierClass,
                     @"animationAttributesForLayoutElement:");
    [sAxsNotchHomeSlotAnimAttrs axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookAnimationAttributes
                                                          returnType:"@" argumentTypes:@[@"@"]];

    if (!sAxsNotchHomeZoomCheckIMP) {
        sAxsNotchHomeZoomCheckIMP = axs_notchhome_lookupIMP(modifier, @"_isIndexZoomAppLayout:",
                                                            "B", @[@"Q"]);
    }
    axs_notchhome_diagLogF("lookups: zoomCheckIMP=%p", (void *)sAxsNotchHomeZoomCheckIMP);
}

%ctor {
    @autoreleasepool {
        if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
            return;
        }
        sAxsNotchHomeEnabled = axs_notchhome_computeEnabled();
        axs_notchhome_diagLogF("=== load: machine=%s sentinel=%d enabled=%d",
            axs_notchhome_machineName().UTF8String,
            (int)axs_notchhome_sentinelExists(), (int)sAxsNotchHomeEnabled);
        dispatch_async(dispatch_get_main_queue(), ^{
            axs_notchhome_installAll();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            axs_notchhome_installAll();
        });
    }
}
