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
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotOpacityIndex;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotOpacityRole;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotAnimAttrsT;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotAnimAttrsZ;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotHomeAlpha;




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

// Per-transition summary trackers: the values that matter (animation
// settings for the app layout, opacity, home-screen alpha dip) are folded
// into one "sum" line per transition so they survive any log truncation.
static double sSumAttrsG[4] = {-1, -1, -1, -1};
static BOOL sSumAttrsGValid = NO;
static double sSumAttrsT[4] = {-1, -1, -1, -1};
static BOOL sSumAttrsTValid = NO;
static double sSumOpR[2] = {-1, -1};
static double sSumHsMin = 1.0;
static BOOL sSumHsSeen = NO;

static void axs_notchhome_postFinish(id self) {
    axs_notchhome_diagDidEnd++;
    axs_notchhome_diagLogF("sum aG{%.3f %.3f %.3f %.3f} aT{%.3f %.3f %.3f %.3f} opR{%.2f %.2f} hsMin=%.3f",
        sSumAttrsG[0], sSumAttrsG[1], sSumAttrsG[2], sSumAttrsG[3],
        sSumAttrsT[0], sSumAttrsT[1], sSumAttrsT[2], sSumAttrsT[3],
        sSumOpR[0], sSumOpR[1], sSumHsSeen ? sSumHsMin : -1.0);
    sSumAttrsGValid = NO; sSumAttrsTValid = NO;
    sSumAttrsG[0] = sSumAttrsG[1] = sSumAttrsG[2] = sSumAttrsG[3] = -1;
    sSumAttrsT[0] = sSumAttrsT[1] = sSumAttrsT[2] = sSumAttrsT[3] = -1;
    sSumOpR[0] = sSumOpR[1] = -1;
    sSumHsMin = 1.0; sSumHsSeen = NO;
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
    if (axs_notchhome_stateActive(state)) {
        axs_notchhome_diagFrameActive++;
    }
    return original;
}

static double axs_notchhome_hookScale(id self, SEL _cmd, NSUInteger index) {
    axs_notchhome_diagScaleCalls++;
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotScale);
    double original = orig ? ((double (*)(id, SEL, NSUInteger))orig)(self, _cmd, index) : 1.0;
    return original;
}

static AxsNotchHomeCornerRadii axs_notchhome_hookCorner(id self, SEL _cmd, NSUInteger index) {
    axs_notchhome_diagCornerCalls++;
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotCorner);
    AxsNotchHomeCornerRadii original = {0, 0, 0, 0};
    if (orig) {
        original = ((AxsNotchHomeCornerRadii (*)(id, SEL, NSUInteger))orig)(self, _cmd, index);
    }
    return original;
}

static double axs_notchhome_hookOpacityIndex(id self, SEL _cmd, NSUInteger index) {
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotOpacityIndex);
    double original = orig ? ((double (*)(id, SEL, NSUInteger))orig)(self, _cmd, index) : 1.0;
    AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, NO);
    if (axs_notchhome_stateActive(state)) {
        static NSUInteger samples = 0;
        if (samples < 80) {
            samples++;
            axs_notchhome_diagLogF("op idx=%lu -> %.3f", (unsigned long)index, original);
        }
    }
    return original;
}

static double axs_notchhome_hookOpacityRole(id self, SEL _cmd, long long role, id appLayout, NSUInteger index) {
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotOpacityRole);
    double original = orig ? ((double (*)(id, SEL, long long, id, NSUInteger))orig)(self, _cmd, role, appLayout, index) : 1.0;
    if (role == 1 && index < 2) {
        sSumOpR[index] = original;
    }
    AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, NO);
    if (axs_notchhome_stateActive(state)) {
        static NSUInteger samples = 0;
        if (samples < 80) {
            samples++;
            axs_notchhome_diagLogF("opR role=%lld idx=%lu -> %.3f", role, (unsigned long)index, original);
        }
    }
    return original;
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

static double axs_notchhome_probeDouble(id object, SEL selector) {
    if (object && [object respondsToSelector:selector]) {
        @try {
            return ((double (*)(id, SEL))objc_msgSend)(object, selector);
        } @catch (NSException *exception) {
            return NAN;
        }
    }
    return NAN;
}

static long long axs_notchhome_probeInt(id object, SEL selector) {
    if (object && [object respondsToSelector:selector]) {
        @try {
            return ((long long (*)(id, SEL))objc_msgSend)(object, selector);
        } @catch (NSException *exception) {
            return -999;
        }
    }
    return -999;
}

static void axs_notchhome_logAttrs(const char *tag, id attributes, id element) {
    if (!attributes) {
        return;
    }
    @try {
        id position = [attributes respondsToSelector:@selector(positionSettings)] ? [attributes positionSettings] : nil;
        id scale = [attributes respondsToSelector:@selector(scaleSettings)] ? [attributes scaleSettings] : nil;
        const char *elemClass = element ? object_getClassName(element) : "?";
        double pd = axs_notchhome_probeDouble(position, @selector(dampingRatio));
        double pr = axs_notchhome_probeDouble(position, @selector(response));
        double sd = axs_notchhome_probeDouble(scale, @selector(dampingRatio));
        double sr = axs_notchhome_probeDouble(scale, @selector(response));
        if (elemClass && strcmp(elemClass, "SBAppLayout") == 0 && !isnan(pd)) {
            double *dst = NULL;
            if (strcmp(tag, "attrsG") == 0) { dst = sSumAttrsG; sSumAttrsGValid = YES; }
            if (strcmp(tag, "attrsT") == 0) { dst = sSumAttrsT; sSumAttrsTValid = YES; }
            if (dst) { dst[0] = pd; dst[1] = pr; dst[2] = sd; dst[3] = sr; }
        }
        static NSUInteger samples = 0;
        if (samples < 120) {
            samples++;
            axs_notchhome_diagLogF("%s elem=%s pos{damp=%.3f resp=%.3f} scale{damp=%.3f resp=%.3f} pMode=%lld sMode=%lld",
                tag, elemClass, pd, pr, sd, sr,
                axs_notchhome_probeInt(attributes, @selector(positionUpdateMode)),
                axs_notchhome_probeInt(attributes, @selector(scaleUpdateMode)));
        }
    } @catch (NSException *exception) {
        axs_notchhome_diagLogF("%s probe failed", tag);
    }
}

static id axs_notchhome_hookAnimationAttributes(id self, SEL _cmd, id element) {
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotAnimAttrs);
    id result = orig ? ((id (*)(id, SEL, id))orig)(self, _cmd, element) : nil;
    if (sAxsNotchHomeEnabled && result) {
        axs_notchhome_diagAnimCalls++;
        axs_notchhome_logAttrs("attrsG", result, element);
    }
    return result;
}

static id axs_notchhome_hookAnimationAttributesT(id self, SEL _cmd, id element) {
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotAnimAttrsT);
    id result = orig ? ((id (*)(id, SEL, id))orig)(self, _cmd, element) : nil;
    if (sAxsNotchHomeEnabled && result) {
        axs_notchhome_logAttrs("attrsT", result, element);
    }
    return result;
}

static id axs_notchhome_hookAnimationAttributesZ(id self, SEL _cmd, id element) {
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotAnimAttrsZ);
    id result = orig ? ((id (*)(id, SEL, id))orig)(self, _cmd, element) : nil;
    if (sAxsNotchHomeEnabled && result) {
        axs_notchhome_logAttrs("attrsZ", result, element);
    }
    return result;
}

static double axs_notchhome_hookHomeScreenAlpha(id self, SEL _cmd) {
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotHomeAlpha);
    double original = orig ? ((double (*)(id, SEL))orig)(self, _cmd) : 1.0;
    if (!sSumHsSeen || original < sSumHsMin) {
        sSumHsMin = original;
        sSumHsSeen = YES;
    }
    AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, NO);
    if (axs_notchhome_stateActive(state)) {
        static NSUInteger samples = 0;
        if (samples < 60) {
            samples++;
            axs_notchhome_diagLogF("hsAlpha -> %.3f", original);
        }
    }
    return original;
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

    axs_notchhome_slot(&sAxsNotchHomeSlotOpacityIndex, modifier, @"opacityForIndex:");
    [sAxsNotchHomeSlotOpacityIndex axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookOpacityIndex
                                                            returnType:"d" argumentTypes:@[@"Q"]];
    axs_notchhome_slot(&sAxsNotchHomeSlotOpacityRole, modifier, @"opacityForLayoutRole:inAppLayout:atIndex:");
    [sAxsNotchHomeSlotOpacityRole axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookOpacityRole
                                                           returnType:"d" argumentTypes:@[@"q", @"@", @"Q"]];
    axs_notchhome_slot(&sAxsNotchHomeSlotAnimAttrsT, @"SBTransitionSwitcherModifier",
                       @"animationAttributesForLayoutElement:");
    [sAxsNotchHomeSlotAnimAttrsT axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookAnimationAttributesT
                                                           returnType:"@" argumentTypes:@[@"@"]];
    axs_notchhome_slot(&sAxsNotchHomeSlotAnimAttrsZ, modifier,
                       @"animationAttributesForLayoutElement:");
    [sAxsNotchHomeSlotAnimAttrsZ axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookAnimationAttributesZ
                                                           returnType:"@" argumentTypes:@[@"@"]];
    axs_notchhome_slot(&sAxsNotchHomeSlotHomeAlpha, modifier, @"homeScreenAlpha");
    [sAxsNotchHomeSlotHomeAlpha axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookHomeScreenAlpha
                                                          returnType:"d" argumentTypes:@[]];
    axs_notchhome_diagLogF("wrap4 build: per-transition summary lines");
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
