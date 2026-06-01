#include "capture_source.h"
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <cmath>
#include <algorithm>

// ---------------------------------------------------------------------------
// RNSCaptureSource — one SCStream + one CVMetalTextureCache, double-buffered
// latest texture under a lock.

@interface RNSCaptureSource : NSObject <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, strong) SCStream* stream;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, assign) CVMetalTextureCacheRef cache;
@property (nonatomic, strong) id<MTLTexture> latest; // atomic via @synchronized
@property (nonatomic, assign) BOOL gotFirstFrame;
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
    if (!_gotFirstFrame) {
        _gotFirstFrame = YES;
        std::fprintf(stderr, "  [capture] first frame %zux%zu\n", w, h);
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
+ (nullable SCShareableContent*)fetchSyncWithTimeout:(NSTimeInterval)timeout
                                        onScreenOnly:(BOOL)onScreenOnly;
@end

@implementation RNSShareableContent
+ (nullable SCShareableContent*)fetchSyncWithTimeout:(NSTimeInterval)timeout {
    return [self fetchSyncWithTimeout:timeout onScreenOnly:YES];
}
+ (nullable SCShareableContent*)fetchSyncWithTimeout:(NSTimeInterval)timeout
                                        onScreenOnly:(BOOL)onScreenOnly {
    __block SCShareableContent* result = nil;
    __block NSError* err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                               onScreenWindowsOnly:onScreenOnly
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
    bool pre = CGPreflightScreenCaptureAccess();
    bool granted = CGRequestScreenCaptureAccess() != 0;
    std::fprintf(stderr,
        "Screen Recording permission: preflight=%s, after-request=%s\n",
        pre ? "GRANTED" : "DENIED",
        granted ? "GRANTED" : "DENIED");
    if (!granted) {
        std::fprintf(stderr,
            "  -> Captures will show placeholder colors until you grant it.\n"
            "  -> System Settings > Privacy & Security > Screen Recording:\n"
            "     enable 'RayNeoSpatial' (add the .app if missing), then relaunch.\n");
    }
    return granted;
}

// Shared display-capture path used by both the built-in and by-id entrypoints.
static CaptureSource makeDisplayCaptureInternal(id<MTLDevice> device,
                                                SCDisplay* chosen,
                                                int width, int height) {
    CaptureSource out;
    SCContentFilter* filter =
        [[SCContentFilter alloc] initWithDisplay:chosen excludingWindows:@[]];

    // Size the buffer to the display's POINT size. ScreenCaptureKit delivers
    // the content at point size and does NOT upscale into a larger buffer — an
    // oversized buffer leaves the content tiny in a black corner. Point size
    // either matches exactly or gets downscaled to fit, but always fills.
    int w = (int)chosen.width, h = (int)chosen.height;
    if (w <= 0 || h <= 0) { w = width; h = height; }
    w = std::max(640, std::min(4096, w));
    h = std::max(480, std::min(2304, h));
    std::fprintf(stderr, "  display %u capture buffer %dx%d\n",
                 (unsigned)chosen.displayID, w, h);

    SCStreamConfiguration* cfg = [[SCStreamConfiguration alloc] init];
    cfg.pixelFormat        = kCVPixelFormatType_32BGRA;
    cfg.width              = w;
    cfg.height             = h;
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
    if (![stream addStreamOutput:src
                            type:SCStreamOutputTypeScreen
              sampleHandlerQueue:outQ
                           error:&err]) {
        std::fprintf(stderr, "addStreamOutput failed: %s\n",
                     err.localizedDescription.UTF8String);
        return out;
    }
    src.stream = stream;
    [stream startCaptureWithCompletionHandler:^(NSError* e) {
        if (e) {
            std::fprintf(stderr, "startCapture failed: %s\n",
                         e.localizedDescription.UTF8String);
        }
    }];
    out.objc = (__bridge_retained void*)src;
    return out;
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
    if (!content || content.displays.count == 0) {
        std::fprintf(stderr, "No SCDisplays found\n");
        return out;
    }
    SCDisplay* chosen = content.displays.firstObject;
    for (SCDisplay* d in content.displays) {
        if (CGDisplayIsBuiltin(d.displayID)) { chosen = d; break; }
    }
    return makeDisplayCaptureInternal(device, chosen, width, height);
}

CaptureSource makeDisplayCapture(void* devicePtr, uint32_t displayID,
                                 int width, int height) {
    CaptureSource out;
    id<MTLDevice> device = (__bridge id<MTLDevice>)devicePtr;
    if (!device) return out;
    SCShareableContent* content =
        [RNSShareableContent fetchSyncWithTimeout:5.0];
    if (!content) return out;
    SCDisplay* chosen = nil;
    for (SCDisplay* d in content.displays) {
        if (d.displayID == displayID) { chosen = d; break; }
    }
    if (!chosen) {
        std::fprintf(stderr, "makeDisplayCapture: display id=%u not found\n",
                     (unsigned)displayID);
        return out;
    }
    return makeDisplayCaptureInternal(device, chosen, width, height);
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

// Helper: make a CaptureSource for one specific SCWindow.
static CaptureSource makeWindowCaptureInternal(id<MTLDevice> device,
                                               SCWindow* window,
                                               int width, int height) {
    CaptureSource out;
    SCContentFilter* filter =
        [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];

    // Size the output buffer to the window's POINT size. SCK delivers window
    // content at point size and does NOT upscale into a larger buffer, so a
    // fixed/oversized buffer left the window tiny in a black corner. Point size
    // matches exactly (or downscales) but always fills.
    int w = (int)std::lround(window.frame.size.width);
    int h = (int)std::lround(window.frame.size.height);
    w = std::max(320, std::min(3840, w ? w : width));
    h = std::max(240, std::min(2160, h ? h : height));
    std::fprintf(stderr, "  window capture buffer %dx%d\n", w, h);

    SCStreamConfiguration* cfg = [[SCStreamConfiguration alloc] init];
    cfg.pixelFormat        = kCVPixelFormatType_32BGRA;
    cfg.width              = w;
    cfg.height             = h;
    cfg.minimumFrameInterval = CMTimeMake(1, 60);
    cfg.queueDepth         = 5;
    cfg.showsCursor        = NO;
    cfg.scalesToFit        = YES;

    RNSCaptureSource* src = [[RNSCaptureSource alloc] initWithDevice:device];
    SCStream* stream = [[SCStream alloc] initWithFilter:filter
                                          configuration:cfg
                                               delegate:src];
    NSError* err = nil;
    dispatch_queue_t outQ = dispatch_queue_create("rns.capture.win",
                                                  DISPATCH_QUEUE_SERIAL);
    if (![stream addStreamOutput:src
                            type:SCStreamOutputTypeScreen
              sampleHandlerQueue:outQ
                           error:&err]) {
        std::fprintf(stderr, "window addStreamOutput failed: %s\n",
                     err.localizedDescription.UTF8String);
        return out;
    }
    src.stream = stream;
    [stream startCaptureWithCompletionHandler:^(NSError* e) {
        if (e) {
            std::fprintf(stderr, "window startCapture failed: %s\n",
                         e.localizedDescription.UTF8String);
        }
    }];
    out.objc = (__bridge_retained void*)src;
    return out;
}

CaptureSource makeAppWindowCapture(void* devicePtr,
                                   const std::string& appNameSubstring,
                                   int width, int height) {
    CaptureSource out;
    id<MTLDevice> device = (__bridge id<MTLDevice>)devicePtr;
    if (!device) return out;

    // Include windows on ALL Spaces (not just the active one) so we still find
    // the app when it's full-screen or on another desktop. Prefer on-screen
    // windows but fall back to any matching window.
    SCShareableContent* content =
        [RNSShareableContent fetchSyncWithTimeout:5.0 onScreenOnly:NO];
    if (!content) return out;

    NSString* needle = [[NSString stringWithUTF8String:appNameSubstring.c_str()]
                        lowercaseString];

    SCWindow* best = nil;
    double bestArea = 0;
    BOOL bestOnScreen = NO;
    for (SCWindow* w in content.windows) {
        if (w.frame.size.width < 100 || w.frame.size.height < 100) continue;
        NSString* appName = [w.owningApplication.applicationName lowercaseString];
        if (!appName || [appName rangeOfString:needle].location == NSNotFound)
            continue;
        double area = w.frame.size.width * w.frame.size.height;
        BOOL on = w.onScreen;
        // Prefer on-screen; among equal on-screen-ness, prefer the larger window.
        if (!best || (on && !bestOnScreen) ||
            (on == bestOnScreen && area > bestArea)) {
            best = w; bestArea = area; bestOnScreen = on;
        }
    }
    if (!best) {
        std::fprintf(stderr, "  no window found for app '%s'\n",
                     appNameSubstring.c_str());
        return out;
    }
    std::fprintf(stderr, "  app '%s' window onScreen=%d\n",
                 appNameSubstring.c_str(), (int)bestOnScreen);
    std::fprintf(stderr, "  app '%s' -> '%s' %.0fx%.0f\n",
                 appNameSubstring.c_str(),
                 best.title.UTF8String ?: "",
                 best.frame.size.width, best.frame.size.height);
    return makeWindowCaptureInternal(device, best, width, height);
}

int discoverWindowCaptures(void* devicePtr, int maxCount,
                           int width, int height,
                           std::vector<CaptureSource>& out) {
    out.clear();
    if (maxCount <= 0) return 0;
    id<MTLDevice> device = (__bridge id<MTLDevice>)devicePtr;
    if (!device) return 0;

    SCShareableContent* content =
        [RNSShareableContent fetchSyncWithTimeout:5.0];
    if (!content) return 0;

    // Self-app's PID, so we can exclude our own glasses-display window.
    pid_t myPid = getpid();

    // Filter: on-screen, non-empty title, area > 100x100 px, not own app.
    NSMutableArray<SCWindow*>* candidates = [NSMutableArray array];
    for (SCWindow* w in content.windows) {
        if (!w.onScreen) continue;
        if (w.frame.size.width  < 100 || w.frame.size.height < 100) continue;
        if (w.owningApplication.processID == myPid) continue;
        // Skip pure-decoration windows (no title and no app).
        if (!w.owningApplication && (w.title.length == 0)) continue;
        [candidates addObject:w];
    }
    // Sort by area descending.
    [candidates sortUsingComparator:^NSComparisonResult(SCWindow* a, SCWindow* b) {
        double aA = a.frame.size.width * a.frame.size.height;
        double aB = b.frame.size.width * b.frame.size.height;
        if (aA < aB) return NSOrderedDescending;
        if (aA > aB) return NSOrderedAscending;
        return NSOrderedSame;
    }];

    int taken = 0;
    for (SCWindow* w in candidates) {
        if (taken >= maxCount) break;
        std::fprintf(stderr, "  capture[%d] '%s' (%s) %.0fx%.0f\n",
                     taken,
                     w.title.UTF8String ?: "",
                     w.owningApplication.applicationName.UTF8String ?: "?",
                     w.frame.size.width, w.frame.size.height);
        CaptureSource cs = makeWindowCaptureInternal(device, w, width, height);
        if (cs.objc) {
            out.push_back(cs);
            ++taken;
        }
    }
    return taken;
}

} // namespace rns
