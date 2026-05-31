#include "capture_source.h"
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Metal/Metal.h>
#include <cstdio>

// ---------------------------------------------------------------------------
// RNSCaptureSource — one SCStream + one CVMetalTextureCache, double-buffered
// latest texture under a lock.

@interface RNSCaptureSource : NSObject <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, strong) SCStream* stream;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, assign) CVMetalTextureCacheRef cache;
@property (nonatomic, strong) id<MTLTexture> latest; // atomic via @synchronized
@end

@implementation RNSCaptureSource

- (instancetype)initWithDevice:(id<MTLDevice>)dev {
    if ((self = [super init])) {
        _device = dev;
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, dev,
                                  nullptr, &_cache);
    }
    return self;
}

- (void)dealloc {
    if (_cache) {
        CFRelease(_cache);
        _cache = nullptr;
    }
}

// MARK: SCStreamOutput

- (void)stream:(SCStream*)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
    ofType:(SCStreamOutputType)type
{
    (void)stream;
    if (type != SCStreamOutputTypeScreen) return;
    if (!CMSampleBufferIsValid(sampleBuffer)) return;
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pb) return;

    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    CVMetalTextureRef cvTex = nullptr;
    CVReturn r = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, _cache, pb, nullptr,
        MTLPixelFormatBGRA8Unorm, w, h, 0, &cvTex);
    if (r != kCVReturnSuccess || !cvTex) {
        if (cvTex) CFRelease(cvTex);
        return;
    }
    id<MTLTexture> tex = CVMetalTextureGetTexture(cvTex);
    @synchronized (self) {
        _latest = tex;
    }
    // The CVMetalTextureCache keeps the underlying IOSurface alive until the
    // texture is released; we can drop the wrapper here.
    CFRelease(cvTex);
}

// MARK: SCStreamDelegate

- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
    (void)stream;
    std::fprintf(stderr, "\nSCStream stopped: %s\n",
                 error.localizedDescription.UTF8String);
}

- (id<MTLTexture>)latestTexture {
    @synchronized (self) {
        return _latest;
    }
}

@end

// ---------------------------------------------------------------------------
// Synchronous wrapper around SCShareableContent (which is async-only).

@interface RNSShareableContent : NSObject
+ (nullable SCShareableContent*)fetchSyncWithTimeout:(NSTimeInterval)timeout;
@end

@implementation RNSShareableContent
+ (nullable SCShareableContent*)fetchSyncWithTimeout:(NSTimeInterval)timeout {
    __block SCShareableContent* result = nil;
    __block NSError* err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                               onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent* c, NSError* e) {
        result = c;
        err = e;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_time_t until = dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)(timeout * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(sem, until) != 0) {
        std::fprintf(stderr, "SCShareableContent fetch timed out\n");
        return nil;
    }
    if (err) {
        std::fprintf(stderr, "SCShareableContent error: %s\n",
                     err.localizedDescription.UTF8String);
        return nil;
    }
    return result;
}
@end

namespace rns {

bool requestScreenRecordingPermission() {
    // Triggers the OS prompt on first call. The prompt path differs by macOS
    // version; CGRequestScreenCaptureAccess returns immediately with the
    // current state. If false, the app must be relaunched after the user
    // grants access in System Settings > Privacy & Security > Screen Recording.
    return CGRequestScreenCaptureAccess() != 0;
}

CaptureSource makeBuiltinDisplayCapture(void* devicePtr, int width, int height) {
    CaptureSource out;
    id<MTLDevice> device = (__bridge id<MTLDevice>)devicePtr;
    if (!device) {
        std::fprintf(stderr, "makeBuiltinDisplayCapture: no Metal device\n");
        return out;
    }

    SCShareableContent* content =
        [RNSShareableContent fetchSyncWithTimeout:5.0];
    if (!content) return out;
    if (content.displays.count == 0) {
        std::fprintf(stderr, "No SCDisplays found\n");
        return out;
    }
    // Built-in display has the lowest displayID on Apple Silicon laptops.
    SCDisplay* chosen = content.displays.firstObject;
    for (SCDisplay* d in content.displays) {
        if (CGDisplayIsBuiltin(d.displayID)) { chosen = d; break; }
    }

    SCContentFilter* filter =
        [[SCContentFilter alloc] initWithDisplay:chosen excludingWindows:@[]];

    SCStreamConfiguration* cfg = [[SCStreamConfiguration alloc] init];
    cfg.pixelFormat        = kCVPixelFormatType_32BGRA;
    cfg.width              = width;
    cfg.height             = height;
    cfg.minimumFrameInterval = CMTimeMake(1, 60);
    cfg.queueDepth         = 5;
    cfg.showsCursor        = YES;
    cfg.scalesToFit        = YES;

    RNSCaptureSource* src = [[RNSCaptureSource alloc] initWithDevice:device];
    SCStream* stream = [[SCStream alloc] initWithFilter:filter
                                          configuration:cfg
                                               delegate:src];
    NSError* err = nil;
    dispatch_queue_t outQ = dispatch_queue_create("rns.capture",
                                                  DISPATCH_QUEUE_SERIAL);
    BOOL added = [stream addStreamOutput:src
                                    type:SCStreamOutputTypeScreen
                      sampleHandlerQueue:outQ
                                   error:&err];
    if (!added) {
        std::fprintf(stderr, "addStreamOutput failed: %s\n",
                     err.localizedDescription.UTF8String);
        return out;
    }
    src.stream = stream;

    // Async start; failures bubble up via the delegate.
    [stream startCaptureWithCompletionHandler:^(NSError* e) {
        if (e) {
            std::fprintf(stderr, "startCapture failed: %s\n",
                         e.localizedDescription.UTF8String);
        }
    }];

    out.objc = (__bridge_retained void*)src;
    return out;
}

void* captureLatestTexture(CaptureSource& cs) {
    if (!cs.objc) return nullptr;
    RNSCaptureSource* src = (__bridge RNSCaptureSource*)cs.objc;
    return (__bridge void*)[src latestTexture];
}

void destroyCapture(CaptureSource& cs) {
    if (!cs.objc) return;
    RNSCaptureSource* src = (__bridge_transfer RNSCaptureSource*)cs.objc;
    cs.objc = nullptr;
    if (src.stream) {
        [src.stream stopCaptureWithCompletionHandler:^(NSError* e) {
            (void)e;
        }];
    }
}

} // namespace rns
