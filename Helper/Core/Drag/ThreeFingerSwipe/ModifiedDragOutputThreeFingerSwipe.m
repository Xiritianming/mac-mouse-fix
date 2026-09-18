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
@import Cocoa;
#import "PointerFreeze.h"
#import "Mac_Mouse_Fix_Helper-Swift.h"

@implementation ModifiedDragOutputThreeFingerSwipe

/// Vars

static ModifiedDragState *_drag;

static int16_t _nOfSpaces = 1;
static double _threeFingerScaleH = 0.0;
static double _threeFingerScaleV = 0.0;

/// Interface funcs

+ (void)initializeWithDragState:(ModifiedDragState *)dragStateRef {
    _drag = dragStateRef;
}

+ (void)handleBecameInUse {
    /// Resolve screen-dependent scaling once per gesture instead of querying NSScreen
    /// and recomputing the same constants for every mouse report.
    CGSize screenSize = NSScreen.mainScreen.frame.size;
    
    /// Get number of spaces only when we actually need horizontal DockSwipe scaling.
    /// Mission Control / vertical DockSwipes do not use this value, and querying Spaces
    /// synchronously while WindowServer is transitioning is unnecessary work on the
    /// gesture-start path.
    if (_drag->usageAxis == kMFAxisHorizontal) {
        CFArrayRef spaces = CGSCopySpaces(CGSMainConnectionID(), CGSSpaceIncludesUser | CGSSpaceIncludesOthers | CGSSpaceIncludesCurrent);
        /// Full screen spaces appear twice for some reason so we need to filter duplicates
        NSSet *uniqueSpaces = [NSSet setWithArray:(__bridge NSArray *)spaces];
        _nOfSpaces = uniqueSpaces.count;
        CFRelease(spaces);
        
        double originOffsetForOneSpace = _nOfSpaces == 1 ? 2.0 : 1.0 + (1.0 / (_nOfSpaces - 1));
        const double spaceSeparatorWidth = 63.0;
        _threeFingerScaleH = screenSize.width > 0.0
            ? originOffsetForOneSpace / (screenSize.width + spaceSeparatorWidth)
            : 0.0;
    } else if (_drag->usageAxis == kMFAxisVertical) {
        _threeFingerScaleV = screenSize.height > 0.0 ? 1.0 / screenSize.height : 0.0;
    }

    /// Freeze pointer
    if (GeneralConfig.freezePointerDuringModifiedDrag) {
        [PointerFreeze freezePointerAtPosition:_drag->usageOrigin];
    }
}

+ (void)handleMouseInputWhileInUseWithDeltaX:(double)deltaX deltaY:(double)deltaY event:(CGEventRef)event {
    
    /// Get phase
    IOHIDEventPhaseBits eventPhase = _drag->firstCallback ? kIOHIDEventPhaseBegan : kIOHIDEventPhaseChanged;

    /// Send events directly from the modified-drag path. TouchSimulator coalesces
    /// high-rate Changed events before posting them to WindowServer, while Began / Ended /
    /// Cancelled remain immediate.
    if (_drag->usageAxis == kMFAxisHorizontal) {
        /**
         Horizontal DockSwipe scaling
         This makes horizontal DockSwipes (switch between spaces) follow the pointer exactly.
         */
        double delta = -deltaX * _threeFingerScaleH;
        [TouchSimulator postDockSwipeEventWithDelta:delta type:kMFDockSwipeTypeHorizontal phase:eventPhase invertedFromDevice:_drag->naturalDirection];
    } else if (_drag->usageAxis == kMFAxisVertical) {
        /// Vertical DockSwipe scaling
        ///     Not sure if it makes sense to scale this with screen height
        double delta = deltaY * _threeFingerScaleV;
        [TouchSimulator postDockSwipeEventWithDelta:delta type:kMFDockSwipeTypeVertical phase:eventPhase invertedFromDevice:_drag->naturalDirection];
    } else {
        assert(false);
    }
}

+ (void)handleDeactivationWhileInUseWithCancel:(BOOL)cancel {
    
    MFDockSwipeType type;
    IOHIDEventPhaseBits phase;
    
    if (_drag->usageAxis == kMFAxisHorizontal) {
        type = kMFDockSwipeTypeHorizontal;
    } else if (_drag->usageAxis == kMFAxisVertical) {
        type = kMFDockSwipeTypeVertical;
    } else {
        assert(false);
    }
    
    phase = cancel ? kIOHIDEventPhaseCancelled : kIOHIDEventPhaseEnded;
    
    [TouchSimulator postDockSwipeEventWithDelta:0.0 type:type phase:phase invertedFromDevice:_drag->naturalDirection];
    
    /// Unfreeze pointer
    if (GeneralConfig.freezePointerDuringModifiedDrag) {
        [PointerFreeze unfreeze];
    }
    
}

+ (void)suspend {}
+ (void)unsuspend {}

@end
