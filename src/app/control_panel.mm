#include "control_panel.h"
#include "control_actions.h"
#include "../config.h"
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <cstdio>

// Tiny block-as-target shim so AppKit controls can use closures instead of
// per-field selectors + tag bookkeeping.
@interface RNSBlockTarget : NSObject
@property(nonatomic, copy) void (^block)(id sender);
- (instancetype)initWithBlock:(void (^)(id))b;
@end
@implementation RNSBlockTarget
- (instancetype)initWithBlock:(void (^)(id))b { if ((self = [super init])) _block = [b copy]; return self; }
- (void)invoke:(id)sender { if (_block) _block(sender); }
@end

// ---------------------------------------------------------------------------

@interface RNSControlPanel : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSWindow* window;
@property(nonatomic, strong) NSStackView* rootStack;
@property(nonatomic, strong) NSMutableArray* targets; // retain block targets
@property(nonatomic, weak)   id<RNSControlActions> actions;
- (void)rebuild;
@end

@implementation RNSControlPanel

- (instancetype)initWithActions:(id<RNSControlActions>)actions {
    if ((self = [super init])) {
        _actions = actions;
        _targets = [NSMutableArray array];
        [self buildWindow];
        [self rebuild];
    }
    return self;
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 380, 560);
    self.window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.window.title = @"RayNeo Spatial — Screens";
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;

    // Scrollable vertical stack.
    NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:frame];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;

    NSStackView* stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    self.rootStack = stack;

    NSClipView* clip = scroll.contentView;
    scroll.documentView = stack;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:clip.topAnchor],
    ]];

    self.window.contentView = scroll;
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
}

// --- small builders --------------------------------------------------------

- (NSTextField*)label:(NSString*)s bold:(BOOL)bold {
    NSTextField* t = [NSTextField labelWithString:s];
    if (bold) t.font = [NSFont boldSystemFontOfSize:13];
    return t;
}

- (NSButton*)button:(NSString*)title block:(void (^)(id))b {
    RNSBlockTarget* bt = [[RNSBlockTarget alloc] initWithBlock:b];
    [self.targets addObject:bt];
    NSButton* btn = [NSButton buttonWithTitle:title target:bt action:@selector(invoke:)];
    btn.bezelStyle = NSBezelStyleRounded;
    return btn;
}

// A row: [name] [slider] [value]. update(value) writes config + label text.
- (NSStackView*)sliderRow:(NSString*)name
                      min:(double)mn max:(double)mx value:(double)val
                   format:(NSString*)fmt
                   update:(void (^)(double))update {
    NSTextField* nameL = [self label:name bold:NO];
    [nameL.widthAnchor constraintEqualToConstant:64].active = YES;
    NSTextField* valL  = [self label:[NSString stringWithFormat:fmt, val] bold:NO];
    [valL.widthAnchor constraintEqualToConstant:54].active = YES;
    valL.alignment = NSTextAlignmentRight;

    RNSBlockTarget* bt = [[RNSBlockTarget alloc] initWithBlock:^(id sender){
        double v = [(NSSlider*)sender doubleValue];
        valL.stringValue = [NSString stringWithFormat:fmt, v];
        update(v);
    }];
    [self.targets addObject:bt];
    NSSlider* sl = [NSSlider sliderWithValue:val minValue:mn maxValue:mx
                                      target:bt action:@selector(invoke:)];
    sl.continuous = YES;
    [sl.widthAnchor constraintEqualToConstant:200].active = YES;

    NSStackView* row = [NSStackView stackViewWithViews:@[nameL, sl, valL]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    return row;
}

- (NSBox*)separator {
    NSBox* b = [[NSBox alloc] init];
    b.boxType = NSBoxSeparator;
    return b;
}

// --- rebuild from config ---------------------------------------------------

- (void)rebuild {
    for (NSView* v in [self.rootStack.arrangedSubviews copy]) {
        [self.rootStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self.targets removeAllObjects];

    rns::Config& cfg = rns::config();

    // Top bar.
    NSButton* addBtn = [self button:@"＋ Add screen" block:^(id s){
        [self.actions addScreen];
        [self rebuild];
    }];
    NSButton* recBtn = [self button:@"⌖ Recenter" block:^(id s){
        [self.actions recenter];
    }];
    NSStackView* top = [NSStackView stackViewWithViews:@[addBtn, recBtn]];
    top.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    top.spacing = 8;
    [self.rootStack addArrangedSubview:top];
    [self.rootStack addArrangedSubview:[self separator]];

    for (NSInteger i = 0; i < (NSInteger)cfg.screens.size(); ++i) {
        [self addRowsForSlot:i];
        if (i + 1 < (NSInteger)cfg.screens.size())
            [self.rootStack addArrangedSubview:[self separator]];
    }
}

- (void)addRowsForSlot:(NSInteger)i {
    rns::Config& cfg = rns::config();
    rns::ScreenPose& s = cfg.screens[i];
    BOOL isApp = (s.source == rns::SlotSource::App);

    // Header: title + source + remove.
    NSTextField* title = [self label:[NSString stringWithFormat:@"Screen %ld", (long)i+1]
                                bold:YES];
    NSString* srcDesc = isApp
        ? [NSString stringWithFormat:@"app: %s", s.appName.empty() ? "?" : s.appName.c_str()]
        : @"virtual screen";
    NSTextField* src = [self label:srcDesc bold:NO];
    src.textColor = [NSColor secondaryLabelColor];

    NSButton* rm = [self button:@"✕" block:^(id b){
        [self.actions removeScreenAtIndex:i];
        [self rebuild];
    }];
    NSStackView* header = [NSStackView stackViewWithViews:@[title, src, rm]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.spacing = 8;
    [self.rootStack addArrangedSubview:header];

    // Visible + source toggle.
    RNSBlockTarget* vis = [[RNSBlockTarget alloc] initWithBlock:^(id sender){
        rns::config().screens[i].visible = ([(NSButton*)sender state] == NSControlStateValueOn);
    }];
    [self.targets addObject:vis];
    NSButton* visChk = [NSButton checkboxWithTitle:@"Visible" target:vis action:@selector(invoke:)];
    visChk.state = s.visible ? NSControlStateValueOn : NSControlStateValueOff;

    NSButton* srcBtn = isApp
        ? [self button:@"→ Make virtual screen" block:^(id b){
              [self.actions revertIndexToScreen:i]; [self rebuild]; }]
        : [self button:@"→ Pin app…" block:^(id b){
              [self showAppMenuForIndex:i fromButton:(NSButton*)b]; }];

    NSStackView* row2 = [NSStackView stackViewWithViews:@[visChk, srcBtn]];
    row2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row2.spacing = 12;
    [self.rootStack addArrangedSubview:row2];

    // Sliders.
    [self.rootStack addArrangedSubview:
        [self sliderRow:@"Azimuth" min:-90 max:90 value:s.azimuthDeg format:@"%.0f°"
                 update:^(double v){ rns::config().screens[i].azimuthDeg = (float)v; }]];
    [self.rootStack addArrangedSubview:
        [self sliderRow:@"Up/Down" min:-45 max:45 value:s.elevationDeg format:@"%.0f°"
                 update:^(double v){ rns::config().screens[i].elevationDeg = (float)v; }]];
    [self.rootStack addArrangedSubview:
        [self sliderRow:@"Distance" min:0.5 max:4.0 value:s.distanceM format:@"%.2fm"
                 update:^(double v){ rns::config().screens[i].distanceM = (float)v; }]];
    [self.rootStack addArrangedSubview:
        [self sliderRow:@"Size" min:0.5 max:2.5 value:s.widthM format:@"%.2fm"
                 update:^(double v){
                     rns::config().screens[i].widthM = (float)v;
                     rns::config().screens[i].heightM = (float)v * 0.5625f; // 16:9
                 }]];
}

// Popup of currently-running, user-visible apps; pick one to pin to slot i.
- (void)showAppMenuForIndex:(NSInteger)i fromButton:(NSButton*)b {
    NSMenu* menu = [[NSMenu alloc] init];
    NSArray<NSRunningApplication*>* apps =
        [[NSWorkspace sharedWorkspace] runningApplications];
    NSMutableSet* seen = [NSMutableSet set];
    for (NSRunningApplication* app in apps) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        NSString* name = app.localizedName;
        if (!name.length || [name isEqualToString:@"RayNeoSpatial"]) continue;
        if ([seen containsObject:name]) continue;
        [seen addObject:name];

        RNSBlockTarget* bt = [[RNSBlockTarget alloc] initWithBlock:^(id sender){
            [self.actions pinAppNamed:name toIndex:i];
            [self rebuild];
        }];
        [self.targets addObject:bt];
        NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:name
                                                    action:@selector(invoke:)
                                             keyEquivalent:@""];
        it.target = bt;
        if (app.icon) { it.image = app.icon; it.image.size = NSMakeSize(16,16); }
        [menu addItem:it];
    }
    if (menu.itemArray.count == 0)
        [menu addItemWithTitle:@"(no running apps)" action:nil keyEquivalent:@""];
    [menu popUpMenuPositioningItem:nil
                        atLocation:NSMakePoint(0, b.bounds.size.height)
                            inView:b];
}

- (void)windowWillClose:(NSNotification*)n { (void)n; }

@end

// ---------------------------------------------------------------------------

namespace rns {

ControlPanel makeControlPanel(void* actionsDelegate) {
    id<RNSControlActions> act = (__bridge id<RNSControlActions>)actionsDelegate;
    RNSControlPanel* p = [[RNSControlPanel alloc] initWithActions:act];
    ControlPanel out;
    out.objc = (__bridge_retained void*)p;
    return out;
}

void destroyControlPanel(ControlPanel& cp) {
    if (cp.objc) {
        RNSControlPanel* p = (__bridge_transfer RNSControlPanel*)cp.objc;
        [p.window close];
        cp.objc = nullptr;
    }
}

void controlPanelRefresh(ControlPanel& cp) {
    if (!cp.objc) return;
    RNSControlPanel* p = (__bridge RNSControlPanel*)cp.objc;
    [p rebuild];
}

} // namespace rns
