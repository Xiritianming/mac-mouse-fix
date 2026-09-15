//
// --------------------------------------------------------------------------
// ModifiedDragOutputThreeFingerDrag.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2022
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

#import "ModifiedDragOutputThreeFingerSwipe.h"
#import "CGSSpace.h"
#import "TouchSimulator.h"
#import "DisplayLink.h"
#import "SharedUtility.h"
@import Cocoa;
@import QuartzCore;
#import "PointerFreeze.h"
#import "Mac_Mouse_Fix_Helper-Swift.h"
#import <math.h>

/// Modified-drag mouse deltas arrive as integer CoreGraphics fields. At low pointer speeds,
/// many physical reports therefore collapse into zero-delta events, while the occasional
/// non-zero event advances by a whole point. Driving DockSwipe directly from those events
/// makes the interactive Mission Control/Spaces animation visibly step on high-refresh displays.
///
/// Keep input collection event-driven, but drive DockSwipe output from a display link. The
/// resampler tracks cumulative progress, estimates input velocity from event timestamps, and
/// predicts by less than one mouse point between integer updates. This reconstructs the missing
/// sub-point motion without allowing prediction error to grow noticeably.

static const double kDockSwipePredictionLimitPoints = 0.85;
static const double kDockSwipeVelocitySmoothingTime = 0.035;
static const double kDockSwipeMaxLag = 0.020;
static const double kDockSwipeVelocityHeadroom = 1.10;
static const double kDockSwipeDeltaEpsilon = 1.0e-10;

static ModifiedDragState *_drag;
static int16_t _nOfSpaces = 1;

/// Input-side state. These are only touched from ModifiedDrag's serial queue.
static double _dragInputScale = 0.0;

/// Output-side state. Everything below is only touched from `_dockSwipeDisplayLink.dispatchQueue`.
static DisplayLink *_dockSwipeDisplayLink;
static BOOL _dockSwipeIsActive = NO;
static BOOL _dockSwipeSentBegan = NO;
static MFDockSwipeType _dockSwipeType = kMFDockSwipeTypeVertical;
static BOOL _dockSwipeInvertedFromDevice = NO;
static double _dockSwipeTargetProgress = 0.0;
static double _dockSwipeOutputProgress = 0.0;
static double _dockSwipeEstimatedVelocity = 0.0;      /// DockSwipe progress units / second, signed
static double _dockSwipePredictionLimit = 0.0;        /// DockSwipe progress units
static CFTimeInterval _dockSwipeLastInputTime = 0.0;
static CFTimeInterval _dockSwipeLastFrameTime = 0.0;

static void ensureDockSwipeDisplayLink(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void (^createDisplayLink)(void) = ^{
            _dockSwipeDisplayLink = [DisplayLink displayLinkOptimizedForWorkType:kMFDisplayLinkWorkTypeEventSending];
        };

        /// CVDisplayLink setup has historically been most reliable when initialized from main.
        if (NSThread.isMainThread) {
            createDisplayLink();
        } else {
            dispatch_sync(dispatch_get_main_queue(), createDisplayLink);
        }
    });
}

static double fallbackFrameDuration(DisplayLinkCallbackTimeInfo timeInfo) {
    double result = timeInfo.timeBetweenFrames;
    if (!(result > 0.0) || !isfinite(result)) result = timeInfo.nominalTimeBetweenFrames;
    if (!(result > 0.0) || !isfinite(result)) result = 1.0 / 60.0;
    return result;
}

static void postResampledDelta_Unsafe(double delta) {
    if (!_dockSwipeIsActive || fabs(delta) <= kDockSwipeDeltaEpsilon) return;

    IOHIDEventPhaseBits phase = _dockSwipeSentBegan ? kIOHIDEventPhaseChanged : kIOHIDEventPhaseBegan;
    [TouchSimulator postDockSwipeEventWithDelta:delta
                                           type:_dockSwipeType
                                          phase:phase
                             invertedFromDevice:_dockSwipeInvertedFromDevice];

    _dockSwipeOutputProgress += delta;
    _dockSwipeSentBegan = YES;
}

static void dockSwipeDisplayLinkCallback_Unsafe(DisplayLinkCallbackTimeInfo timeInfo) {
    if (!_dockSwipeIsActive) return;

    double frameTime = timeInfo.cvCallbackTime;
    double frameDuration = fallbackFrameDuration(timeInfo);

    if (_dockSwipeLastFrameTime > 0.0) {
        double measuredDuration = frameTime - _dockSwipeLastFrameTime;
        /// Ignore timing discontinuities when a display mode changes or the machine stalls.
        if (measuredDuration > 0.001 && measuredDuration < 0.050 && isfinite(measuredDuration)) {
            frameDuration = measuredDuration;
        }
    }
    _dockSwipeLastFrameTime = frameTime;

    /// Predict no more than 0.85 input points past the latest integer CoreGraphics delta.
    /// With steady slow motion this makes the target advance every display frame instead of
    /// alternating between long holds and one-point jumps. If the user stops, the maximum
    /// prediction error is visually negligible and is intentionally not snapped backwards.
    double predictedTarget = _dockSwipeTargetProgress;
    if (_dockSwipeLastInputTime > 0.0 && fabs(_dockSwipeEstimatedVelocity) > kDockSwipeDeltaEpsilon) {
        double inputAge = fmax(0.0, frameTime - _dockSwipeLastInputTime);
        double prediction = _dockSwipeEstimatedVelocity * inputAge;
        if (_dockSwipePredictionLimit > 0.0 && fabs(prediction) > _dockSwipePredictionLimit) {
            prediction = copysign(_dockSwipePredictionLimit, prediction);
        }
        predictedTarget += prediction;
    }

    double distance = predictedTarget - _dockSwipeOutputProgress;
    if (fabs(distance) <= kDockSwipeDeltaEpsilon) return;

    /// Follow the estimated mouse velocity when possible. The lag term is a safety net for the
    /// first couple of integer events and sudden speed changes, keeping the resampler responsive
    /// without collapsing slow movement back into one-frame jumps.
    double stepFromVelocity = fabs(_dockSwipeEstimatedVelocity) * frameDuration * kDockSwipeVelocityHeadroom;
    double stepFromLag = fabs(distance) * fmin(1.0, frameDuration / kDockSwipeMaxLag);
    double maxStep = fmax(stepFromVelocity, stepFromLag);
    if (!(maxStep > 0.0) || !isfinite(maxStep)) maxStep = fabs(distance);

    double delta = copysign(fmin(fabs(distance), maxStep), distance);
    postResampledDelta_Unsafe(delta);
}

@implementation ModifiedDragOutputThreeFingerSwipe

/// Interface funcs

+ (void)initializeWithDragState:(ModifiedDragState *)dragStateRef {
    _drag = dragStateRef;
    ensureDockSwipeDisplayLink();
}

+ (void)handleBecameInUse {
    /// Get number of spaces
    ///     for use in horizontal scaling. Full-screen spaces appear twice, so filter duplicates.
    CFArrayRef spaces = CGSCopySpaces(CGSMainConnectionID(), CGSSpaceIncludesUser | CGSSpaceIncludesOthers | CGSSpaceIncludesCurrent);
    NSSet *uniqueSpaces = [NSSet setWithArray:(__bridge NSArray *)spaces];
    _nOfSpaces = uniqueSpaces.count;
    CFRelease(spaces);

    /// Cache the input-to-DockSwipe scale on ModifiedDrag's queue.
    CGSize screenSize = NSScreen.mainScreen.frame.size;
    MFDockSwipeType type;
    if (_drag->usageAxis == kMFAxisHorizontal) {
        double originOffsetForOneSpace = _nOfSpaces == 1 ? 2.0 : 1.0 + (1.0 / (_nOfSpaces - 1));
        double spaceSeparatorWidth = 63.0;
        double threeFingerScaleH = originOffsetForOneSpace / (screenSize.width + spaceSeparatorWidth);
        _dragInputScale = -threeFingerScaleH;
        type = kMFDockSwipeTypeHorizontal;
    } else if (_drag->usageAxis == kMFAxisVertical) {
        _dragInputScale = 1.0 / screenSize.height;
        type = kMFDockSwipeTypeVertical;
    } else {
        assert(false);
        return;
    }

    BOOL invertedFromDevice = _drag->naturalDirection;
    double predictionLimit = fabs(_dragInputScale) * kDockSwipePredictionLimitPoints;

    /// Reset and start the display-synchronised output driver. Queueing this before the first
    /// input update guarantees deterministic ordering without sharing mutable state across queues.
    dispatch_async(_dockSwipeDisplayLink.dispatchQueue, ^{
        _dockSwipeIsActive = YES;
        _dockSwipeSentBegan = NO;
        _dockSwipeType = type;
        _dockSwipeInvertedFromDevice = invertedFromDevice;
        _dockSwipeTargetProgress = 0.0;
        _dockSwipeOutputProgress = 0.0;
        _dockSwipeEstimatedVelocity = 0.0;
        _dockSwipePredictionLimit = predictionLimit;
        _dockSwipeLastInputTime = 0.0;
        _dockSwipeLastFrameTime = 0.0;

        [_dockSwipeDisplayLink linkToMainScreen_Unsafe];
        [_dockSwipeDisplayLink start_UnsafeWithCallback:^(DisplayLinkCallbackTimeInfo timeInfo) {
            dockSwipeDisplayLinkCallback_Unsafe(timeInfo);
        }];
    });

    /// Freeze pointer
    if (GeneralConfig.freezePointerDuringModifiedDrag) {
        [PointerFreeze freezePointerAtPosition:_drag->usageOrigin];
    }
}

+ (void)handleMouseInputWhileInUseWithDeltaX:(double)deltaX deltaY:(double)deltaY event:(CGEventRef)event {
    double axisDelta;
    if (_drag->usageAxis == kMFAxisHorizontal) {
        axisDelta = deltaX;
    } else if (_drag->usageAxis == kMFAxisVertical) {
        axisDelta = deltaY;
    } else {
        assert(false);
        return;
    }

    double scaledDelta = axisDelta * _dragInputScale;
    if (fabs(scaledDelta) <= kDockSwipeDeltaEpsilon) return;

    /// CGEvent timestamps use mach absolute time, the same time base used by DisplayLink's
    /// `cvCallbackTime` after conversion in DisplayLink.m. Fall back for unusual synthetic events.
    CGEventTimestamp eventTimestamp = CGEventGetTimestamp(event);
    CFTimeInterval inputTime = eventTimestamp != 0 ? machTimeToSeconds(eventTimestamp) : CACurrentMediaTime();

    dispatch_async(_dockSwipeDisplayLink.dispatchQueue, ^{
        if (!_dockSwipeIsActive) return;

        if (_dockSwipeLastInputTime > 0.0) {
            double inputDuration = inputTime - _dockSwipeLastInputTime;
            if (inputDuration > 0.001 && inputDuration < 0.250 && isfinite(inputDuration)) {
                double measuredVelocity = scaledDelta / inputDuration;

                if (fabs(_dockSwipeEstimatedVelocity) <= kDockSwipeDeltaEpsilon
                    || copysign(1.0, measuredVelocity) != copysign(1.0, _dockSwipeEstimatedVelocity)) {
                    /// Direction changes should take effect immediately instead of being averaged with
                    /// stale velocity from the opposite direction.
                    _dockSwipeEstimatedVelocity = measuredVelocity;
                } else {
                    double alpha = 1.0 - exp(-inputDuration / kDockSwipeVelocitySmoothingTime);
                    _dockSwipeEstimatedVelocity += alpha * (measuredVelocity - _dockSwipeEstimatedVelocity);
                }
            }
        }

        _dockSwipeLastInputTime = inputTime;
        _dockSwipeTargetProgress += scaledDelta;
    });
}

+ (void)handleDeactivationWhileInUseWithCancel:(BOOL)cancel {
    /// Finish on the resampler queue so all queued mouse deltas are processed before the end phase.
    dispatch_sync(_dockSwipeDisplayLink.dispatchQueue, ^{
        if (!_dockSwipeIsActive) return;

        if (!cancel) {
            /// Flush known input that the resampler is still behind on. Do not snap backwards when
            /// output is only ahead because of the sub-point predictor; that would create a visible
            /// one-frame reversal and can make TouchSimulator classify the gesture as cancelled.
            double knownDistance = _dockSwipeTargetProgress - _dockSwipeOutputProgress;
            BOOL outputIsBehindLatestMotion =
                fabs(knownDistance) > kDockSwipeDeltaEpsilon
                && (fabs(_dockSwipeEstimatedVelocity) <= kDockSwipeDeltaEpsilon
                    || copysign(1.0, knownDistance) == copysign(1.0, _dockSwipeEstimatedVelocity));

            if (outputIsBehindLatestMotion) {
                postResampledDelta_Unsafe(knownDistance);
            }
        }

        if (_dockSwipeSentBegan) {
            IOHIDEventPhaseBits phase = cancel ? kIOHIDEventPhaseCancelled : kIOHIDEventPhaseEnded;
            [TouchSimulator postDockSwipeEventWithDelta:0.0
                                                   type:_dockSwipeType
                                                  phase:phase
                                     invertedFromDevice:_dockSwipeInvertedFromDevice];
        }

        _dockSwipeIsActive = NO;
        [_dockSwipeDisplayLink stop_Unsafe];
    });

    /// Unfreeze pointer
    if (GeneralConfig.freezePointerDuringModifiedDrag) {
        [PointerFreeze unfreeze];
    }
}

+ (void)suspend {}
+ (void)unsuspend {}

@end
