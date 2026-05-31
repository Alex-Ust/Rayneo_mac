#include "app.h"
#include "renderer.h"
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
@property (nonatomic, assign) rns::Renderer renderer;
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

    rns::Renderer r = rns::makeRenderer((__bridge void*)mtkv, self.imu);
    self.renderer = r;

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    // Global-ish key handler. Local monitor sees keys when our app is key.
    __weak RNSAppDelegate* weakSelf = self;
    self.keyMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                     handler:^NSEvent* (NSEvent* evt) {
        NSString* chars = [[evt charactersIgnoringModifiers] lowercaseString];
        NSEventModifierFlags mods = [evt modifierFlags];
        bool cmd = (mods & NSEventModifierFlagCommand) != 0;
        bool ctrl = (mods & NSEventModifierFlagControl) != 0;
        bool opt = (mods & NSEventModifierFlagOption) != 0;
        bool ctrlOpt = ctrl && opt;
        unichar key = [chars length] > 0 ? [chars characterAtIndex:0] : 0;

        if ((cmd && key == 'q') || key == 27 /*Esc*/) {
            [NSApp terminate:weakSelf];
            return nil;
        }
        // Ctrl+Opt+R: recenter
        if (ctrlOpt && key == 'r') {
            if (weakSelf.imu) weakSelf.imu->recenter();
            std::fprintf(stderr, "\n[recentered]\n");
            return nil;
        }
        // Plain 'r' also recenters — convenient when no modifier keys are
        // mapped through the glasses' HID.
        if (key == 'r') {
            if (weakSelf.imu) weakSelf.imu->recenter();
            std::fprintf(stderr, "\n[recentered]\n");
            return nil;
        }
        return evt;
    }];
}

- (void)applicationWillTerminate:(NSNotification*)note {
    (void)note;
    if (self.keyMonitor) {
        [NSEvent removeMonitor:self.keyMonitor];
        self.keyMonitor = nil;
    }
    rns::Renderer r = self.renderer;
    rns::destroyRenderer(r);
    self.renderer = r;
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
