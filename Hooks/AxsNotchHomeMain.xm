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
static id sAxsNotchHomeCurrentModifier = nil;

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
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotVCRspMatchMove;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotVCRspIconOverlay;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotVCRspIconView;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotVCActMatchMove;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotVCActIconOverlay;
static AxsNotchHomeHookSlot *sAxsNotchHomeSlotVCActIconView;

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

// Transcribed from the original's geometry workers (frame worker at
// 0x6ec4, scale/corner identical): the override applies only while
// began==1, ended==0, finishing!=1, mutationDepth<=0 (no recursion path
// exists in this implementation, so the depth check is vacuous), the
// tri-state first-sample field is resolved (!=2) and ==0, a LIVE call of
// the original _isEffectivelyHome at geometry time returns YES, and the
// index is the zoom index. The live-call and zoom checks live in the
// geometry hooks; this predicate carries the cached-field half.
// startedAtHomeCache here is that tri-state field: written ONLY by the
// _isEffectivelyHome replacement's backfill (first sample wins), never
// by the begin handler — disassembly shows exactly two writers of the
// field in the whole binary (state init -> 2, ih backfill).
// POLARITY CORRECTION (-40): -38/-39 implemented this gate with both
// booleans inverted, misreading `orn w9, w9, w0` at 0x70dc (ORN negates
// the SECOND source: F920 | ~liveIH, not ~F920 | liveIH). Re-verified
// instruction by instruction at 0x70cc-0x70e4 (frame), 0x73ec-0x73fc
// (scale) and 0xb90c-0xb91c (opacity, `bic w8, w22, w25` = liveIH &
// ~F920): continue iff firstSample==0 AND liveIH==YES AND isZoom==YES.
// On device this showed exactly as the user spotted in their video:
// the override fired on OPENING legs and stayed off on home legs.
static BOOL axs_notchhome_stateActive(AxsNotchHomeZoomState *state) {
    return sAxsNotchHomeEnabled && [NSThread isMainThread] && state &&
           state.began && !state.ended && !state.finishing &&
           state.startedAtHomeCache == 0;
}

// Live original _isEffectivelyHome, called through the saved IMP like
// the original's workers do (their calls bypass their own replacement,
// so this does not backfill the tri-state).
static BOOL axs_notchhome_liveIsEffectivelyHome(id self) {
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotIsHome);
    if (!orig) {
        return NO;
    }
    return ((BOOL (*)(id, SEL))orig)(self, NSSelectorFromString(@"_isEffectivelyHome"));
}

static BOOL axs_notchhome_isZoomIndex(id modifier, NSUInteger index) {
    if (sAxsNotchHomeZoomCheckIMP) {
        return ((BOOL (*)(id, SEL, NSUInteger))sAxsNotchHomeZoomCheckIMP)(
            modifier, NSSelectorFromString(@"_isIndexZoomAppLayout:"), index);
    }
    return index == 0;
}

// The index the notch override applies to. Parity fix (-39): the
// original's workers require _isIndexZoomAppLayout: == YES for the
// index, with no fallback (verified in the frame and scale workers'
// gate code). The foreground-index fallback added in -36 for legs with
// no zoom index was a deviation and is removed; measured folder,
// other-page and switcher legs all carry a zoom index, so the scope
// the user asked for is unaffected.
static BOOL axs_notchhome_isTargetIndex(id self, AxsNotchHomeZoomState *state, NSUInteger index) {
    (void)state;
    return axs_notchhome_isZoomIndex(self, index);
}

#pragma mark - Hook implementations

static BOOL axs_notchhome_hookIsEffectivelyHome(id self, SEL _cmd) {
    IMP orig = axs_notchhome_savedIMP(sAxsNotchHomeSlotIsHome);
    BOOL result = orig ? ((BOOL (*)(id, SEL))orig)(self, _cmd) : NO;
    if ([NSThread isMainThread]) {
        AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, sAxsNotchHomeEnabled);
        if (state && state.startedAtHomeCache == 2) {
            state.startedAtHomeCache = result ? 1 : 0;
        }
        // The audit's static read of the original (report section 8):
        // its _isEffectivelyHome replacement NEVER changes the return
        // value — it only backfills the tri-state cache field when it is
        // still unknown (== 2). The YES-forcing this hook did from -28
        // to -36 was an inference from wrap counts and is a deviation;
        // it also feeds the switcher view controller "home presented"
        // answers during legs where that is false, which can derail
        // its transition setup for the following home leg. Removed:
        // this hook now returns the original value, like the original.
        BOOL ret = result;
        // stlog2 (diagnostic only): record every flip of the stock
        // answer per instance, plus nil-state calls, so the switcher
        // sequence's capture timing can be read off the log.
        if (state) {
            if ((long long)(result ? 1 : 0) != state.ihLastLogged) {
                state.ihLastLogged = result ? 1 : 0;
                axs_notchhome_diagLogF("ihlog self=%p orig=%d cache=%lld ret=%d", self,
                    result ? 1 : 0, (long long)state.startedAtHomeCache, ret ? 1 : 0);
            }
        } else {
            static NSInteger sIhNilLast = -1;
            if ((long long)(result ? 1 : 0) != sIhNilLast) {
                sIhNilLast = result ? 1 : 0;
                axs_notchhome_diagLogF("ihlog self=%p orig=%d cache=-9 ret=%d", self,
                    result ? 1 : 0, ret ? 1 : 0);
            }
        }
        return ret;
    }
    return result;
}

static unsigned long sStLogFrames = 0;

static void axs_notchhome_captureBegin(id self, AxsNotchHomeZoomState *state) {
    // NOTE: unlike -37 and earlier, this no longer samples
    // _isEffectivelyHome into startedAtHomeCache. In the original that
    // field is written only by the state initializer (=2) and by the
    // _isEffectivelyHome replacement's first-sample backfill; the begin
    // pre-handler never touches it (verified in the disassembly: two
    // writers in the whole binary). Sampling at willBegin read the
    // signal half a phase late and with inverted results per direction,
    // which is what closed the gate on folder/switcher/other-page legs.
    state.began = YES;
    state.ended = NO;
    state.finishing = NO;
    state.notchCloseLatched = NO;
    UIWindow *window = axs_notchhome_findSwitcherWindow();
    state.targetWindow = window;
    CGRect bounds = window ? window.bounds : CGRectZero;
    state.cachedBounds = bounds;
    state.cachedBoundsValid = axs_notchhome_isPlausibleBounds(bounds);
    sStLogFrames = 0;
    state.ihLastLogged = -1;
    long long dirValue = -9;
    @try {
        id dirObj = [self valueForKey:@"direction"];
        if ([dirObj isKindOfClass:[NSNumber class]]) {
            dirValue = [dirObj longLongValue];
        }
    } @catch (NSException *exception) {
        dirValue = -8;
    }
    state.directionCache = dirValue;
    state.zoomIndexCache = -2;
    axs_notchhome_diagLogF("stlog begin self=%p started=%lld dir=%lld layout=%p", self,
        (long long)state.startedAtHomeCache, dirValue, state.appLayout);
}

static id axs_notchhome_hookTransitionWillBegin(id self, SEL _cmd) {
    axs_notchhome_diagWillBegin++;
    if (sAxsNotchHomeEnabled && [NSThread isMainThread]) {
        @try {
            AxsNotchHomeZoomState *state = axs_notchhome_stateForObject(self, YES);
            axs_notchhome_captureBegin(self, state);
            sAxsNotchHomeCurrentModifier = self;
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
        // sAxsNotchHomeCurrentModifier / sAxsNotchHomeCurrentLayout are
        // deliberately NOT cleared here: the view controller can still
        // deliver modifier actions while the end of the transition is
        // being processed, and the SBFluidSwitcherViewController action
        // hooks below qualify through this state's live flags (ended is
        // already YES by then for anything later). They are overwritten
        // at the next transitionWillBegin.
    }
}

static id axs_notchhome_hookTransitionDidEnd(id self, SEL _cmd) {
    if (sAxsNotchHomeEnabled) {
        axs_notchhome_diagLogF("stlog end self=%p", self);
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
    if (!axs_notchhome_liveIsEffectivelyHome(self)) {
        return original;
    }
    axs_notchhome_diagFrameActive++;
    if (!state.cachedBoundsValid || !axs_notchhome_isTargetIndex(self, state, index)) {
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
    state.notchCloseLatched = YES;
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
    if (!axs_notchhome_liveIsEffectivelyHome(self)) {
        return original;
    }
    if (!axs_notchhome_isTargetIndex(self, state, index)) {
        return original;
    }
    state.notchCloseLatched = YES;
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
    if (!axs_notchhome_liveIsEffectivelyHome(self)) {
        return original;
    }
    if (!state.cachedBoundsValid || !axs_notchhome_isTargetIndex(self, state, index)) {
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
    BOOL transitionActive = sAxsNotchHomeTransitionActive;
    if (!transitionActive && sAxsNotchHomeCurrentModifier) {
        // The tri-state first sample can land after willBegin (the
        // view controller's first _isEffectivelyHome query for the
        // instance may come later); re-evaluate against the live state
        // instead of trusting only the willBegin snapshot.
        transitionActive = axs_notchhome_stateActive(
            axs_notchhome_stateForObject(sAxsNotchHomeCurrentModifier, NO));
    }
    if (!sAxsNotchHomeEnabled || !result || !transitionActive || !element) {
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
        // Parity fix (-39): the layout settings group is NOT written.
        // The original's dylib contains no reference to layoutSettings
        // or layoutSettingsForTargetCenter: at all (no string, no
        // fragment); the constant layout values wrap8 measured in the
        // original's sessions are the view controller's own computation
        // downstream of the changed geometry (its target centers move
        // to the notch path), not a write. The direct write added in
        // -32 (1.100/0.433 for both elements) was a mechanism deviation
        // and is removed; with the geometry transcribed, the stock
        // computation produces the original's values on its own.
        if (!wrotePosition && !wroteScale) {
            axs_notchhome_diagAnimSkip++;
            return result;
        }
        return copy;
    } @catch (NSException *exception) {
        return result;
    }
}


// SBFluidSwitcherViewController modifier-response/action hooks,
// fully decoded from the original's registrar B (2026-11-11):
// SIX slot descriptors (initializers 0xbc4c-0xbf1c) form a 3x2 matrix
// on the class SBFluidSwitcherViewController — three response kinds,
// each in an iOS 15 "Response:" spelling and an iOS 16 "Action:"
// spelling:
//   _performModifierMatchMoveToIconView{Response,Action}:
//   _performModifierIconOverlayVisibilityUpdate{Response,Action}:
//   _performModifierIconViewVisibilityUpdate{Response,Action}:
// On iOS 15.4 only the Response: methods exist (verified in the
// device class dump); the Action: installs fail silently there in
// the original as well. Two worker families sit behind the thunks:
//   - MatchMove / IconOverlay (worker 0xd508, flag in the thunk):
//     if the response's BOOL ivar is 1, it is forced to 0 for the
//     duration of the original call and restored to 1 after.
//     Ivar: _active (MatchMove), _visible (IconOverlay).
//   - IconViewVisibility (worker 0xd1d0): INVERTED — if the _visible
//     ivar is 0, it is forced to 1 during the original call and
//     restored to 0 after, i.e. the icon view is kept visible.
// Both workers tail-call the original IMP untouched off the main
// thread or for a nil response, and qualify the flip through two
// static (String, String) whitelist membership tests (0xbfac) plus a
// live per-layout context lookup (0xafc4); the whitelist pair
// semantics are the one piece not fully decoded, and the latch below
// (this leg's geometry override applied for this layout) is the
// operational equivalent used here. If the ivar is absent or not in
// the state to flip, the call passes through untouched.
enum {
    kAxsNotchHomeVCFlipActiveDown = 0,
    kAxsNotchHomeVCFlipVisibleDown = 1,
    kAxsNotchHomeVCFlipVisibleUp = 2,
};

static void axs_notchhome_vcActionWorker(AxsNotchHomeHookSlot *slot, id self, SEL _cmd, id action, NSInteger kind) {
    IMP orig = axs_notchhome_savedIMP(slot);
    if (!orig) {
        return;
    }
    void (*callOrig)(id, SEL, id) = (void (*)(id, SEL, id))orig;
    if (!sAxsNotchHomeEnabled || ![NSThread isMainThread] || !action) {
        callOrig(self, _cmd, action);
        return;
    }
    static const char *kindNames[] = {"matchmove", "overlay", "iconview"};
    BOOL called = NO;
    @try {
        id actionLayout = nil;
        @try {
            actionLayout = [action valueForKey:@"appLayout"];
        } @catch (NSException *exception) {
            actionLayout = nil;
        }
        AxsNotchHomeZoomState *state = sAxsNotchHomeCurrentModifier
            ? axs_notchhome_stateForObject(sAxsNotchHomeCurrentModifier, NO) : nil;
        // Qualification: see the header comment. Responses generated
        // by transitionDidEnd are performed after the modifier chain
        // has finished, so the live flags no longer describe the leg;
        // the latch carries the fact that this leg's override applied.
        BOOL qualify = actionLayout && sAxsNotchHomeCurrentLayout &&
                       actionLayout == sAxsNotchHomeCurrentLayout &&
                       state && state.notchCloseLatched;
        static NSUInteger actionLogs = 0;
        if (actionLogs < 60) {
            actionLogs++;
            axs_notchhome_diagLogF("stlog vcaction seen %s layout=%p cur=%p latch=%d qualify=%d",
                kindNames[kind], actionLayout, sAxsNotchHomeCurrentLayout,
                state ? (int)state.notchCloseLatched : -1, (int)qualify);
        }
        if (!qualify) {
            called = YES;
            callOrig(self, _cmd, action);
            return;
        }
        const char *ivarName = (kind == kAxsNotchHomeVCFlipActiveDown) ? "_active" : "_visible";
        Ivar ivar = class_getInstanceVariable(object_getClass(action), ivarName);
        static NSUInteger flipLogs = 0;
        if (!ivar) {
            if (flipLogs < 20) {
                flipLogs++;
                axs_notchhome_diagLogF("stlog vcflip %s NO-IVAR %s on %s",
                    kindNames[kind], ivarName, class_getName(object_getClass(action)));
            }
            called = YES;
            callOrig(self, _cmd, action);
            return;
        }
        unsigned char *bytePtr = (unsigned char *)(__bridge void *)action + ivar_getOffset(ivar);
        if (flipLogs < 20) {
            flipLogs++;
            axs_notchhome_diagLogF("stlog vcflip %s ivar %s off=%td byte=%d",
                kindNames[kind], ivarName, ivar_getOffset(ivar), (int)*bytePtr);
        }
        if (kind == kAxsNotchHomeVCFlipVisibleUp) {
            if (*bytePtr != 0) {
                called = YES;
                callOrig(self, _cmd, action);
                return;
            }
            *bytePtr = 1;
            called = YES;
            callOrig(self, _cmd, action);
            *bytePtr = 0;
        } else {
            if (*bytePtr != 1) {
                called = YES;
                callOrig(self, _cmd, action);
                return;
            }
            *bytePtr = 0;
            called = YES;
            callOrig(self, _cmd, action);
            *bytePtr = 1;
        }
        axs_notchhome_diagLogF("stlog vcaction %s flipped for layout %p",
            kindNames[kind], actionLayout);
    } @catch (NSException *exception) {
        if (!called) {
            callOrig(self, _cmd, action);
        }
    }
}

static void axs_notchhome_hookVCRspMatchMove(id self, SEL _cmd, id action) {
    axs_notchhome_vcActionWorker(sAxsNotchHomeSlotVCRspMatchMove, self, _cmd, action, kAxsNotchHomeVCFlipActiveDown);
}
static void axs_notchhome_hookVCRspIconOverlay(id self, SEL _cmd, id action) {
    axs_notchhome_vcActionWorker(sAxsNotchHomeSlotVCRspIconOverlay, self, _cmd, action, kAxsNotchHomeVCFlipVisibleDown);
}
static void axs_notchhome_hookVCRspIconView(id self, SEL _cmd, id action) {
    axs_notchhome_vcActionWorker(sAxsNotchHomeSlotVCRspIconView, self, _cmd, action, kAxsNotchHomeVCFlipVisibleUp);
}
static void axs_notchhome_hookVCActMatchMove(id self, SEL _cmd, id action) {
    axs_notchhome_vcActionWorker(sAxsNotchHomeSlotVCActMatchMove, self, _cmd, action, kAxsNotchHomeVCFlipActiveDown);
}
static void axs_notchhome_hookVCActIconOverlay(id self, SEL _cmd, id action) {
    axs_notchhome_vcActionWorker(sAxsNotchHomeSlotVCActIconOverlay, self, _cmd, action, kAxsNotchHomeVCFlipVisibleDown);
}
static void axs_notchhome_hookVCActIconView(id self, SEL _cmd, id action) {
    axs_notchhome_vcActionWorker(sAxsNotchHomeSlotVCActIconView, self, _cmd, action, kAxsNotchHomeVCFlipVisibleUp);
}

static void axs_notchhome_diagDumpIvars(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        axs_notchhome_diagLogF("ivars %s: class-missing", className.UTF8String);
        return;
    }
    for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned count = 0;
        Ivar *ivars = class_copyIvarList(c, &count);
        axs_notchhome_diagLogF("ivars %s (on %s): %u", className.UTF8String,
            class_getName(c), count);
        for (unsigned i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            axs_notchhome_diagLogF("  ivar %s off=%td type=%s",
                ivar_getName(ivars[i]), ivar_getOffset(ivars[i]), type ? type : "?");
        }
        free(ivars);
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
        axs_notchhome_diagDumpClass(@"SBFluidSwitcherViewController");
        axs_notchhome_diagDumpIvars(@"SBMatchMoveToIconViewSwitcherEventResponse");
        axs_notchhome_diagDumpIvars(@"SBIconOverlayVisibilitySwitcherEventResponse");
        axs_notchhome_diagDumpIvars(@"SBIconViewVisibilitySwitcherEventResponse");
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

    // Registrar B's two view-controller action hooks (see the worker
    // above). Signature-verified like every other slot; if the class or
    // method is absent the install silently skips, as in the original.
    // Registrar B's six view-controller hooks (see the worker above).
    // Signature-verified like every other slot; on iOS 15.4 the three
    // Action: installs fail (methods absent) exactly as in the
    // original, and the three Response: installs engage.
    NSString *vc = @"SBFluidSwitcherViewController";
    axs_notchhome_slot(&sAxsNotchHomeSlotVCRspMatchMove, vc, @"_performModifierMatchMoveToIconViewResponse:");
    BOOL vcRspMM = [sAxsNotchHomeSlotVCRspMatchMove axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookVCRspMatchMove
                                                                              returnType:"v" argumentTypes:@[@"@"]];
    axs_notchhome_slot(&sAxsNotchHomeSlotVCRspIconOverlay, vc, @"_performModifierIconOverlayVisibilityUpdateResponse:");
    BOOL vcRspIO = [sAxsNotchHomeSlotVCRspIconOverlay axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookVCRspIconOverlay
                                                                                 returnType:"v" argumentTypes:@[@"@"]];
    axs_notchhome_slot(&sAxsNotchHomeSlotVCRspIconView, vc, @"_performModifierIconViewVisibilityUpdateResponse:");
    BOOL vcRspIV = [sAxsNotchHomeSlotVCRspIconView axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookVCRspIconView
                                                                              returnType:"v" argumentTypes:@[@"@"]];
    axs_notchhome_slot(&sAxsNotchHomeSlotVCActMatchMove, vc, @"_performModifierMatchMoveToIconViewAction:");
    BOOL vcActMM = [sAxsNotchHomeSlotVCActMatchMove axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookVCActMatchMove
                                                                              returnType:"v" argumentTypes:@[@"@"]];
    axs_notchhome_slot(&sAxsNotchHomeSlotVCActIconOverlay, vc, @"_performModifierIconOverlayVisibilityUpdateAction:");
    BOOL vcActIO = [sAxsNotchHomeSlotVCActIconOverlay axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookVCActIconOverlay
                                                                                 returnType:"v" argumentTypes:@[@"@"]];
    axs_notchhome_slot(&sAxsNotchHomeSlotVCActIconView, vc, @"_performModifierIconViewVisibilityUpdateAction:");
    BOOL vcActIV = [sAxsNotchHomeSlotVCActIconView axs_notchhome_installWithReplacement:(IMP)axs_notchhome_hookVCActIconView
                                                                              returnType:"v" argumentTypes:@[@"@"]];
    axs_notchhome_diagLogF("vc installs: rsp mm=%d io=%d iv=%d; act mm=%d io=%d iv=%d",
        (int)vcRspMM, (int)vcRspIO, (int)vcRspIV, (int)vcActMM, (int)vcActIO, (int)vcActIV);

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
