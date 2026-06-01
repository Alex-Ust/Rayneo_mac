#include "app.h"
#include "scene.h"
#include "../config.h"
#include "../display/display_locator.h"
#include "../tracking/quat.h"
#include "../virtualdisplay/virtual_display_manager.h"
#include "../capture/capture_source.h"
#include "../config_store.h"
#include "control_panel.h"
#include "control_actions.h"
#include <vector>
#include <memory>
#include <cstring>
#include <cmath>
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <ApplicationServices/ApplicationServices.h>  // AXIsProcessTrustedWithOptions

#include <cstdio>
#include <cstdarg>

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

// Diagnostics for the window-move path. `make runapp` launches via Launch
// Services, so stderr never reaches the terminal — mirror the key lines to a
// file in the project folder so we can read what actually happened.
void moveLog(const char* fmt, ...) {
    char buf[1024];
    va_list ap; va_start(ap, fmt);
    std::vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    std::fprintf(stderr, "%s", buf);
    if (FILE* f = std::fopen(
            "/Users/alex_ust/Desktop/RayNeoSpatial/rns-move.log", "a")) {
        std::fputs(buf, f);
        std::fclose(f);
    }
}

// Read an AXValue point/size attribute (origin/size). Returns a sentinel on
// failure so the caller can tell "not readable" from a real coordinate.
CGPoint axGetPoint(AXUIElementRef el, CFStringRef attr) {
    CGPoint p = {-999999, -999999};
    AXValueRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, (CFTypeRef*)&v) == kAXErrorSuccess
        && v) {
        AXValueGetValue(v, kAXValueTypeCGPoint, &p);
        CFRelease(v);
    }
    return p;
}
CGSize axGetSize(AXUIElementRef el, CFStringRef attr) {
    CGSize s = {0, 0};
    AXValueRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, (CFTypeRef*)&v) == kAXErrorSuccess
        && v) {
        AXValueGetValue(v, kAXValueTypeCGSize, &s);
        CFRelease(v);
    }
    return s;
}

} // namespace

// ----------------------------------------------------------------------------
// AppDelegate. Owns the window/renderer; routes keyDown to imu/quit.

@interface RNSAppDelegate : NSObject <NSApplicationDelegate, RNSControlActions>
@property (nonatomic, strong) NSWindow*  window;
@property (nonatomic, strong) MTKView*   mtkView;
@property (nonatomic, assign) rns::Scene scene;
@property (nonatomic, assign) rns::ControlPanel panel;
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
- (BOOL)moveApp:(NSString*)appName toDisplayID:(uint32_t)displayID
          error:(NSString**)errOut;
- (void)mirrorAppNamed:(NSString*)appName toIndex:(NSInteger)idx;
- (void)setupCapturesFromConfig;
- (void)saveLayout;
- (void)resetLayout;
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

    if (rns::requestScreenRecordingPermission()) {
        self.captures = new std::vector<std::unique_ptr<rns::CaptureSource>>();
        self.vdm = new rns::VirtualDisplayManager();
        [self setupCapturesFromConfig];
    } else {
        std::fprintf(stderr,
            "Screen Recording permission not granted yet. Opening Settings…\n"
            "Enable RayNeoSpatial there, then relaunch.\n");
        // Jump the user straight to the right settings pane.
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:
            @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
        // Still build captures so virtual displays exist; they'll show
        // placeholder colors until permission is granted + relaunch.
        self.captures = new std::vector<std::unique_ptr<rns::CaptureSource>>();
        self.vdm = new rns::VirtualDisplayManager();
        [self setupCapturesFromConfig];
    }

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    [self setupHotkeys];

    // Control panel on the Mac's main display: edit the layout by hand, with a
    // live preview of the glasses render you can drag screens / drop apps onto.
    self.panel = rns::makeControlPanel((__bridge void*)self, self.scene,
                                       self.imu, (__bridge void*)self.mtlDevice);
}

// Control scheme — all chords use ⌃⌥ (Control+Option) so they don't collide
// with normal typing in the app you're actually working in. Returns YES if
// the key was handled (so the local monitor can swallow it).
//
//   ⌃⌥1/2/3   select slot (same again = deselect)   ⌃⌥0  clear selection
//   ⌃⌥A/D     move left / right     ⌃⌥W/S  move up / down (elev)
//   ⌃⌥-/=     move nearer / farther
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
    const int n = (int)cfg.screens.size();
    int sel = cfg.selectedSlot;
    const bool hasSel = (sel >= 0 && sel < n);

    // --- global keys (no slot selection required) ---
    if (key == 'r') {
        if (self.imu) self.imu->recenter();
        std::fprintf(stderr, "\n[recentered]\n");
        return YES;
    }
    if (key == 'n') { [self addScreen]; return YES; }
    if (key == 'y') {
        cfg.yawEnabled = !cfg.yawEnabled;
        std::fprintf(stderr, "\n[yaw tracking %s]\n", cfg.yawEnabled ? "on" : "off");
        return YES;
    }
    if (key == 'g') {
        cfg.pitchEnabled = !cfg.pitchEnabled;
        std::fprintf(stderr, "\n[pitch tracking %s]\n", cfg.pitchEnabled ? "on" : "off");
        return YES;
    }
    // --- selection keys ---
    if (key == '0') {                 // clear selection
        cfg.selectedSlot = -1;
        std::fprintf(stderr, "\n[selection cleared]\n");
        return YES;
    }
    if (key >= '1' && key <= '9') {
        int idx = key - '1';
        if (idx < n) {
            // Pressing the already-selected slot's number deselects it.
            if (idx == sel) {
                cfg.selectedSlot = -1;
                std::fprintf(stderr, "\n[selection cleared]\n");
            } else {
                cfg.selectedSlot = idx;
                std::fprintf(stderr, "\n[selected slot %d]\n", idx + 1);
            }
        }
        return YES;
    }
    if (key == '[' || key == ']') {
        // First press with nothing selected picks slot 0; then it cycles.
        int next = hasSel ? (sel + (key == ']' ? 1 : n - 1)) % n : 0;
        cfg.selectedSlot = next;
        std::fprintf(stderr, "\n[selected slot %d]\n", next + 1);
        return YES;
    }

    // --- per-slot keys: require a selection first ---
    static const char* slotKeys = "adws-=+vxpo";
    if (strchr(slotKeys, (int)key)) {
        if (!hasSel) {
            std::fprintf(stderr,
                "\n[no screen selected — press ⌃⌥1/2/3 (or ⌃⌥]) first]\n");
            return YES;
        }
        auto& cur = cfg.screens[sel];
        if (key == 'a') {
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
        } else if (key == 'x') {
            [self removeSelectedScreen];
        } else if (key == 'p') {
            [self pinFrontmostAppToSelected];
        } else if (key == 'o') {
            [self revertSelectedToScreen];
        }
        return YES;
    }
    return NO;
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
    uint32_t did = self.vdm->create(nm, 1920, 1080, 60.0, /*hidpi=*/false);
    cfg.screens[idx].backingDisplayID = did;
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

// Drag an app onto a screen. Two modes (toggle in the panel):
//  - moveAppOntoScreen ON  : MOVE the app's window onto the slot's virtual
//                            monitor (it leaves the Mac, stays on the screen).
//  - moveAppOntoScreen OFF : MIRROR the window (a copy; original stays on Mac).
- (void)pinAppNamed:(NSString*)appName toIndex:(NSInteger)idx {
    rns::Config& cfg = rns::config();
    if (!self.captures || idx < 0 || idx >= (NSInteger)cfg.screens.size()) return;
    if (!appName || appName.length == 0
        || [appName isEqualToString:@"RayNeoSpatial"]) {
        std::fprintf(stderr, "\n[pin: no usable app]\n");
        return;
    }

    if (cfg.moveAppOntoScreen) {
        uint32_t did = cfg.screens[idx].backingDisplayID;
        NSString* err = nil;
        BOOL ok = (did != 0) && [self moveApp:appName toDisplayID:did error:&err];
        [NSApp activateIgnoringOtherApps:YES];
        if (!ok) {
            NSAlert* a = [[NSAlert alloc] init];
            a.messageText = [NSString stringWithFormat:@"Can't move “%@”", appName];
            a.informativeText = err ?: @"This screen has no virtual monitor.";
            [a addButtonWithTitle:@"OK"];
            [a runModal];
            return;
        }
        cfg.screens[idx].appName = std::string([appName UTF8String]);
        // The app now lives on this slot's virtual monitor. Make sure the quad
        // is capturing THAT monitor (not a leftover mirror/window capture), so
        // the moved window shows up on the screen.
        rns::CaptureSource cs =
            rns::makeDisplayCapture((__bridge void*)self.mtlDevice, did, 1920, 1080);
        if (cs.objc && (size_t)idx < self.captures->size()) {
            auto& up = (*self.captures)[idx];
            if (up) rns::destroyCapture(*up);
            (*self.captures)[idx] = std::make_unique<rns::CaptureSource>(cs);
            rns::sceneSetCaptureSource(self.scene, (int)idx, (*self.captures)[idx].get());
        }
        std::fprintf(stderr, "\n[slot %ld: moved '%s' onto its monitor]\n",
                     (long)idx + 1, appName.UTF8String);
    } else {
        [self mirrorAppNamed:appName toIndex:idx];
    }

    rns::ControlPanel cp = self.panel;
    rns::controlPanelRefresh(cp);
    self.panel = cp;
}

// MIRROR mode: replace slot `idx`'s capture with a live capture of the app's
// window (the window stays on the Mac; the screen shows a copy).
- (void)mirrorAppNamed:(NSString*)appName toIndex:(NSInteger)idx {
    rns::Config& cfg = rns::config();
    std::string needle([appName UTF8String]);
    for (NSRunningApplication* app in
         [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        if ([app.localizedName caseInsensitiveCompare:appName] == NSOrderedSame) {
            [app unhide];
            [app activateWithOptions:NSApplicationActivateAllWindows];
            break;
        }
    }
    [[NSRunLoop currentRunLoop]
        runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.35]];

    rns::CaptureSource cs = rns::makeAppWindowCapture(
        (__bridge void*)self.mtlDevice, needle, 1920, 1080);
    [NSApp activateIgnoringOtherApps:YES];
    if (!cs.objc) {
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = [NSString stringWithFormat:@"Can't show “%@”", appName];
        alert.informativeText = [NSString stringWithFormat:
            @"“%@” has no open window to capture. Open a normal window "
            "(not minimized), then drop it again.", appName];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        return;
    }
    cfg.screens[idx].source  = rns::SlotSource::App;
    cfg.screens[idx].appName = needle;
    if ((size_t)idx < self.captures->size()) {
        auto& up = (*self.captures)[idx];
        if (up) rns::destroyCapture(*up);
        (*self.captures)[idx] = std::make_unique<rns::CaptureSource>(cs);
        rns::sceneSetCaptureSource(self.scene, (int)idx, (*self.captures)[idx].get());
    }
    std::fprintf(stderr, "\n[slot %ld mirroring '%s']\n",
                 (long)idx + 1, needle.c_str());
}

// MOVE mode: relocate the app's frontmost window onto virtual display
// `displayID` and resize to fill. Reads the position back to confirm it stuck.
- (BOOL)moveApp:(NSString*)appName toDisplayID:(uint32_t)displayID
          error:(NSString**)errOut {
    if (!AXIsProcessTrusted()) {
        // Trigger the system prompt that adds RayNeoSpatial to the Accessibility
        // list and opens the right Settings pane — one click to grant, instead
        // of the user hunting for it.
        NSDictionary* opts = @{ (__bridge id)kAXTrustedCheckOptionPrompt : @YES };
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
        if (errOut) *errOut = @"RayNeoSpatial needs Accessibility access to move "
            "windows. I just opened System Settings ▸ Privacy & Security ▸ "
            "Accessibility — switch RayNeoSpatial ON there, then drop the app again.";
        return NO;
    }
    pid_t pid = 0;
    for (NSRunningApplication* app in
         [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        if ([app.localizedName caseInsensitiveCompare:appName] == NSOrderedSame) {
            pid = app.processIdentifier;
            [app unhide];
            [app activateWithOptions:NSApplicationActivateAllWindows];
            break;
        }
    }
    if (pid == 0) {
        if (errOut) *errOut = [NSString stringWithFormat:
            @"“%@” isn't running. Open it first.", appName];
        return NO;
    }
    [[NSRunLoop currentRunLoop]
        runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];

    CGRect b = CGDisplayBounds(displayID);
    moveLog("\n[move] '%s' -> display %u bounds (%.0f,%.0f) %.0fx%.0f\n",
            appName.UTF8String, (unsigned)displayID,
            b.origin.x, b.origin.y, b.size.width, b.size.height);

    AXUIElementRef appEl = AXUIElementCreateApplication(pid);
    if (!appEl) { if (errOut) *errOut = @"Couldn't access the app."; return NO; }

    // Pick the window to move: the app's main window if it has one, else the
    // first standard (titled, non-panel) window, else just the first window.
    // (Moving a random auxiliary/panel window is a common reason move "fails".)
    AXUIElementRef target = NULL;          // owned: CFRelease when done
    AXUIElementRef mainWin = NULL;
    if (AXUIElementCopyAttributeValue(appEl, kAXMainWindowAttribute,
                                      (CFTypeRef*)&mainWin) == kAXErrorSuccess
        && mainWin) {
        target = mainWin;                  // already +1
    }
    CFArrayRef windows = NULL;
    AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute, (CFTypeRef*)&windows);
    CFIndex nwin = windows ? CFArrayGetCount(windows) : 0;
    moveLog("  [move] app has %ld AX window(s); mainWindow=%s\n",
            (long)nwin, target ? "yes" : "no");
    for (CFIndex wi = 0; wi < nwin; ++wi) {
        AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(windows, wi);
        CFStringRef sub = NULL;
        AXUIElementCopyAttributeValue(w, kAXSubroleAttribute, (CFTypeRef*)&sub);
        char subbuf[64] = "?";
        if (sub) CFStringGetCString(sub, subbuf, sizeof(subbuf), kCFStringEncodingUTF8);
        CGPoint wp = axGetPoint(w, kAXPositionAttribute);
        CGSize  ws = axGetSize(w, kAXSizeAttribute);
        moveLog("    win %ld subrole=%s at (%.0f,%.0f) %.0fx%.0f\n",
                (long)wi, subbuf, wp.x, wp.y, ws.width, ws.height);
        if (!target && sub && CFEqual(sub, kAXStandardWindowSubrole))
            target = (AXUIElementRef)CFRetain(w);
        if (sub) CFRelease(sub);
    }
    if (!target && nwin > 0)
        target = (AXUIElementRef)CFRetain(CFArrayGetValueAtIndex(windows, 0));

    BOOL moved = NO;
    BOOL hadWindow = (target != NULL);
    if (target) {
        CGPoint pre = axGetPoint(target, kAXPositionAttribute);
        moveLog("  [move] chosen window pre-move at (%.0f,%.0f)\n", pre.x, pre.y);
        AXUIElementSetAttributeValue(target, kAXMinimizedAttribute, kCFBooleanFalse);
        AXUIElementPerformAction(target, kAXRaiseAction);
        CGPoint pos = b.origin;
        CGSize  size = b.size;
        // Several passes with a settle between them: many apps (Chrome,
        // Electron) apply an AX move asynchronously, so an immediate read-back
        // catches the OLD position and looks like it "snapped back".
        for (int pass = 0; pass < 4 && !moved; ++pass) {
            AXValueRef posV  = AXValueCreate(kAXValueTypeCGPoint, &pos);
            AXValueRef sizeV = AXValueCreate(kAXValueTypeCGSize,  &size);
            AXUIElementSetAttributeValue(target, kAXPositionAttribute, posV);
            AXUIElementSetAttributeValue(target, kAXSizeAttribute, sizeV);
            AXUIElementSetAttributeValue(target, kAXPositionAttribute, posV);
            if (posV)  CFRelease(posV);
            if (sizeV) CFRelease(sizeV);
            [[NSRunLoop currentRunLoop]
                runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
            CGPoint got = axGetPoint(target, kAXPositionAttribute);
            CGSize  gs  = axGetSize(target, kAXSizeAttribute);
            CGPoint center = CGPointMake(got.x + gs.width * 0.5f,
                                         got.y + gs.height * 0.5f);
            BOOL inBounds = CGRectContainsPoint(b, center);
            BOOL nearOrigin = std::abs(got.x - pos.x) < 100
                           && std::abs(got.y - pos.y) < 100;
            moveLog("  [move] pass %d: set (%.0f,%.0f) -> now (%.0f,%.0f) "
                    "%.0fx%.0f center(%.0f,%.0f) inBounds=%d\n",
                    pass, pos.x, pos.y, got.x, got.y, gs.width, gs.height,
                    center.x, center.y, inBounds);
            if (inBounds || nearOrigin) moved = YES;
        }
        CFRelease(target);
    } else if (errOut) {
        *errOut = [NSString stringWithFormat:
            @"“%@” has no movable window. Open a normal window and try again.",
            appName];
    }
    if (windows) CFRelease(windows);
    CFRelease(appEl);
    moveLog("  [move] verdict moved=%d\n", moved);
    if (!moved && hadWindow && errOut) *errOut = [NSString stringWithFormat:
        @"“%@” wouldn't move onto the screen (it snapped back). Make sure it has "
        "a normal window — not full-screen (green button) — then try again.",
        appName];
    return moved;
}

// Hotkey ⌃⌥P: pin whatever app is frontmost to the selected slot.
- (void)pinFrontmostAppToSelected {
    NSRunningApplication* front =
        [[NSWorkspace sharedWorkspace] frontmostApplication];
    [self pinAppNamed:front.localizedName toIndex:rns::config().selectedSlot];
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
    uint32_t did = self.vdm->create(nm, 1920, 1080, 60.0, /*hidpi=*/false);
    cfg.screens[sel].backingDisplayID = did;
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

// Build a capture source for every slot per its config (Display slots spawn
// a virtual monitor; App slots capture the app window). Assumes self.captures
// is empty and self.vdm has no displays yet.
- (void)setupCapturesFromConfig {
    auto& slots = rns::config().screens;
    self.captures->clear();

    // Every slot is a real virtual monitor (always renders, fills the quad).
    std::vector<uint32_t> slotDisplayID(slots.size(), 0);
    for (size_t i = 0; i < slots.size(); ++i) {
        char nm[64];
        std::snprintf(nm, sizeof(nm), "RayNeo Screen %zu", i + 1);
        slotDisplayID[i] = self.vdm->create(nm, 1920, 1080, 60.0, /*hidpi=*/false);
        slots[i].backingDisplayID = slotDisplayID[i];
    }
    if (self.vdm->displays().size() > 0) {
        [[NSRunLoop currentRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
    }

    rns::sceneEnsureSlotCount(self.scene, (int)slots.size());
    for (size_t i = 0; i < slots.size(); ++i) {
        rns::CaptureSource cs;
        if (slotDisplayID[i] != 0) {
            cs = rns::makeDisplayCapture(
                (__bridge void*)self.mtlDevice, slotDisplayID[i], 1920, 1080);
        }
        if (!cs.objc) {
            cs = rns::makeBuiltinDisplayCapture(
                (__bridge void*)self.mtlDevice, 1920, 1080);
        }
        self.captures->push_back(std::make_unique<rns::CaptureSource>(cs));
        if (cs.objc)
            rns::sceneSetCaptureSource(self.scene, (int)i, self.captures->back().get());
    }
}

- (void)saveLayout {
    rns::ConfigStore::save();
}

// Reset to the built-in default layout (3 virtual screens) and rebuild
// captures/displays. Recovers from a bad saved layout (e.g. a black slot).
- (void)resetLayout {
    if (!self.captures || !self.vdm) return;
    for (auto& c : *self.captures) if (c) rns::destroyCapture(*c);
    self.captures->clear();
    self.vdm->teardown();

    rns::config().screens = rns::Config{}.screens;  // default 3 screens
    rns::config().selectedSlot = -1;                // nothing selected
    [self setupCapturesFromConfig];
    std::fprintf(stderr, "\n[layout reset to defaults]\n");
}

// --- RNSControlActions (called from the control panel; index-based) --------
- (void)removeScreenAtIndex:(NSInteger)index {
    rns::config().selectedSlot = (int)index;
    [self removeSelectedScreen];
}
- (void)revertIndexToScreen:(NSInteger)index {
    rns::config().selectedSlot = (int)index;
    [self revertSelectedToScreen];
}
- (void)recenter {
    if (self.imu) self.imu->recenter();
    std::fprintf(stderr, "\n[recentered]\n");
}

- (void)applicationWillTerminate:(NSNotification*)note {
    (void)note;
    // NOTE: layout is saved ONLY when the user clicks Save in the panel —
    // we deliberately do not auto-save on quit.
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.keyMonitor) {
        [NSEvent removeMonitor:self.keyMonitor];
        self.keyMonitor = nil;
    }
    if (self.globalKeyMonitor) {
        [NSEvent removeMonitor:self.globalKeyMonitor];
        self.globalKeyMonitor = nil;
    }
    rns::ControlPanel cp = self.panel;
    rns::destroyControlPanel(cp);
    self.panel = cp;

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
