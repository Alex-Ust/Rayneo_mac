#include "preview_view.h"
#include "control_actions.h"
#include "pick.h"
#include "../config.h"
#include "../tracking/quat.h"
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cstdio>

// Wider than the glasses' real FOV so the mirror shows all the screens and
// head movement at once (and so picking can reach the side screens).
static const float kPreviewFovDiag = 115.0f;

@implementation RNSPreviewView {
    id<MTLCommandQueue> _previewQueue;   // own queue (not shared with glasses view)
}

- (instancetype)initWithScene:(rns::Scene)scene
                          imu:(rns::ImuService*)imu
                       device:(id<MTLDevice>)device
                      actions:(id<RNSControlActions>)actions {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, 340, 200) device:device])) {
        _scene      = scene;
        _imu        = imu;
        _actions    = actions;
        _followHead = NO;
        _previewQueue = [device newCommandQueue];

        self.delegate                = self;
        self.colorPixelFormat        = MTLPixelFormatBGRA8Unorm;
        self.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
        self.clearColor              = MTLClearColorMake(0.05, 0.05, 0.06, 1.0);
        self.framebufferOnly         = YES;
        self.paused                  = NO;
        self.enableSetNeedsDisplay    = NO;
        self.preferredFramesPerSecond = 60;
        self.layer.borderWidth        = 1.0;
        self.layer.borderColor        =
            [NSColor colorWithWhite:0.3 alpha:1.0].CGColor;

        [self registerForDraggedTypes:@[NSPasteboardTypeString]];
    }
    return self;
}

// --- render -----------------------------------------------------------------

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size { (void)view; (void)size; }

- (void)drawInMTKView:(MTKView*)view {
    rns::Quat cam = rns::Quat::identity();        // stable by default
    if (_followHead && _imu) cam = _imu->snapshot().view;
    rns::sceneRenderInto(_scene, (__bridge void*)view, cam, kPreviewFovDiag,
                         (__bridge void*)_previewQueue);
}

// --- input helpers ----------------------------------------------------------

- (rns::Quat)cameraQuat {
    if (_followHead && _imu) return _imu->snapshot().view;
    return rns::Quat::identity();
}

- (BOOL)ndcAtWindowPoint:(NSPoint)winPt outX:(float*)nx outY:(float*)ny {
    NSPoint p = [self convertPoint:winPt fromView:nil];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    if (w <= 0 || h <= 0) return NO;
    *nx = (float)(p.x / w) * 2.0f - 1.0f;   // AppKit y is bottom-up → matches NDC
    *ny = (float)(p.y / h) * 2.0f - 1.0f;
    return YES;
}

- (float)aspect {
    CGFloat h = self.bounds.size.height;
    return h > 0 ? (float)(self.bounds.size.width / h) : 1.0f;
}

// --- mouse: select + move ---------------------------------------------------

- (void)mouseDown:(NSEvent*)event {
    float nx, ny;
    if (![self ndcAtWindowPoint:event.locationInWindow outX:&nx outY:&ny]) return;
    int slot = rns::pickSlot(nx, ny, [self aspect],
                             kPreviewFovDiag, [self cameraQuat]);
    rns::config().selectedSlot = slot;            // -1 (empty click) deselects
}

- (void)mouseDragged:(NSEvent*)event {
    rns::Config& cfg = rns::config();
    int sel = cfg.selectedSlot;
    if (sel < 0 || sel >= (int)cfg.screens.size()) return;
    float nx, ny;
    if (![self ndcAtWindowPoint:event.locationInWindow outX:&nx outY:&ny]) return;
    float az, el;
    rns::cursorToAzEl(nx, ny, [self aspect],
                      kPreviewFovDiag, [self cameraQuat], az, el);
    cfg.screens[sel].azimuthDeg   = std::max(-90.0f, std::min(90.0f, az));
    cfg.screens[sel].elevationDeg = std::max(-45.0f, std::min(45.0f, el));
}

- (void)scrollWheel:(NSEvent*)event {
    rns::Config& cfg = rns::config();
    int sel = cfg.selectedSlot;
    if (sel < 0 || sel >= (int)cfg.screens.size()) return;
    float d = cfg.screens[sel].distanceM - (float)event.scrollingDeltaY * 0.01f;
    cfg.screens[sel].distanceM = std::max(0.3f, std::min(6.0f, d));
}

// --- drag destination: drop an app onto a screen ----------------------------

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    (void)sender;
    return NSDragOperationCopy;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSString* name = [sender.draggingPasteboard stringForType:NSPasteboardTypeString];
    if (!name.length) return NO;
    float nx, ny;
    if (![self ndcAtWindowPoint:sender.draggingLocation outX:&nx outY:&ny]) return NO;
    int slot = rns::pickNearestSlot(nx, ny, [self aspect],
                                    kPreviewFovDiag, [self cameraQuat]);
    if (slot < 0) {
        std::fprintf(stderr, "\n[drop '%s' missed a screen]\n", name.UTF8String);
        return NO;
    }
    rns::config().selectedSlot = slot;
    [self.actions pinAppNamed:name toIndex:slot];
    return YES;
}

@end
