#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AxsNotchHomeConfig.h"
#import "AxsNotchHomePrivate.h"
#import "AxsNotchHomeHookSlot.h"
#import "AxsNotchHomeState.h"

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

// Direct (non-hooked) lookups, mirroring the original's helper at 0x8430.
static IMP sAxsNotchHomeIconFrameIMP = NULL;
static NSInteger sAxsNotchHomeIconFrameForm = 0; // 0 none, 1 no-arg, 2 index-arg
static IMP sAxsNotchHomeIconRadiusIMP = NULL;
static NSInteger sAxsNotchHomeIconRadiusForm = 0; // 0 none, 1 double, 2 radii struct

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

static CGRect axs_notchhome_iconFrame(id modifier, NSUInteger index, BOOL *valid) {
    *valid = NO;
    if (!sAxsNotchHomeIconFrameIMP) {
        return CGRectZero;
    }
    CGRect frame = CGRectZero;
    if (sAxsNotchHomeIconFrameForm == 1) {
        frame = ((CGRect (*)(id, SEL))sAxsNotchHomeIconFrameIMP)(
            modifier, NSSelectorFromString(@"_homeScreenIconFrame"));
    } else if (sAxsNotchHomeIconFrameForm == 2) {
        frame = ((CGRect (*)(id, SEL, NSUInteger))sAxsNotchHomeIconFrameIMP)(
            modifier, NSSelectorFromString(@"_homeScreenIconFrame"), index);
    }
    if (CGRectGetWidth(frame) > 0 && CGRectGetHeight(frame) > 0 &&
        isfinite(CGRectGetWidth(frame)) && isfinite(CGRectGetHeight(frame))) {
        *valid = YES;
    }
    return frame;
}

static double axs_notchhome_iconRadius(id modifier, BOOL *valid) {
    *valid = NO;
    if (!sAxsNotchHomeIconRadiusIMP) {
        return 0;
    }
    if (sAxsNotchHomeIconRadiusForm == 1) {
        double radius = ((double (*)(id, SEL))sAxsNotchHomeIconRadiusIMP)(
            modifier, NSSelectorFromString(@"_homeScreenIconCornerRadius"));
        if (radius > 0 && isfinite(radius)) {
            *valid = YES;
            return radius;
        }
    } else if (sAxsNotchHomeIconRadiusForm == 2) {
        AxsNotchHomeCornerRadii radii = ((AxsNotchHomeCornerRadii (*)(id, SEL))sAxsNotchHomeIconRadiusIMP)(
            modifier, NSSelectorFromString(@"_homeScreenIconCornerRadius"));
        if (radii.topLeft > 0 && isfinite(radii.topLeft)) {
            *valid = YES;
            return radii.topLeft;
        }
    }
    return 0;
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
    if (sAxsNotchHomeEnabled && [NSThread isMainThread]) {
        @try {
            AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, YES);
            axs_notchhome_captureBegin(self, state);
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
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotFrame);
    CGRect original = orig ? ((CGRect (*)(id, SEL, NSUInteger))orig)(self, _cmd, index) : CGRectZero;
    AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, NO);
    if (!axs_notchhome_stateActive(state)) {
        return original;
    }
    BOOL valid = NO;
    CGRect icon = axs_notchhome_iconFrame(self, index, &valid);
    return valid ? icon : original;
}

static double axs_notchhome_hookScale(id self, SEL _cmd, NSUInteger index) {
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotScale);
    double original = orig ? ((double (*)(id, SEL, NSUInteger))orig)(self, _cmd, index) : 1.0;
    AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, NO);
    if (!axs_notchhome_stateActive(state) || !state.cachedBoundsValid) {
        return original;
    }
    BOOL valid = NO;
    CGRect icon = axs_notchhome_iconFrame(self, index, &valid);
    if (!valid) {
        return original;
    }
    double scale = CGRectGetWidth(icon) / CGRectGetWidth(state.cachedBounds);
    return (scale > 0.0 && scale <= 1.0) ? scale : original;
}

static AxsNotchHomeCornerRadii axs_notchhome_hookCorner(id self, SEL _cmd, NSUInteger index) {
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotCorner);
    AxsNotchHomeCornerRadii original = {0, 0, 0, 0};
    if (orig) {
        original = ((AxsNotchHomeCornerRadii (*)(id, SEL, NSUInteger))orig)(self, _cmd, index);
    }
    AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, NO);
    if (!axs_notchhome_stateActive(state)) {
        return original;
    }
    BOOL valid = NO;
    double radius = axs_notchhome_iconRadius(self, &valid);
    if (!valid) {
        return original;
    }
    AxsNotchHomeCornerRadii radii = {radius, radius, radius, radius};
    return radii;
}

static BOOL axs_notchhome_hookShouldMatchMove(id self, SEL _cmd) {
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
    // On iOS 15.4 the real attributes object does not necessarily respond
    // to the settings accessors the original binary referenced; the first
    // build crashed SpringBoard with an unrecognized-selector exception
    // here. Every private call is guarded, and no exception may escape.
    @try {
        SBSwitcherAnimationAttributes *attributes = (SBSwitcherAnimationAttributes *)result;
        if (![attributes respondsToSelector:@selector(positionSettings)] ||
            ![attributes respondsToSelector:@selector(scaleSettings)]) {
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

    // Direct lookups for the home-screen icon geometry (not hooked).
    if (!sAxsNotchHomeIconFrameIMP) {
        sAxsNotchHomeIconFrameIMP = axs_notchhome_lookupIMP(modifier, @"_homeScreenIconFrame",
                                                            kAxsNotchHomeCGRectEncoding, @[]);
        if (sAxsNotchHomeIconFrameIMP) {
            sAxsNotchHomeIconFrameForm = 1;
        } else {
            sAxsNotchHomeIconFrameIMP = axs_notchhome_lookupIMP(modifier, @"_homeScreenIconFrame",
                                                                kAxsNotchHomeCGRectEncoding, @[@"Q"]);
            if (sAxsNotchHomeIconFrameIMP) {
                sAxsNotchHomeIconFrameForm = 2;
            }
        }
    }
    if (!sAxsNotchHomeIconRadiusIMP) {
        sAxsNotchHomeIconRadiusIMP = axs_notchhome_lookupIMP(modifier, @"_homeScreenIconCornerRadius",
                                                             "d", @[]);
        if (sAxsNotchHomeIconRadiusIMP) {
            sAxsNotchHomeIconRadiusForm = 1;
        } else {
            sAxsNotchHomeIconRadiusIMP = axs_notchhome_lookupIMP(modifier, @"_homeScreenIconCornerRadius",
                                                                 kAxsNotchHomeRadiiEncoding, @[]);
            if (sAxsNotchHomeIconRadiusIMP) {
                sAxsNotchHomeIconRadiusForm = 2;
            }
        }
    }
}

%ctor {
    @autoreleasepool {
        if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
            return;
        }
        sAxsNotchHomeEnabled = axs_notchhome_computeEnabled();
        dispatch_async(dispatch_get_main_queue(), ^{
            axs_notchhome_installAll();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            axs_notchhome_installAll();
        });
    }
}
