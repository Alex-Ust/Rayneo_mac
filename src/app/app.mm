#include "app.h"
#include "scene.h"
#include "../config.h"
#include "../display/display_locator.h"
#include "../tracking/quat.h"
#include "../virtualdisplay/virtual_display_manager.h"
#include "../capture/capture_source.h"
#include "../config_store.h"
#include <vector>
#include <memory>
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <ApplicationServices/ApplicationServices.h>  // AXIsProcessTrustedWithOptions

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
// One capture source per slot, index-aligned with cfg.screens. unique_ptr so
// the pointers handed to the scene stay valid when the vector grows/shrinks.
@property (nonatomic, assign) std::vector<std::unique_ptr<rns::CaptureSource>>* captures;
@property (nonatomic, assign) rns::VirtualDisplayManager* vdm;
@property (nonatomic, assign) id<MTLDevice> mtlDevice;
@property (nonatomic, assign) rns::ImuService* imu; // unowned
@property (nonatomic, assign) uint32_t glassesDisplayID;
@property (nonatomic, strong) id keyMonitor;
@property (nonatomic, strong) id globalKeyMonitor;
- (void)setupHotkeys;
- (BOOL)handleKeyChars:(NSString*)charsRaw modifiers:(NSEventModifierFlags)mods;
- (void)addScreen;
- (void)removeSelectedScreen;
- (void)pinFrontmostAppToSelected;
- (void)revertSelectedToScreen;
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
    self.mtlDevice = mtlDev;
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
        self.captures = new std::vector<std::unique_ptr<rns::CaptureSource>>();
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
        rns::sceneEnsureSlotCount(self.scene, (int)slots.size());
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
            self.captures->push_back(std::make_unique<rns::CaptureSource>(cs));
            if (cs.objc) {
                rns::sceneSetCaptureSource(self.scene, (int)i,
                                           self.captures->back().get());
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

    [self setupHotkeys];
}

// Control scheme — all chords use ⌃⌥ (Control+Option) so they don't collide
// with normal typing in the app you're actually working in. Returns YES if
// the key was handled (so the local monitor can swallow it).
//
//   ⌃⌥1/2/3   select slot          ⌃⌥A/D  move selected left / right (azimuth)
//   ⌃⌥W/S     move up / down (elev) ⌃⌥-/=  move nearer / farther (distance)
//   ⌃⌥R       recenter (bring screens to where you're looking)
//   ⌃⌥V       hide / show selected  ⌃⌥[ ⌃⌥]  cycle selection prev / next
//   ⌃⌥N       add screen            ⌃⌥X       remove selected screen
//   ⌃⌥P       pin frontmost app     ⌃⌥O       revert slot to a screen
//   ⌃⌥Y/G     toggle yaw / pitch tracking
//   ⌃⌥Q       QUIT (emergency — works even with no focus / lost cursor)
- (BOOL)handleKeyChars:(NSString*)charsRaw modifiers:(NSEventModifierFlags)mods {
    NSString* chars = [charsRaw lowercaseString];
    bool ctrl = (mods & NSEventModifierFlagControl) != 0;
    bool opt  = (mods & NSEventModifierFlagOption)  != 0;
    if (!(ctrl && opt)) return NO;       // only ⌃⌥ chords are ours
    if (chars.length == 0) return NO;
    unichar key = [chars characterAtIndex:0];

    // Emergency global quit — works even when the app has no focus and the
    // cursor has wandered onto an off-screen virtual display. Always first.
    if (key == 'q') {
        std::fprintf(stderr, "\n[quit ⌃⌥Q]\n");
        [NSApp terminate:self];
        return YES;
    }

    rns::Config& cfg = rns::config();
    if (cfg.screens.empty()) return NO;
    int sel = cfg.selectedSlot;
    if (sel < 0 || sel >= (int)cfg.screens.size()) { sel = 0; cfg.selectedSlot = 0; }
    auto& cur = cfg.screens[sel];

    if (key == 'r') {
        if (self.imu) self.imu->recenter();
        std::fprintf(stderr, "\n[recentered]\n");
    } else if (key >= '1' && key <= '9') {
        int idx = key - '1';
        if (idx < (int)cfg.screens.size()) {
            cfg.selectedSlot = idx;
            std::fprintf(stderr, "\n[selected slot %d]\n", idx + 1);
        }
    } else if (key == '[' || key == ']') {
        int n = (int)cfg.screens.size();
        cfg.selectedSlot = (sel + (key == ']' ? 1 : n - 1)) % n;
        std::fprintf(stderr, "\n[selected slot %d]\n", cfg.selectedSlot + 1);
    } else if (key == 'a') {
        cur.azimuthDeg -= 3.0f;
        std::fprintf(stderr, "\n[slot %d azimuth %.0f°]\n", sel+1, cur.azimuthDeg);
    } else if (key == 'd') {
        cur.azimuthDeg += 3.0f;
        std::fprintf(stderr, "\n[slot %d azimuth %.0f°]\n", sel+1, cur.azimuthDeg);
    } else if (key == 'w') {
        cur.elevationDeg += 3.0f;
        std::fprintf(stderr, "\n[slot %d elevation %.0f°]\n", sel+1, cur.elevationDeg);
    } else if (key == 's') {
        cur.elevationDeg -= 3.0f;
        std::fprintf(stderr, "\n[slot %d elevation %.0f°]\n", sel+1, cur.elevationDeg);
    } else if (key == '-') {
        cur.distanceM = std::max(0.3f, cur.distanceM - 0.1f);
        std::fprintf(stderr, "\n[slot %d distance %.2fm]\n", sel+1, cur.distanceM);
    } else if (key == '=' || key == '+') {
        cur.distanceM += 0.1f;
        std::fprintf(stderr, "\n[slot %d distance %.2fm]\n", sel+1, cur.distanceM);
    } else if (key == 'v') {
        cur.visible = !cur.visible;
        std::fprintf(stderr, "\n[slot %d %s]\n", sel+1, cur.visible ? "shown" : "hidden");
    } else if (key == 'y') {
        cfg.yawEnabled = !cfg.yawEnabled;
        std::fprintf(stderr, "\n[yaw tracking %s]\n", cfg.yawEnabled ? "on" : "off");
    } else if (key == 'g') {
        cfg.pitchEnabled = !cfg.pitchEnabled;
        std::fprintf(stderr, "\n[pitch tracking %s]\n", cfg.pitchEnabled ? "on" : "off");
    } else if (key == 'n') {
        [self addScreen];
    } else if (key == 'x') {
        [self removeSelectedScreen];
    } else if (key == 'p') {
        [self pinFrontmostAppToSelected];
    } else if (key == 'o') {
        [self revertSelectedToScreen];
    } else {
        return NO;
    }
    return YES;
}

- (void)setupHotkeys {
    // Global hotkeys need Accessibility (Input Monitoring) trust. Prompt once.
    NSDictionary* opts = @{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES };
    bool trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
    if (!trusted) {
        std::fprintf(stderr,
            "\nGlobal hotkeys need Accessibility access. Grant RayNeoSpatial in\n"
            "System Settings > Privacy & Security > Accessibility, then relaunch.\n"
            "Until then, hotkeys only work while this app is focused.\n\n");
    }

    __weak RNSAppDelegate* weakSelf = self;
    // Local monitor: fires when our app is key; lets us swallow the event.
    self.keyMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                     handler:^NSEvent* (NSEvent* evt) {
        // ⌘Q / Esc quit (only meaningful when focused).
        NSString* c = [[evt charactersIgnoringModifiers] lowercaseString];
        if (((evt.modifierFlags & NSEventModifierFlagCommand) && [c isEqualToString:@"q"])
            || (c.length && [c characterAtIndex:0] == 27)) {
            [NSApp terminate:weakSelf];
            return nil;
        }
        if ([weakSelf handleKeyChars:c modifiers:evt.modifierFlags]) return nil;
        return evt;
    }];
    // Global monitor: fires while OTHER apps are focused (observe-only, can't
    // swallow — fine, our chords are ⌃⌥ so they don't disturb typing).
    self.globalKeyMonitor = [NSEvent
        addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                      handler:^(NSEvent* evt) {
        NSString* c = [[evt charactersIgnoringModifiers] lowercaseString];
        [weakSelf handleKeyChars:c modifiers:evt.modifierFlags];
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

// Add a new screen slot: a virtual monitor placed just right of the current
// rightmost screen. Selects it.
- (void)addScreen {
    rns::Config& cfg = rns::config();
    if (!self.captures || !self.vdm) return;

    // Position: 40° to the right of the current max azimuth (or 0 if none).
    float az = 0.f;
    for (auto& s : cfg.screens) az = std::max(az, s.azimuthDeg);
    az = cfg.screens.empty() ? 0.f : az + 40.f;

    rns::ScreenPose pose{ az, 0.f, 1.7f, 1.2f, 0.675f };
    pose.source = rns::SlotSource::Display;
    pose.visible = true;
    cfg.screens.push_back(pose);
    size_t idx = cfg.screens.size() - 1;

    char nm[64];
    std::snprintf(nm, sizeof(nm), "RayNeo Screen %zu", idx + 1);
    uint32_t did = self.vdm->create(nm, 1920, 1080, 60.0, /*hidpi=*/true);
    [[NSRunLoop currentRunLoop]
        runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];

    rns::CaptureSource cs;
    if (did != 0)
        cs = rns::makeDisplayCapture((__bridge void*)self.mtlDevice, did, 1920, 1080);
    if (!cs.objc)
        cs = rns::makeBuiltinDisplayCapture((__bridge void*)self.mtlDevice, 1920, 1080);

    self.captures->push_back(std::make_unique<rns::CaptureSource>(cs));
    rns::sceneEnsureSlotCount(self.scene, (int)cfg.screens.size());
    if (cs.objc)
        rns::sceneSetCaptureSource(self.scene, (int)idx, self.captures->back().get());

    cfg.selectedSlot = (int)idx;
    std::fprintf(stderr, "\n[added screen %zu at %.0f°]\n", idx + 1, az);
}

// Remove the selected slot: tear down its capture (the virtual display is
// freed in bulk on quit; we just stop capturing it here) and drop it.
- (void)removeSelectedScreen {
    rns::Config& cfg = rns::config();
    if (!self.captures || cfg.screens.empty()) return;
    int sel = cfg.selectedSlot;
    if (sel < 0 || sel >= (int)cfg.screens.size()) return;

    if ((size_t)sel < self.captures->size()) {
        auto& up = (*self.captures)[sel];
        if (up) rns::destroyCapture(*up);
        self.captures->erase(self.captures->begin() + sel);
    }
    cfg.screens.erase(cfg.screens.begin() + sel);

    // Re-point the scene's whole table (indices shifted after the erase).
    rns::sceneEnsureSlotCount(self.scene, (int)cfg.screens.size());
    for (size_t i = 0; i < cfg.screens.size(); ++i) {
        rns::CaptureSource* p = (i < self.captures->size())
                              ? (*self.captures)[i].get() : nullptr;
        rns::sceneSetCaptureSource(self.scene, (int)i, p);
    }
    if (cfg.selectedSlot >= (int)cfg.screens.size())
        cfg.selectedSlot = std::max(0, (int)cfg.screens.size() - 1);
    std::fprintf(stderr, "\n[removed screen %d; %zu left]\n",
                 sel + 1, cfg.screens.size());
}

// Replace the selected slot's content with the window of whatever app is
// frontmost right now (e.g. you're in Terminal, press ⌃⌥P → Terminal pins
// to the selected slot).
- (void)pinFrontmostAppToSelected {
    rns::Config& cfg = rns::config();
    if (!self.captures || cfg.screens.empty()) return;
    int sel = cfg.selectedSlot;
    if (sel < 0 || sel >= (int)cfg.screens.size()) return;

    NSRunningApplication* front =
        [[NSWorkspace sharedWorkspace] frontmostApplication];
    NSString* appName = front.localizedName;
    if (!appName || appName.length == 0
        || [appName isEqualToString:@"RayNeoSpatial"]) {
        std::fprintf(stderr, "\n[pin: no usable frontmost app]\n");
        return;
    }

    cfg.screens[sel].source  = rns::SlotSource::App;
    cfg.screens[sel].appName = std::string([appName UTF8String]);

    rns::CaptureSource cs = rns::makeAppWindowCapture(
        (__bridge void*)self.mtlDevice,
        cfg.screens[sel].appName, 1920, 1080);
    if (!cs.objc) {
        std::fprintf(stderr, "\n[pin: no window for '%s' — is it open?]\n",
                     cfg.screens[sel].appName.c_str());
        return;
    }
    // Swap the slot's capture source.
    if ((size_t)sel < self.captures->size()) {
        auto& up = (*self.captures)[sel];
        if (up) rns::destroyCapture(*up);
        (*self.captures)[sel] = std::make_unique<rns::CaptureSource>(cs);
        rns::sceneSetCaptureSource(self.scene, sel, (*self.captures)[sel].get());
    }
    std::fprintf(stderr, "\n[slot %d pinned to '%s']\n",
                 sel + 1, cfg.screens[sel].appName.c_str());
}

// Turn the selected slot back into a draggable virtual screen.
- (void)revertSelectedToScreen {
    rns::Config& cfg = rns::config();
    if (!self.captures || !self.vdm || cfg.screens.empty()) return;
    int sel = cfg.selectedSlot;
    if (sel < 0 || sel >= (int)cfg.screens.size()) return;

    cfg.screens[sel].source = rns::SlotSource::Display;
    cfg.screens[sel].appName.clear();

    char nm[64];
    std::snprintf(nm, sizeof(nm), "RayNeo Screen %d", sel + 1);
    uint32_t did = self.vdm->create(nm, 1920, 1080, 60.0, /*hidpi=*/true);
    [[NSRunLoop currentRunLoop]
        runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];

    rns::CaptureSource cs;
    if (did != 0)
        cs = rns::makeDisplayCapture((__bridge void*)self.mtlDevice, did, 1920, 1080);
    if (!cs.objc)
        cs = rns::makeBuiltinDisplayCapture((__bridge void*)self.mtlDevice, 1920, 1080);

    if ((size_t)sel < self.captures->size()) {
        auto& up = (*self.captures)[sel];
        if (up) rns::destroyCapture(*up);
        (*self.captures)[sel] = std::make_unique<rns::CaptureSource>(cs);
        if (cs.objc)
            rns::sceneSetCaptureSource(self.scene, sel, (*self.captures)[sel].get());
    }
    std::fprintf(stderr, "\n[slot %d reverted to a virtual screen]\n", sel + 1);
}

- (void)applicationWillTerminate:(NSNotification*)note {
    (void)note;
    // Persist the layout the user arranged this session.
    rns::ConfigStore::save();
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.keyMonitor) {
        [NSEvent removeMonitor:self.keyMonitor];
        self.keyMonitor = nil;
    }
    if (self.globalKeyMonitor) {
        [NSEvent removeMonitor:self.globalKeyMonitor];
        self.globalKeyMonitor = nil;
    }
    rns::Scene sc = self.scene;
    rns::destroyScene(sc);
    self.scene = sc;

    if (self.captures) {
        for (auto& c : *self.captures) if (c) rns::destroyCapture(*c);
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
