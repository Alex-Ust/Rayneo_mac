#include "renderer.h"
#include "../tracking/quat.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

// MTKViewDelegate that, for M1, just clears the drawable. The clear color is
// a small visible signal that head tracking is plumbed end-to-end: hue
// rotates with the head yaw. Once M2 lands and we draw actual quads, this
// degenerates back into a plain black clear and the quads carry the signal.
@interface RNSRenderer : NSObject <MTKViewDelegate>
@property (nonatomic, strong) id<MTLDevice>       device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, assign) rns::ImuService*    imu; // unowned
@end

@implementation RNSRenderer

- (instancetype)initWithView:(MTKView*)view imu:(rns::ImuService*)imu {
    if ((self = [super init])) {
        _device = view.device ?: MTLCreateSystemDefaultDevice();
        view.device = _device;
        _queue = [_device newCommandQueue];
        _imu = imu;
        view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        view.preferredFramesPerSecond = 120;
        view.paused = NO;
        view.enableSetNeedsDisplay = NO;
        view.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    }
    return self;
}

// Convert hue in [0,1] + value to RGB. Quick HSV->RGB with S=1.
static inline void hueToRgb(float h, float v, float* r, float* g, float* b) {
    h = h - floorf(h);
    float k = h * 6.0f;
    int s = (int)k;
    float f = k - (float)s;
    switch (s % 6) {
        case 0: *r = v;       *g = v * f;   *b = 0;       break;
        case 1: *r = v*(1-f); *g = v;       *b = 0;       break;
        case 2: *r = 0;       *g = v;       *b = v * f;   break;
        case 3: *r = 0;       *g = v*(1-f); *b = v;       break;
        case 4: *r = v * f;   *g = 0;       *b = v;       break;
        default:*r = v;       *g = 0;       *b = v*(1-f); break;
    }
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {
    (void)view; (void)size;
}

- (void)drawInMTKView:(MTKView*)view {
    // Pull head yaw and dimly tint the clear color with it. This is the
    // M1 acceptance signal: when the user turns their head, the on-glasses
    // tint visibly shifts. (M2 replaces this with real quads.)
    float h = 0.0f;
    if (_imu) {
        auto snap = _imu->snapshot();
        float yaw, pitch, roll;
        snap.view.toYPR(yaw, pitch, roll);
        // Map yaw (rad) to hue cycle every 360°.
        h = yaw / (2.0f * (float)M_PI);
    }
    float r=0, g=0, b=0;
    hueToRgb(h, 0.10f, &r, &g, &b); // dim — won't blind through the optics

    view.clearColor = MTLClearColorMake(r, g, b, 1.0);

    MTLRenderPassDescriptor* rpd = view.currentRenderPassDescriptor;
    if (!rpd) return;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!drawable) return;

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
}

@end

namespace rns {

Renderer makeRenderer(void* mtkView, ImuService* imu) {
    MTKView* v = (__bridge MTKView*)mtkView;
    RNSRenderer* r = [[RNSRenderer alloc] initWithView:v imu:imu];
    v.delegate = r;
    Renderer out;
    out.objc = (__bridge_retained void*)r;
    return out;
}

void destroyRenderer(Renderer& r) {
    if (r.objc) {
        RNSRenderer* o = (__bridge_transfer RNSRenderer*)r.objc;
        (void)o;
        r.objc = nullptr;
    }
}

} // namespace rns
