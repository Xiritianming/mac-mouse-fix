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
#import "CGSDisplays.h"

@implementation ModifiedDragOutputThreeFingerSwipe

/// Vars

static ModifiedDragState *_drag;

static int16_t _nOfSpaces = 1;
static NSSize _screenSize = {};
static double _threeFingerScaleH = 0.0;
static double _threeFingerScaleV = 0.0;

/// Interface funcs

+ (void)initializeWithDragState:(ModifiedDragState *)dragStateRef {
    _drag = dragStateRef;
}

+ (void)handleBecameInUse {

    NSScreen *screen = [NSScreen mainScreen];

    /// Cache screen-dependent scaling once per gesture.
    /// This keeps the mouse-report hot path free of NSScreen / Spaces queries.
    _screenSize = [screen frame].size;

    if (_drag->usageAxis == kMFAxisHorizontal) {
        /// Support multiple displays by counting Spaces for the display that owns the current screen.
        NSArray *spacesInfo = CFBridgingRelease(CGSCopyManagedDisplaySpaces(CGSMainConnectionID()));
        NSString *screenUUID = [screen mf_UUIDString];

        NSDictionary *entry = nil;
        for (NSDictionary *screenDict in spacesInfo) {
            if ([[screenDict objectForKey:@"Display Identifier"] isEqual:screenUUID]) {
                entry = screenDict;
                break;
            }
        }

        _nOfSpaces = MAX((int16_t)[[entry objectForKey:@"Spaces"] count], (int16_t)1);
        double originOffsetForOneSpace = _nOfSpaces <= 1 ? 2.0 : 1.0 + (1.0 / (_nOfSpaces - 1));
        const double spaceSeparatorWidth = 63.0;
        _threeFingerScaleH = _screenSize.width > 0.0
            ? originOffsetForOneSpace / (_screenSize.width + spaceSeparatorWidth)
            : 0.0;
    } else if (_drag->usageAxis == kMFAxisVertical) {
        _threeFingerScaleV = _screenSize.height > 0.0 ? 1.0 / _screenSize.height : 0.0;
    }

    /// Freeze pointer
    if (GeneralConfig.freezePointerDuringModifiedDrag) {
        [PointerFreeze freezePointerAtPosition:_drag->usageOrigin];
    }
}

+ (void)handleMouseInputWhileInUseWithDeltaX:(double)deltaX deltaY:(double)deltaY {
    
    /// Get phase
    
    IOHIDEventPhaseBits eventPhase = _drag->firstCallback ? kIOHIDEventPhaseBegan : kIOHIDEventPhaseChanged;
    
    /// Send events
    
    if (_drag->usageAxis == kMFAxisHorizontal) {
        double delta = -deltaX * _threeFingerScaleH;
        [TouchSimulator postDockSwipeEventWithDelta:delta type:kMFDockSwipeTypeHorizontal phase:eventPhase invertedFromDevice:_drag->naturalDirection];
    } else if (_drag->usageAxis == kMFAxisVertical) {
        double delta = deltaY * _threeFingerScaleV;
        [TouchSimulator postDockSwipeEventWithDelta:delta type:kMFDockSwipeTypeVertical phase:eventPhase invertedFromDevice:_drag->naturalDirection];
    }
}

+ (void)handleDeactivationWhileInUseWithCancel:(BOOL)cancel {
    
    MFDockSwipeType type;
    IOHIDEventPhaseBits phase;
    
    if      (_drag->usageAxis == kMFAxisHorizontal) type = kMFDockSwipeTypeHorizontal;
    else if (_drag->usageAxis == kMFAxisVertical)   type = kMFDockSwipeTypeVertical;
    else                                            assert(false);
    
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
