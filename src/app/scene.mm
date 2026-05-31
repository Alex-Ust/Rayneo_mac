#include "scene.h"
#include "../config.h"
#include "../render/mat4.h"
#include "../tracking/quat.h"
#include "../capture/capture_source.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#include <cstdio>
#include <vector>

// ---------------------------------------------------------------------------
// Shaders (compiled at runtime). One textured-quad pipeline, applied per
// screen quad. The vertex stage transforms a unit quad (-1..+1) by
// model * view * projection; fragment samples the per-quad texture.

static NSString* const kSceneShaders = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProj;
};

struct PerQuad {
    float4x4 model;
};

struct VSIn {
    float2 pos  [[attribute(0)]];
    float2 uv   [[attribute(1)]];
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

vertex VSOut vs_main(VSIn in [[stage_in]],
                     constant Uniforms& u  [[buffer(1)]],
                     constant PerQuad&  q  [[buffer(2)]]) {
    VSOut o;
    float4 world = q.model * float4(in.pos, 0.0, 1.0);
    o.position   = u.viewProj * world;
    o.uv         = in.uv;
    return o;
}

fragment float4 fs_main(VSOut in [[stage_in]],
                        texture2d<float> tex [[texture(0)]],
                        sampler samp         [[sampler(0)]]) {
    return tex.sample(samp, in.uv);
}
)MSL";

// ---------------------------------------------------------------------------
// Uniform structs (CPU mirrors of the MSL structs above).

struct Uniforms {
    simd_float4x4 viewProj;
};
struct PerQuad {
    simd_float4x4 model;
};

static simd_float4x4 mat4ToSimd(const rns::Mat4& m) {
    simd_float4x4 r;
    for (int c = 0; c < 4; ++c) {
        r.columns[c] = simd_make_float4(m.m[c*4+0], m.m[c*4+1],
                                        m.m[c*4+2], m.m[c*4+3]);
    }
    return r;
}

// ---------------------------------------------------------------------------
// Procedural texture: a colored ramp per quad, so we can visually identify
// which quad is which (left/center/right) before ScreenCaptureKit lands.

static id<MTLTexture> makeProceduralTexture(id<MTLDevice> dev,
                                            int width, int height,
                                            float baseHue) {
    MTLTextureDescriptor* d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:d];

    std::vector<uint8_t> pixels(width * height * 4);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            float u = (float)x / (float)(width  - 1);
            float v = (float)y / (float)(height - 1);
            // Diagonal HSV ramp built around baseHue, with a few darker
            // grid lines so motion is visible.
            float h = baseHue + u * 0.2f - 0.1f;
            float s = 0.9f;
            float val = 0.85f - v * 0.4f;
            int gx = (int)(u * 16.0f), gy = (int)(v * 9.0f);
            if (((x % (width  / 16)) == 0) ||
                ((y % (height /  9)) == 0)) val *= 0.5f;
            (void)gx; (void)gy;

            // HSV -> RGB
            h = h - floorf(h);
            float k = h * 6.0f;
            int   si = (int)k;
            float fr = k - (float)si;
            float p = val * (1 - s);
            float q = val * (1 - s * fr);
            float t = val * (1 - s * (1 - fr));
            float r=0,g=0,b=0;
            switch (si % 6) {
                case 0: r=val; g=t;   b=p;   break;
                case 1: r=q;   g=val; b=p;   break;
                case 2: r=p;   g=val; b=t;   break;
                case 3: r=p;   g=q;   b=val; break;
                case 4: r=t;   g=p;   b=val; break;
                default:r=val; g=p;   b=q;   break;
            }
            uint8_t* px = &pixels[(y * width + x) * 4];
            px[0] = (uint8_t)(b * 255); // BGRA
            px[1] = (uint8_t)(g * 255);
            px[2] = (uint8_t)(r * 255);
            px[3] = 255;
        }
    }
    [tex replaceRegion:MTLRegionMake2D(0, 0, width, height)
           mipmapLevel:0
             withBytes:pixels.data()
           bytesPerRow:width * 4];
    return tex;
}

// ---------------------------------------------------------------------------
// Scene delegate.

@interface RNSScene : NSObject <MTKViewDelegate>
@property (nonatomic, strong) id<MTLDevice>              device;
@property (nonatomic, strong) id<MTLCommandQueue>        queue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) id<MTLDepthStencilState>   depthState;
@property (nonatomic, strong) id<MTLBuffer>              vertexBuffer;
@property (nonatomic, strong) id<MTLBuffer>              indexBuffer;
@property (nonatomic, strong) NSMutableArray<id<MTLTexture>>* quadTextures;
@property (nonatomic, strong) id<MTLSamplerState>        sampler;
@property (nonatomic, assign) rns::ImuService*           imu; // unowned
/// Indexed by quad index: optional capture source override. nullptr = use
/// the procedural texture from _quadTextures at the same index.
@property (nonatomic, assign) std::vector<rns::CaptureSource*>* captureSources;
@end

@implementation RNSScene

- (instancetype)initWithView:(MTKView*)view imu:(rns::ImuService*)imu {
    if ((self = [super init])) {
        _device = view.device ?: MTLCreateSystemDefaultDevice();
        view.device = _device;
        _queue  = [_device newCommandQueue];
        _imu    = imu;
        _captureSources = new std::vector<rns::CaptureSource*>(
            rns::config().screens.size(), nullptr);

        view.colorPixelFormat        = MTLPixelFormatBGRA8Unorm;
        view.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
        view.preferredFramesPerSecond = 120;
        view.clearColor              = MTLClearColorMake(0, 0, 0, 1);
        view.framebufferOnly         = YES;

        if (![self buildPipeline]) return nil;
        [self buildGeometry];
        [self buildSampler];
        [self buildProceduralTextures];
    }
    return self;
}

- (void)dealloc {
    delete _captureSources;
    _captureSources = nullptr;
}

- (BOOL)buildPipeline {
    NSError* err = nil;
    MTLCompileOptions* opts = [[MTLCompileOptions alloc] init];
    id<MTLLibrary> lib = [_device newLibraryWithSource:kSceneShaders
                                                options:opts
                                                  error:&err];
    if (!lib) {
        std::fprintf(stderr, "Metal shader compile failed: %s\n",
                     err.localizedDescription.UTF8String);
        return NO;
    }

    MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
    d.vertexFunction   = [lib newFunctionWithName:@"vs_main"];
    d.fragmentFunction = [lib newFunctionWithName:@"fs_main"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    d.depthAttachmentPixelFormat      = MTLPixelFormatDepth32Float;

    MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
    vd.attributes[0].format = MTLVertexFormatFloat2;
    vd.attributes[0].offset = 0;
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat2;
    vd.attributes[1].offset = sizeof(float) * 2;
    vd.attributes[1].bufferIndex = 0;
    vd.layouts[0].stride = sizeof(float) * 4;
    d.vertexDescriptor = vd;

    _pipeline = [_device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!_pipeline) {
        std::fprintf(stderr, "Pipeline build failed: %s\n",
                     err.localizedDescription.UTF8String);
        return NO;
    }

    MTLDepthStencilDescriptor* dsd = [[MTLDepthStencilDescriptor alloc] init];
    dsd.depthCompareFunction = MTLCompareFunctionLess;
    dsd.depthWriteEnabled    = YES;
    _depthState = [_device newDepthStencilStateWithDescriptor:dsd];
    return YES;
}

- (void)buildGeometry {
    // Unit quad in the XY plane, UVs (0..1). v0=BL, v1=BR, v2=TR, v3=TL.
    static const float verts[] = {
        -1.f, -1.f,  0.f, 1.f,
         1.f, -1.f,  1.f, 1.f,
         1.f,  1.f,  1.f, 0.f,
        -1.f,  1.f,  0.f, 0.f,
    };
    static const uint16_t indices[] = { 0, 1, 2,  0, 2, 3 };
    _vertexBuffer = [_device newBufferWithBytes:verts length:sizeof(verts)
                                        options:MTLResourceStorageModeShared];
    _indexBuffer  = [_device newBufferWithBytes:indices length:sizeof(indices)
                                        options:MTLResourceStorageModeShared];
}

- (void)buildSampler {
    MTLSamplerDescriptor* sd = [[MTLSamplerDescriptor alloc] init];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    _sampler = [_device newSamplerStateWithDescriptor:sd];
}

- (void)buildProceduralTextures {
    _quadTextures = [NSMutableArray array];
    const auto& cfg = rns::config();
    const float hues[] = { 0.55f, 0.10f, 0.85f }; // L=cyan, C=orange, R=magenta
    for (size_t i = 0; i < cfg.screens.size(); ++i) {
        float h = (i < 3) ? hues[i] : (float)i * 0.31f;
        id<MTLTexture> tex = makeProceduralTexture(_device, 640, 360, h);
        [_quadTextures addObject:tex];
    }
}

// ---------------------------------------------------------------------------
// Draw

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {
    (void)view; (void)size;
}

- (void)drawInMTKView:(MTKView*)view {
    MTLRenderPassDescriptor* rpd = view.currentRenderPassDescriptor;
    if (!rpd) return;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!drawable) return;

    // Camera. View matrix = inverse(headQuat) since headQuat rotates world
    // INTO head; we need the same rotation applied to world points to bring
    // them into head/eye space. (The world is rendered as seen from the head.)
    rns::ImuService::Snapshot snap;
    if (_imu) snap = _imu->snapshot();
    rns::Mat4 view4 = rns::Mat4::fromQuat(snap.view);

    const float aspect = (float)view.drawableSize.width
                       / std::max(1.0f, (float)view.drawableSize.height);
    // Convert diagonal FOV (config) into vertical FOV given the display aspect.
    const float diag = rns::degToRad(rns::config().fovDiagonalDeg);
    const float fovY = 2.0f * std::atan(std::tan(diag * 0.5f) /
                                        std::sqrt(1.0f + aspect * aspect));
    rns::Mat4 proj = rns::Mat4::perspective(fovY, aspect, 0.05f, 50.0f);
    rns::Mat4 viewProj4 = rns::Mat4::mul(proj, view4);

    Uniforms u{};
    u.viewProj = mat4ToSimd(viewProj4);

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    [enc setRenderPipelineState:_pipeline];
    [enc setDepthStencilState:_depthState];
    [enc setCullMode:MTLCullModeNone];
    [enc setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
    [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
    [enc setFragmentSamplerState:_sampler atIndex:0];

    const auto& cfg = rns::config();
    for (size_t i = 0; i < cfg.screens.size(); ++i) {
        const auto& s = cfg.screens[i];
        if (!s.visible) continue;   // hidden slot (toggled with 1/2/3)
        rns::Mat4 model = rns::quadModelMatrix(
            s.azimuthDeg, s.elevationDeg, s.distanceM, s.widthM, s.heightM);
        PerQuad pq{ mat4ToSimd(model) };
        [enc setVertexBytes:&pq length:sizeof(pq) atIndex:2];
        id<MTLTexture> tex = nil;
        // Prefer a live capture texture for this quad if one is wired up.
        if (_captureSources && (size_t)i < _captureSources->size()
            && (*_captureSources)[i]) {
            void* p = rns::captureLatestTexture(*(*_captureSources)[i]);
            tex = (__bridge id<MTLTexture>)p;
        }
        if (!tex) {
            tex = (i < _quadTextures.count) ? _quadTextures[i]
                                            : _quadTextures.firstObject;
        }
        [enc setFragmentTexture:tex atIndex:0];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:6
                         indexType:MTLIndexTypeUInt16
                       indexBuffer:_indexBuffer
                 indexBufferOffset:0];
    }

    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
}
@end

// ---------------------------------------------------------------------------
// C++ glue.

namespace rns {

Scene makeScene(void* mtkView, ImuService* imu) {
    MTKView* v = (__bridge MTKView*)mtkView;
    RNSScene* s = [[RNSScene alloc] initWithView:v imu:imu];
    v.delegate = s;
    Scene out;
    out.objc = (__bridge_retained void*)s;
    return out;
}

void destroyScene(Scene& s) {
    if (s.objc) {
        RNSScene* o = (__bridge_transfer RNSScene*)s.objc;
        (void)o;
        s.objc = nullptr;
    }
}

void sceneSetCaptureSource(Scene s, int quadIndex, CaptureSource* source) {
    if (!s.objc) return;
    RNSScene* o = (__bridge RNSScene*)s.objc;
    if (!o.captureSources) return;
    if (quadIndex < 0 || (size_t)quadIndex >= o.captureSources->size()) return;
    (*o.captureSources)[quadIndex] = source;
}

} // namespace rns
