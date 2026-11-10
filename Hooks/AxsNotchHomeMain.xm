#import <UIKit/UIKit.h>
#import <objc/runtime.h>
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
static const double kAxsNotchHomePositionDamping = 1.28;
static const double kAxsNotchHomeScaleDamping = 0.97;

// Notch suction target. Device pair data (2026-11-10) proved the stock
// zoom keeps the layout frame's size and moves its CENTER to the icon
// center while scaleForIndex: carries the shrink (428-wide frame,
// center = icon center, scale 0.150 = 64/428). Redirecting the zoom to
// the notch therefore means: same frame size, center moved to the
// notch center, and scale set so the window ends notch-wide.
static const double kAxsNotchHomeNotchCenterY = 20.0;
static const double kAxsNotchHomeNotchWidth = 170.0;
static const double kAxsNotchHomeNotchRadius = 40.0;

static BOOL sAxsNotchHomeEnabled = NO;

static AxsNotchHomeHookSlot *sAxsNotchHomeSlotIsHome;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotWillBegin;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotDidEnd;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotInterrupt;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotFrame;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotScale;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotCorner;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotMatchMove;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotAnimAttrs;

// Direct (non-hooked) lookup, mirroring the original's helper at 0x8430:
// which layout index is the app being zoomed (others keep stock values).
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

static CGRect axs_notchhome_notchTargetFrame(CGRect original, AxsNotchHomeZoomState *state) {
    CGFloat boundsWidth = state.cachedBoundsValid ? CGRectGetWidth(state.cachedBounds)
                                                  : CGRectGetWidth(original);
    CGPoint center = CGPointMake(boundsWidth / 2.0, (CGFloat)kAxsNotchHomeNotchCenterY);
    return CGRectMake(center.x - CGRectGetWidth(original) / 2.0,
                      center.y - CGRectGetHeight(original) / 2.0,
                      CGRectGetWidth(original), CGRectGetHeight(original));
}

#pragma mark - Hook implementations

static BOOL axs_notchhome_hookIsEffectivelyHome(id self, SEL _cmd) {
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotIsHome);
    BOOL result = orig ? ((BOOL (*)(id, SEL))orig)(self, _cmd) : NO;
    // The original only synchronizes its state cache here; it never
    // changes the return value.
    if ([NSThread isMainThread]) {
        AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, NO);
        if (state && state.effectivelyHomeCache == 2) {
            state.effectivelyHomeCache = result ? 1 : 0;
        }
    }
    return result;
}

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
}

static id axs_notchhome_hookTransitionWillBegin(id self, SEL _cmd) {
    axs_notchhome_diagWillBegin++;
    if (sAxsNotchHomeEnabled && [NSThread isMainThread]) {
        @try {
            AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, YES);
            axs_notchhome_captureBegin(self, state);
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
    axs_notchhome_diagLogF("transition end: willBegin=%lu didEnd=%lu frame=%lu frameActive=%lu iconOK=%lu scale=%lu corner=%lu match=%lu anim=%lu animSkip=%lu lastStartedAtHome=%ld boundsOK=%ld",
        (unsigned long)axs_notchhome_diagWillBegin, (unsigned long)axs_notchhome_diagDidEnd,
        (unsigned long)axs_notchhome_diagFrameCalls, (unsigned long)axs_notchhome_diagFrameActive,
        (unsigned long)axs_notchhome_diagIconOK, (unsigned long)axs_notchhome_diagScaleCalls,
        (unsigned long)axs_notchhome_diagCornerCalls, (unsigned long)axs_notchhome_diagMatchCalls,
        (unsigned long)axs_notchhome_diagAnimCalls, (unsigned long)axs_notchhome_diagAnimSkip,
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
    if (!axs_notchhome_stateActive(state)) {
        return original;
    }
    axs_notchhome_diagFrameActive++;
    if (!axs_notchhome_isZoomIndex(self, index)) {
        return original;
    }
    static NSUInteger notchLogs = 0;
    if (notchLogs < 20) {
        notchLogs++;
        axs_notchhome_diagLogF("notch idx=%lu from=(%.0f,%.0f,%.0f,%.0f) center->(%.0f,%.0f)",
            (unsigned long)index,
            CGRectGetMinX(original), CGRectGetMinY(original),
            CGRectGetWidth(original), CGRectGetHeight(original),
            (state.cachedBoundsValid ? CGRectGetWidth(state.cachedBounds) : CGRectGetWidth(original)) / 2.0,
            kAxsNotchHomeNotchCenterY);
    }
    axs_notchhome_diagIconOK++;
    return axs_notchhome_notchTargetFrame(original, state);
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
    if (!axs_notchhome_stateActive(state) || !state.cachedBoundsValid) {
        return original;
    }
    if (!axs_notchhome_isZoomIndex(self, index)) {
        return original;
    }
    double scale = kAxsNotchHomeNotchWidth / CGRectGetWidth(state.cachedBounds);
    return (scale > 0.0 && scale <= 1.0) ? scale : original;
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
    if (!axs_notchhome_isZoomIndex(self, index)) {
        return original;
    }
    AxsNotchHomeCornerRadii radii = {kAxsNotchHomeNotchRadius, kAxsNotchHomeNotchRadius,
                                     kAxsNotchHomeNotchRadius, kAxsNotchHomeNotchRadius};
    return radii;
}

static BOOL axs_notchhome_hookShouldMatchMove(id self, SEL _cmd) {
    axs_notchhome_diagMatchCalls++;
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotMatchMove);
    BOOL original = orig ? ((BOOL (*)(id, SEL))orig)(self, _cmd) : NO;
    AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, NO);
    if (axs_notchhome_stateActive(state)) {
        return YES;
    }
    return original;
}

static id axs_notchhome_hookAnimationAttributes(id self, SEL _cmd, id element) {
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotAnimAttrs);
    id result = orig ? ((id (*)(id, SEL, id))orig)(self, _cmd, element) : nil;
    if (!sAxsNotchHomeEnabled || !result) {
        return result;
    }
    axs_notchhome_diagAnimCalls++;
    // On iOS 15.4 the real attributes object does not necessarily respond
    // to the settings accessors the original binary referenced; the first
    // build crashed SpringBoard with an unrecognized-selector exception
    // here. Every private call is guarded, and no exception may escape.
    @try {
        SBSwitcherAnimationAttributes *attributes = (SBSwitcherAnimationAttributes *)result;
        if (![attributes respondsToSelector:@selector(positionSettings)] ||
            ![attributes respondsToSelector:@selector(scaleSettings)]) {
            axs_notchhome_diagAnimSkip++;
            return result;
        }
        SBSwitcherAnimationAttributes *copy = [attributes mutableCopy];
        if (!copy) {
            return result;
        }
        SBFFluidBehaviorSettings *position = [copy positionSettings];
        if (position && [position respondsToSelector:@selector(setDampingRatio:)] &&
            [copy respondsToSelector:@selector(setPositionSettings:)]) {
            SBFFluidBehaviorSettings *positionCopy = [position mutableCopy];
            if (positionCopy) {
                [positionCopy setDampingRatio:kAxsNotchHomePositionDamping];
                [copy setPositionSettings:positionCopy];
            }
        }
        SBFFluidBehaviorSettings *scale = [copy scaleSettings];
        if (scale && [scale respondsToSelector:@selector(setDampingRatio:)] &&
            [copy respondsToSelector:@selector(setScaleSettings:)]) {
            SBFFluidBehaviorSettings *scaleCopy = [scale mutableCopy];
            if (scaleCopy) {
                [scaleCopy setDampingRatio:kAxsNotchHomeScaleDamping];
                [copy setScaleSettings:scaleCopy];
            }
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
    axs_notchhome_slot(&sAxsNotchHomeSlotMatchMove, modifier, @"shouldMatchMoveToIconView");
    if (![sAxsNotchHomeSlotMatchMove axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookShouldMatchMove
                                                               returnType:"B" argumentTypes:@[]]) {
        static AxsNotchHomeHookSlot *fluidSlot;
        axs_notchhome_slot(&fluidSlot, kAxsNotchHomeFluidVCClass, @"shouldMatchMoveToIconView");
        if ([fluidSlot axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookShouldMatchMove
                                                 returnType:"B" argumentTypes:@[]]) {
            sAxsNotchHomeSlotMatchMove = fluidSlot;
        }
    }

    axs_notchhome_slot(&sAxsNotchHomeSlotAnimAttrs, kAxsNotchHomeGestureModifierClass,
                     @"animationAttributesForLayoutElement:");
    [sAxsNotchHomeSlotAnimAttrs axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookAnimationAttributes
                                                          returnType:"@" argumentTypes:@[@"@"]];

    // Direct lookup for the zoom-index check (not hooked).
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
