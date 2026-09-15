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
@import Cocoa;
#import "PointerFreeze.h"
#import "Mac_Mouse_Fix_Helper-Swift.h"
#import <math.h>

@implementation ModifiedDragOutputThreeFingerSwipe

/// Vars

static ModifiedDragState *_drag;
static int16_t _nOfSpaces = 1;

/// DockSwipe resampling state
///
/// Mouse-drag input reaches this code at an irregular cadence and in integer deltas.
/// Feeding each input event straight into DockSwipe makes slow drags visibly step on
/// high-refresh displays. Instead we accumulate the requested DockSwipe progress and
/// let a CVDisplayLink-backed resampler emit small double-precision deltas at the
/// display cadence.
static DisplayLink *_dockSwipeDisplayLink;
static NSObject *_dockSwipeStateLock;
static BOOL _dockSwipeGestureActive = NO;
static BOOL _dockSwipeSentBegan = NO;
static double _dockSwipeTargetOffset = 0.0;
static double _dockSwipeRenderedOffset = 0.0;
static CFTimeInterval _dockSwipeLastFrameTime = 0.0;
static MFDockSwipeType _dockSwipeType = kMFDockSwipeTypeVertical;
static BOOL _dockSwipeInvertedFromDevice = NO;

/// A short time constant removes the one-pixel stepping without making the gesture
/// feel detached from the mouse. At 160 Hz this spreads a step over a few frames;
/// at 60 Hz it is effectively immediate.
static const CFTimeInterval kDockSwipeSmoothingTimeConstant = 0.004;
static const double kDockSwipeSettleEpsilon = 1e-6;

static void ensureDockSwipeDisplayLink(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _dockSwipeStateLock = [NSObject new];
        _dockSwipeDisplayLink = [DisplayLink displayLinkOptimizedForWorkType:kMFDisplayLinkWorkTypeEventSending];
    });
}

static void postResampledDockSwipeDelta(double delta) {
    if (delta == 0.0) return;

    IOHIDEventPhaseBits phase = _dockSwipeSentBegan ? kIOHIDEventPhaseChanged : kIOHIDEventPhaseBegan;
    [TouchSimulator postDockSwipeEventWithDelta:delta
                                           type:_dockSwipeType
                                          phase:phase
                             invertedFromDevice:_dockSwipeInvertedFromDevice];
    _dockSwipeSentBegan = YES;
    _dockSwipeRenderedOffset += delta;
}

static void dockSwipeDisplayLinkCallback(DisplayLinkCallbackTimeInfo timeInfo) {
    ensureDockSwipeDisplayLink();

    @synchronized (_dockSwipeStateLock) {
        if (!_dockSwipeGestureActive) return;

        CFTimeInterval now = CACurrentMediaTime();
        CFTimeInterval dt = _dockSwipeLastFrameTime > 0.0 ? now - _dockSwipeLastFrameTime : timeInfo.nominalTimeBetweenFrames;
        _dockSwipeLastFrameTime = now;

        /// Keep pathological scheduling delays from turning the filter into a jump.
        if (!(dt > 0.0) || !isfinite(dt)) dt = 1.0 / 120.0;
        dt = MIN(MAX(dt, 1.0 / 500.0), 1.0 / 30.0);

        double error = _dockSwipeTargetOffset - _dockSwipeRenderedOffset;
        if (fabs(error) <= kDockSwipeSettleEpsilon) {
            if (error != 0.0) postResampledDockSwipeDelta(error);
            return;
        }

        /// Frame-rate-independent first-order response.
        double alpha = 1.0 - exp(-dt / kDockSwipeSmoothingTimeConstant);
        double delta = error * alpha;

        /// Avoid spending many frames on an imperceptible tail.
        if (fabs(error - delta) <= kDockSwipeSettleEpsilon) delta = error;

        postResampledDockSwipeDelta(delta);
    }
}

/// Interface funcs

+ (void)initializeWithDragState:(ModifiedDragState *)dragStateRef {
    _drag = dragStateRef;
    ensureDockSwipeDisplayLink();
}

+ (void)handleBecameInUse {
    /// Get number of spaces
    ///     for use in `handleMouseInputWhileInUse()`. Getting it here for performance reasons. Not sure if significant.
    CFArrayRef spaces = CGSCopySpaces(CGSMainConnectionID(), CGSSpaceIncludesUser | CGSSpaceIncludesOthers | CGSSpaceIncludesCurrent);
    /// Full screen spaces appear twice for some reason so we need to filter duplicates
    NSSet *uniqueSpaces = [NSSet setWithArray:(__bridge NSArray *)spaces];
    _nOfSpaces = uniqueSpaces.count;

    CFRelease(spaces);

    ensureDockSwipeDisplayLink();

    @synchronized (_dockSwipeStateLock) {
        _dockSwipeGestureActive = YES;
        _dockSwipeSentBegan = NO;
        _dockSwipeTargetOffset = 0.0;
        _dockSwipeRenderedOffset = 0.0;
        _dockSwipeLastFrameTime = 0.0;
        _dockSwipeInvertedFromDevice = _drag->naturalDirection;

        if (_drag->usageAxis == kMFAxisHorizontal) {
            _dockSwipeType = kMFDockSwipeTypeHorizontal;
        } else if (_drag->usageAxis == kMFAxisVertical) {
            _dockSwipeType = kMFDockSwipeTypeVertical;
        } else {
            assert(false);
        }
    }

    /// Linking and starting are queued in-order on the DisplayLink's serial queue.
    [_dockSwipeDisplayLink linkToMainScreen];
    dispatch_async(_dockSwipeDisplayLink.dispatchQueue, ^{
        if (![_dockSwipeDisplayLink isRunning_Unsafe]) {
            [_dockSwipeDisplayLink start_UnsafeWithCallback:^(DisplayLinkCallbackTimeInfo timeInfo) {
                dockSwipeDisplayLinkCallback(timeInfo);
            }];
        }
    });

    /// Freeze pointer
    if (GeneralConfig.freezePointerDuringModifiedDrag) {
        [PointerFreeze freezePointerAtPosition:_drag->usageOrigin];
    }
}

+ (void)handleMouseInputWhileInUseWithDeltaX:(double)deltaX deltaY:(double)deltaY event:(CGEventRef)event {

    /**
     Horizontal dockSwipe scaling
     This makes horizontal dockSwipes (switch between spaces) follow the pointer exactly
     I arrived at these value through testing documented in the NotePlan note "MMF - Scraps - Testing DockSwipe scaling"
     TODO: Test this on a vertical screen
     */
    CGSize screenSize = NSScreen.mainScreen.frame.size;
    double originOffsetForOneSpace = _nOfSpaces == 1 ? 2.0 : 1.0 + (1.0 / (_nOfSpaces-1));
    double spaceSeparatorWidth = 63;
    double threeFingerScaleH = originOffsetForOneSpace / (screenSize.width + spaceSeparatorWidth);

    /// Vertical dockSwipe scaling
    ///     Not sure if it makes sense to scale this with screen height
    double threeFingerScaleV = 1.0 / screenSize.height;

    double delta = 0.0;
    if (_drag->usageAxis == kMFAxisHorizontal) {
        delta = -deltaX * threeFingerScaleH;
    } else if (_drag->usageAxis == kMFAxisVertical) {
        delta = deltaY * threeFingerScaleV;
    } else {
        assert(false);
        return;
    }

    /// Do not send DockSwipe events directly from the mouse-event cadence. Add them
    /// to the target instead; the DisplayLink callback emits frame-paced subpixel deltas.
    @synchronized (_dockSwipeStateLock) {
        if (_dockSwipeGestureActive) {
            _dockSwipeTargetOffset += delta;
        }
    }
}

+ (void)handleDeactivationWhileInUseWithCancel:(BOOL)cancel {

    ensureDockSwipeDisplayLink();

    @synchronized (_dockSwipeStateLock) {
        if (_dockSwipeGestureActive) {
            /// Flush the tiny filter remainder before lifting the synthetic fingers so
            /// the final gesture position still matches the physical drag exactly.
            double remainder = _dockSwipeTargetOffset - _dockSwipeRenderedOffset;
            if (remainder != 0.0) {
                postResampledDockSwipeDelta(remainder);
            }

            if (_dockSwipeSentBegan) {
                IOHIDEventPhaseBits phase = cancel ? kIOHIDEventPhaseCancelled : kIOHIDEventPhaseEnded;
                [TouchSimulator postDockSwipeEventWithDelta:0.0
                                                       type:_dockSwipeType
                                                      phase:phase
                                         invertedFromDevice:_dockSwipeInvertedFromDevice];
            }

            _dockSwipeGestureActive = NO;
            _dockSwipeLastFrameTime = 0.0;
        }
    }

    dispatch_async(_dockSwipeDisplayLink.dispatchQueue, ^{
        if ([_dockSwipeDisplayLink isRunning_Unsafe]) {
            [_dockSwipeDisplayLink stop_Unsafe];
        }
    });

    /// Unfreeze pointer
    if (GeneralConfig.freezePointerDuringModifiedDrag) {
        [PointerFreeze unfreeze];
    }
}

+ (void)suspend {}
+ (void)unsuspend {}

@end
