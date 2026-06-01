#pragma once
#ifdef __OBJC__
#import <MetalKit/MetalKit.h>
#include "scene.h"
#include "../tracking/imu_service.h"

@protocol RNSControlActions;

// On-Mac live mirror of the glasses render. Reuses the scene's pipeline and
// capture textures (via sceneRenderInto) and adds mouse editing:
//   click        select the screen under the cursor (clears if none)
//   drag         move the selected screen (azimuth / elevation)
//   scroll       change the selected screen's distance
//   drop an app  pin that app to the screen under the drop point
// Camera is stable (identity) by default; `followHead` mirrors the glasses.
@interface RNSPreviewView : MTKView <MTKViewDelegate, NSDraggingDestination>
@property(nonatomic, assign) rns::Scene        scene;
@property(nonatomic, assign) rns::ImuService*  imu;       // unowned
@property(nonatomic, weak)   id<RNSControlActions> actions;
@property(nonatomic, assign) BOOL              followHead;
- (instancetype)initWithScene:(rns::Scene)scene
                          imu:(rns::ImuService*)imu
                       device:(id<MTLDevice>)device
                      actions:(id<RNSControlActions>)actions;
@end
#endif
