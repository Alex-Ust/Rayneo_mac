#include "app.h"
#include "scene.h"
#include "../config.h"
#include "../display/display_locator.h"
#include "../tracking/quat.h"
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
@property (nonatomic, assign) rns::Scene scene;
@property (nonatomic, assign) rns::CaptureSource capture;
@property (nonatomic, assign) rns::ImuService* imu; // unowned
@property (nonatomic, assign) uint32_t glassesDisplayID;
@property (nonatomic, strong) id keyMonitor;
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
    MTKView* mtkv = [[MTKView alloc] initWithFrame:frame device:mtlDev];
    mtkv.framebufferOnly = YES;
    [self.window setContentView:mtkv];

    rns::Scene sc = rns::makeScene((__bridge void*)mtkv, self.imu);
    self.scene = sc;

    // Try to start screen capture and wire it into quad index 1 (center).
    // If permission isn't granted yet, the procedural texture stays visible
    // and the OS will queue a prompt for the next run.
    if (rns::requestScreenRecordingPermission()) {
        self.capture = rns::makeBuiltinDisplayCapture(
            (__bridge void*)mtlDev, 1920, 1080);
        if (self.capture.objc) {
            rns::sceneSetCaptureSource(self.scene, /*quadIndex=*/1,
                                       &self->_capture);
            std::fprintf(stderr,
                "Capture started (built-in display -> center quad)\n");
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
        else consume = false;
        if (consume) return nil;
        return evt;
    }];
}

- (void)applicationWillTerminate:(NSNotification*)note {
    (void)note;
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
