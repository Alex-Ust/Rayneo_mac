#pragma once
#ifdef __OBJC__
#import <Foundation/Foundation.h>

// Actions the control panel can ask the app delegate to perform. These are the
// operations that touch capture streams / virtual displays / the IMU, which
// only the delegate owns. Pure layout edits (azimuth, size, visibility) the
// panel writes straight into rns::config() — the render loop picks them up.
@protocol RNSControlActions <NSObject>
- (void)addScreen;
- (void)removeScreenAtIndex:(NSInteger)index;
- (void)pinAppNamed:(NSString*)appName toIndex:(NSInteger)index;
- (void)revertIndexToScreen:(NSInteger)index;
- (void)recenter;
@end
#endif
