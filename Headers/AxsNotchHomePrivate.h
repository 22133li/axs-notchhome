#pragma once

#import <UIKit/UIKit.h>

// Private interfaces confirmed by the static audit of NotchHome 0.5.0.
// Only the exact selectors found in the original binary are declared here.

// Layout-identical stand-in for the private UIRectCornerRadii struct
// (type encoding "{UIRectCornerRadii=dddd}", four doubles).
typedef struct {
    double topLeft;
    double topRight;
    double bottomLeft;
    double bottomRight;
} AxsNotchHomeCornerRadii;

@interface SBFFluidBehaviorSettings : NSObject
- (double)dampingRatio;
- (void)setDampingRatio:(double)ratio;
@end

@interface SBSwitcherAnimationAttributes : NSObject
- (SBFFluidBehaviorSettings *)positionSettings;
- (SBFFluidBehaviorSettings *)scaleSettings;
- (void)setPositionSettings:(SBFFluidBehaviorSettings *)settings;
- (void)setScaleSettings:(SBFFluidBehaviorSettings *)settings;
@end
