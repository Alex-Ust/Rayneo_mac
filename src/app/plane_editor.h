#pragma once
#ifdef __OBJC__
#import <AppKit/AppKit.h>

@protocol RNSControlActions;

// Flat 2D layout editor: each screen is a rectangle on a plane where the
// horizontal axis is azimuth (left/right) and the vertical axis is elevation
// (up/down). Drag a rectangle to move the screen, scroll to change distance,
// drop an app tile on a rectangle to pin that app. Pure AppKit drawing + hit
// testing — no 3D ray math, so editing is reliable. Reflects config() live.
@interface RNSPlaneEditorView : NSView <NSDraggingDestination>
@property(nonatomic, weak) id<RNSControlActions> actions;
- (instancetype)initWithActions:(id<RNSControlActions>)actions;
@end
#endif
