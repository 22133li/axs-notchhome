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
static IMP sAxsNotchHomeFullFrameIMP = NULL;
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

// The audited _homeScreenIconFrame does not exist anywhere in this
// class hierarchy on iOS 15.4 (device method dump, 2026-11-10). The
// modifier's own fullyPresentedFrameForIndex:frame: is the candidate
// source for the home-icon target frame; a result is only accepted
// when it is plausibly icon-sized, otherwise callers keep the
// original frame and the attempt is visible in the diagnostic log.
static CGRect axs_notchhome_candidateIconFrame(id modifier, NSUInteger index, CGRect seed, BOOL *valid) {
    *valid = NO;
    if (!sAxsNotchHomeFullFrameIMP) {
        return CGRectZero;
    }
    CGRect candidate = ((CGRect (*)(id, SEL, NSUInteger, CGRect))sAxsNotchHomeFullFrameIMP)(
        modifier, NSSelectorFromString(@"fullyPresentedFrameForIndex:frame:"), index, seed);
    CGFloat w = CGRectGetWidth(candidate);
    CGFloat h = CGRectGetHeight(candidate);
    if (w >= 30.0 && w <= 140.0 && h >= 30.0 && h <= 140.0 &&
        isfinite(w) && isfinite(h) && isfinite(CGRectGetMinX(candidate)) && isfinite(CGRectGetMinY(candidate))) {
        *valid = YES;
    }
    return candidate;
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
    BOOL valid = NO;
    CGRect icon = axs_notchhome_candidateIconFrame(self, index, original, &valid);
    static NSUInteger frameSamples = 0;
    if (frameSamples < 8) {
        frameSamples++;
        BOOL fsValid = NO;
        CGRect fsSeed = CGRectMake(0, 0, CGRectGetWidth(state.cachedBounds), CGRectGetHeight(state.cachedBounds));
        CGRect iconFS = axs_notchhome_candidateIconFrame(self, index, fsSeed, &fsValid);
        axs_notchhome_diagLogF("sample idx=%lu orig=(%.0f,%.0f,%.0f,%.0f) cand=(%.0f,%.0f,%.0f,%.0f) valid=%d candFS=(%.0f,%.0f,%.0f,%.0f) validFS=%d",
            (unsigned long)index,
            CGRectGetMinX(original), CGRectGetMinY(original), CGRectGetWidth(original), CGRectGetHeight(original),
            CGRectGetMinX(icon), CGRectGetMinY(icon), CGRectGetWidth(icon), CGRectGetHeight(icon), (int)valid,
            CGRectGetMinX(iconFS), CGRectGetMinY(iconFS), CGRectGetWidth(iconFS), CGRectGetHeight(iconFS), (int)fsValid);
    }
    if (valid) {
        axs_notchhome_diagIconOK++;
    }
    return valid ? icon : original;
}

static double axs_notchhome_hookScale(id self, SEL _cmd, NSUInteger index) {
    axs_notchhome_diagScaleCalls++;
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotScale);
    double original = orig ? ((double (*)(id, SEL, NSUInteger))orig)(self, _cmd, index) : 1.0;
    AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, NO);
    if (!axs_notchhome_stateActive(state) || !state.cachedBoundsValid) {
        return original;
    }
    BOOL valid = NO;
    CGRect seed = CGRectMake(0, 0, CGRectGetWidth(state.cachedBounds), CGRectGetHeight(state.cachedBounds));
    CGRect icon = axs_notchhome_candidateIconFrame(self, index, seed, &valid);
    if (!valid) {
        return original;
    }
    double scale = CGRectGetWidth(icon) / CGRectGetWidth(state.cachedBounds);
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
    BOOL valid = NO;
    double radius = axs_notchhome_iconRadius(self, &valid);
    if (!valid) {
        return original;
    }
    AxsNotchHomeCornerRadii radii = {radius, radius, radius, radius};
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

static void axs_notchhome_diagSlot(AxsNotchHomeHookSlot *slot) {
    if (!slot) {
        axs_notchhome_diagLogF("slot: (nil)");
        return;
    }
    const char *clsName = slot.className.UTF8String;
    const char *selName = slot.selectorName.UTF8String;
    Class cls = NSClassFromString(slot.className);
    if (!cls) {
        axs_notchhome_diagLogF("slot %s.%s installed=%d stage=class-missing", clsName, selName, (int)slot.installed);
        return;
    }
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(slot.selectorName));
    if (!method) {
        axs_notchhome_diagLogF("slot %s.%s installed=%d stage=method-missing", clsName, selName, (int)slot.installed);
        return;
    }
    char *returnType = method_copyReturnType(method);
    char args[256] = {0};
    unsigned argc = method_getNumberOfArguments(method);
    for (unsigned i = 2; i < argc && i < 10; i++) {
        char *argType = method_copyArgumentType(method, i);
        if (argType) {
            strncat(args, argType, sizeof(args) - strlen(args) - 2);
            strncat(args, ",", sizeof(args) - strlen(args) - 1);
            free(argType);
        }
    }
    axs_notchhome_diagLogF("slot %s.%s installed=%d types ret=%s args=%s argc=%u",
        clsName, selName, (int)slot.installed, returnType ? returnType : "?", args, argc);
    free(returnType);
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
    axs_notchhome_diagSlot(sAxsNotchHomeSlotIsHome);
    axs_notchhome_diagSlot(sAxsNotchHomeSlotWillBegin);
    axs_notchhome_diagSlot(sAxsNotchHomeSlotDidEnd);
    axs_notchhome_diagSlot(sAxsNotchHomeSlotInterrupt);
    axs_notchhome_diagSlot(sAxsNotchHomeSlotFrame);
    axs_notchhome_diagSlot(sAxsNotchHomeSlotScale);
    axs_notchhome_diagSlot(sAxsNotchHomeSlotCorner);
    axs_notchhome_diagSlot(sAxsNotchHomeSlotMatchMove);
    axs_notchhome_diagSlot(sAxsNotchHomeSlotAnimAttrs);
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
    if (!sAxsNotchHomeFullFrameIMP) {
        sAxsNotchHomeFullFrameIMP = axs_notchhome_lookupIMP(modifier, @"fullyPresentedFrameForIndex:frame:",
                                                            kAxsNotchHomeCGRectEncoding,
                                                            @[@"Q", @"{CGRect={CGPoint=dd}{CGSize=dd}}"]);
    }
    axs_notchhome_diagLogF("lookups: iconFrameForm=%ld iconRadiusForm=%ld fullFrameIMP=%p",
        (long)sAxsNotchHomeIconFrameForm, (long)sAxsNotchHomeIconRadiusForm, (void *)sAxsNotchHomeFullFrameIMP);
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
