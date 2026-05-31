#include "app.h"
#include "scene.h"
#include "../config.h"
#include "../display/display_locator.h"
#include "../tracking/quat.h"
#include "../virtualdisplay/virtual_display_manager.h"
#include <vector>
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#include <cstdio>

namespace {

// Find the NSScreen whose CGDirectDisplayID matches the candidate.
NSScreen* nsScreenForDisplayID(uint32_t displayID) {
    NSNumber* target = @(displayID);
    for (NSScreen* s in [NSScreen screens]) {
        NSNumber* num = [[s deviceDescription]
                          objectForKey:@"NSScreenNumber"];
        if (num && [num isEqualToNumber:target]) return s;
    }
    return nil;
}

} // namespace

// ----------------------------------------------------------------------------
// AppDelegate. Owns the window/renderer; routes keyDown to imu/quit.

@interface RNSAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow*  window;
@property (nonatomic, strong) MTKView*   mtkView;
@property (nonatomic, assign) rns::Scene scene;
@property (nonatomic, assign) rns::CaptureSource capture;
@property (nonatomic, assign) std::vector<rns::CaptureSource>* captures;
@property (nonatomic, assign) rns::VirtualDisplayManager* vdm;
@property (nonatomic, assign) rns::ImuService* imu; // unowned
@property (nonatomic, assign) uint32_t glassesDisplayID;
@property (nonatomic, strong) id keyMonitor;
- (void)screenParamsChanged:(NSNotification*)note;
- (void)logSurfaceGeometry:(NSString*)tag;
- (void)refitToGlassesScreen;
@end

@implementation RNSAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)note {
    (void)note;
    NSScreen* screen = nsScreenForDisplayID(self.glassesDisplayID);
    if (!screen) {
        std::fprintf(stderr,
                     "RNS: glasses NSScreen for displayID %u not found; "
                     "falling back to main screen.\n", self.glassesDisplayID);
        screen = [NSScreen mainScreen];
    }

    NSRect frame = [screen frame];
    self.window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO
                     screen:screen];
    [self.window setLevel:NSMainMenuWindowLevel + 1];
    [self.window setOpaque:YES];
    [self.window setHasShadow:NO];
    [self.window setBackgroundColor:[NSColor blackColor]];
    [self.window setIgnoresMouseEvents:YES];
    [self.window setCollectionBehavior:
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorStationary |
        NSWindowCollectionBehaviorFullScreenAuxiliary];

    id<MTLDevice> mtlDev = MTLCreateSystemDefaultDevice();
    // Local (0,0)-based bounds for the content view; the window's contentRect
    // (above) already positions it on the glasses screen in global coords.
    NSRect localBounds = NSMakeRect(0, 0, frame.size.width, frame.size.height);
    MTKView* mtkv = [[MTKView alloc] initWithFrame:localBounds device:mtlDev];
    mtkv.framebufferOnly = YES;
    mtkv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.window setContentView:mtkv];
    self.mtkView = mtkv;

    // The glasses change DisplayPort timing when we switch 2D<->3D (the IMU
    // service issues DisplaySet2D on attach), which makes macOS re-publish the
    // display at a new resolution AFTER this window was sized. Re-fit on every
    // screen-parameters change so the fullscreen surface always matches.
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(screenParamsChanged:)
               name:NSApplicationDidChangeScreenParametersNotification
             object:nil];
    [self logSurfaceGeometry:@"launch"];

    rns::Scene sc = rns::makeScene((__bridge void*)mtkv, self.imu);
    self.scene = sc;

    // Wire each slot's capture source per its config: an App slot captures
    // that app's window; a Display slot mirrors the built-in display. One
    // CaptureSource per slot, kept in self.captures (index-aligned to slots).
    if (rns::requestScreenRecordingPermission()) {
        const auto& slots = rns::config().screens;
        self.captures = new std::vector<rns::CaptureSource>(slots.size());
        self.vdm = new rns::VirtualDisplayManager();

        // Pass 1: create a real virtual monitor for every Display slot. We
        // record the displayID per slot (0 for App slots).
        std::vector<uint32_t> slotDisplayID(slots.size(), 0);
        for (size_t i = 0; i < slots.size(); ++i) {
            if (slots[i].source != rns::SlotSource::App) {
                char nm[64];
                std::snprintf(nm, sizeof(nm), "RayNeo Screen %zu", i + 1);
                slotDisplayID[i] = self.vdm->create(nm, 1920, 1080, 60.0,
                                                    /*hidpi=*/true);
            }
        }
        // Let the main run loop register the new displays with the window
        // server before we ask ScreenCaptureKit to enumerate them.
        if (self.vdm->displays().size() > 0) {
            [[NSRunLoop currentRunLoop]
                runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
        }

        // Pass 2: wire each slot's capture.
        for (size_t i = 0; i < slots.size(); ++i) {
            rns::CaptureSource cs;
            if (slots[i].source == rns::SlotSource::App
                && !slots[i].appName.empty()) {
                cs = rns::makeAppWindowCapture(
                    (__bridge void*)mtlDev, slots[i].appName, 1920, 1080);
            } else if (slotDisplayID[i] != 0) {
                cs = rns::makeDisplayCapture(
                    (__bridge void*)mtlDev, slotDisplayID[i], 1920, 1080);
            }
            if (!cs.objc) {
                // Fallback so the slot is never blank (private API missing,
                // app not running, etc.).
                cs = rns::makeBuiltinDisplayCapture(
                    (__bridge void*)mtlDev, 1920, 1080);
            }
            (*self.captures)[i] = cs;
            if (cs.objc) {
                rns::sceneSetCaptureSource(self.scene, (int)i,
                                           &(*self.captures)[i]);
            }
        }
    } else {
        std::fprintf(stderr,
            "Screen Recording permission not granted yet. Grant it in\n"
            "System Settings > Privacy & Security > Screen Recording and\n"
            "relaunch RayNeoSpatial to see the captured desktop on the\n"
            "center panel. The procedural texture is shown meanwhile.\n");
    }

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    // Global-ish key handler. Local monitor sees keys when our app is key.
    __weak RNSAppDelegate* weakSelf = self;
    self.keyMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                     handler:^NSEvent* (NSEvent* evt) {
        NSString* chars = [[evt charactersIgnoringModifiers] lowercaseString];
        NSEventModifierFlags mods = [evt modifierFlags];
        bool cmd     = (mods & NSEventModifierFlagCommand) != 0;
        bool ctrl    = (mods & NSEventModifierFlagControl) != 0;
        bool opt     = (mods & NSEventModifierFlagOption) != 0;
        bool ctrlOpt = ctrl && opt;
        unichar key = [chars length] > 0 ? [chars characterAtIndex:0] : 0;

        if ((cmd && key == 'q') || key == 27 /*Esc*/) {
            [NSApp terminate:weakSelf];
            return nil;
        }
        // Recenter: ⌃⌥R or plain r.
        if ((ctrlOpt && key == 'r') || (!cmd && !ctrl && !opt && key == 'r')) {
            if (weakSelf.imu) weakSelf.imu->recenter();
            std::fprintf(stderr, "\n[recentered]\n");
            return nil;
        }
        // M3 hotkeys (⌃⌥+key, plus a no-modifier shortcut for the glasses'
        // limited HID where modifier keys may not pass through).
        rns::Config& cfg = rns::config();
        auto bumpSpread = [&](float delta){
            for (auto& s : cfg.screens) {
                // Scale spread uniformly: positive azimuths grow positive,
                // negative grow negative. Zero stays zero (the center quad).
                if (s.azimuthDeg > 0) s.azimuthDeg += delta;
                else if (s.azimuthDeg < 0) s.azimuthDeg -= delta;
            }
            std::fprintf(stderr, "\n[spread %+.0f° → ", delta);
            for (auto& s : cfg.screens) std::fprintf(stderr, "%.0f ", s.azimuthDeg);
            std::fprintf(stderr, "]\n");
        };
        auto bumpDistance = [&](float delta){
            for (auto& s : cfg.screens) {
                s.distanceM = std::max(0.3f, s.distanceM + delta);
            }
            std::fprintf(stderr, "\n[distance %+.2fm → %.2fm]\n",
                         delta, cfg.screens[0].distanceM);
        };
        bool consume = true;
        if      ((ctrlOpt || (!cmd && !ctrl && !opt)) && key == '[') bumpSpread(-5.0f);
        else if ((ctrlOpt || (!cmd && !ctrl && !opt)) && key == ']') bumpSpread(+5.0f);
        else if ((ctrlOpt || (!cmd && !ctrl && !opt)) && key == '-') bumpDistance(-0.1f);
        else if ((ctrlOpt || (!cmd && !ctrl && !opt)) && (key == '=' || key == '+')) bumpDistance(+0.1f);
        else if (ctrlOpt && key == 't') {
            cfg.yawEnabled = !cfg.yawEnabled;
            std::fprintf(stderr, "\n[yaw tracking %s]\n",
                         cfg.yawEnabled ? "on" : "off");
        }
        else if (ctrlOpt && key == 'p') {
            cfg.pitchEnabled = !cfg.pitchEnabled;
            std::fprintf(stderr, "\n[pitch tracking %s]\n",
                         cfg.pitchEnabled ? "on" : "off");
        }
        // Keys 1/2/3: toggle slot visibility (hide a panel so only 2 or 1 show).
        else if (key >= '1' && key <= '9') {
            size_t idx = (size_t)(key - '1');
            if (idx < cfg.screens.size()) {
                cfg.screens[idx].visible = !cfg.screens[idx].visible;
                std::fprintf(stderr, "\n[slot %zu %s]\n",
                             idx + 1, cfg.screens[idx].visible ? "shown" : "hidden");
            }
        }
        else consume = false;
        if (consume) return nil;
        return evt;
    }];
}

- (void)screenParamsChanged:(NSNotification*)note {
    (void)note;
    [self refitToGlassesScreen];
    [self logSurfaceGeometry:@"screen-params-changed"];
}

- (void)refitToGlassesScreen {
    NSScreen* screen = nsScreenForDisplayID(self.glassesDisplayID);
    if (!screen) return;
    NSRect frame = [screen frame];
    [self.window setFrame:frame display:YES];
    // contentView autoresizes with the window, but pin it explicitly to be safe.
    self.mtkView.frame = NSMakeRect(0, 0, frame.size.width, frame.size.height);
}

- (void)logSurfaceGeometry:(NSString*)tag {
    NSScreen* screen = nsScreenForDisplayID(self.glassesDisplayID);
    NSRect sf = screen ? [screen frame] : NSZeroRect;
    CGFloat scale = screen ? [screen backingScaleFactor] : 0;
    NSRect wf = self.window.frame;
    NSRect cb = self.mtkView.bounds;
    CGSize ds = self.mtkView.drawableSize;
    // CGDisplay pixel mode of the glasses display.
    CGDirectDisplayID did = self.glassesDisplayID;
    size_t pw = CGDisplayPixelsWide(did), ph = CGDisplayPixelsHigh(did);
    std::fprintf(stderr,
        "\n[geom %s] screen.frame=(%.0f,%.0f %0.fx%.0f) scale=%.1f | "
        "CGpixels=%zux%zu | window=(%.0f,%.0f %.0fx%.0f) | "
        "view.bounds=%.0fx%.0f | drawable=%.0fx%.0f\n",
        tag.UTF8String,
        sf.origin.x, sf.origin.y, sf.size.width, sf.size.height, scale,
        pw, ph,
        wf.origin.x, wf.origin.y, wf.size.width, wf.size.height,
        cb.size.width, cb.size.height,
        ds.width, ds.height);
}

- (void)applicationWillTerminate:(NSNotification*)note {
    (void)note;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.keyMonitor) {
        [NSEvent removeMonitor:self.keyMonitor];
        self.keyMonitor = nil;
    }
    rns::Scene sc = self.scene;
    rns::destroyScene(sc);
    self.scene = sc;

    rns::CaptureSource cap = self.capture;
    rns::destroyCapture(cap);
    self.capture = cap;

    if (self.captures) {
        for (auto& c : *self.captures) rns::destroyCapture(c);
        delete self.captures;
        self.captures = nullptr;
    }

    // Always tear down virtual displays so the user isn't left with phantom
    // monitors after quit.
    if (self.vdm) {
        self.vdm->teardown();
        delete self.vdm;
        self.vdm = nullptr;
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)app {
    (void)app;
    return YES;
}
@end

namespace rns {

int runApp(ImuService& imu, const DisplayInfo& glasses) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        RNSAppDelegate* delegate = [[RNSAppDelegate alloc] init];
        delegate.imu = &imu;
        delegate.glassesDisplayID = glasses.displayID;
        [NSApp setDelegate:delegate];

        [NSApp run];
    }
    return 0;
}

} // namespace rns
