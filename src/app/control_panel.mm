#include "control_panel.h"
#include "control_actions.h"
#include "preview_view.h"
#include "plane_editor.h"
#include "../config.h"
#include "../audio/audio_output.h"
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <vector>

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
// A draggable app tile (icon + name). Dragging it carries the app's name as a
// string on the pasteboard; dropping it on the preview pins that app to the
// screen under the cursor.
@interface RNSAppDragItem : NSView <NSDraggingSource>
@property(nonatomic, copy)   NSString* appName;
@property(nonatomic, strong) NSImage*  appIcon;
@end
@implementation RNSAppDragItem
- (instancetype)initWithName:(NSString*)name icon:(NSImage*)icon {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, 56, 52)])) {
        _appName = [name copy];
        _appIcon = icon;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self.widthAnchor constraintEqualToConstant:56].active = YES;
        [self.heightAnchor constraintEqualToConstant:52].active = YES;

        NSImageView* iv = [NSImageView imageViewWithImage:
            icon ?: [NSImage imageWithSystemSymbolName:@"app" accessibilityDescription:nil]];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:iv];
        NSTextField* lbl = [NSTextField labelWithString:name];
        lbl.font = [NSFont systemFontOfSize:9];
        lbl.alignment = NSTextAlignmentCenter;
        lbl.lineBreakMode = NSLineBreakByTruncatingTail;
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        lbl.toolTip = name;
        [self addSubview:lbl];
        [NSLayoutConstraint activateConstraints:@[
            [iv.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [iv.topAnchor constraintEqualToAnchor:self.topAnchor],
            [iv.widthAnchor constraintEqualToConstant:32],
            [iv.heightAnchor constraintEqualToConstant:32],
            [lbl.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [lbl.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [lbl.topAnchor constraintEqualToAnchor:iv.bottomAnchor constant:1],
        ]];
        self.toolTip = name;
    }
    return self;
}
// Swallow hits from the icon/label subviews so the whole tile is the drag
// handle (otherwise the NSImageView ate mouseDown and dragging never started).
- (NSView*)hitTest:(NSPoint)point {
    NSView* hit = [super hitTest:point];
    return hit ? self : nil;
}
- (void)mouseDown:(NSEvent*)event {
    NSPasteboardItem* pbItem = [[NSPasteboardItem alloc] init];
    [pbItem setString:self.appName forType:NSPasteboardTypeString];
    NSDraggingItem* di = [[NSDraggingItem alloc] initWithPasteboardWriter:pbItem];
    NSImage* img = self.appIcon ?: [NSImage imageWithSystemSymbolName:@"app"
                                              accessibilityDescription:nil];
    [di setDraggingFrame:self.bounds contents:img];
    [self beginDraggingSessionWithItems:@[di] event:event source:self];
}
- (NSDragOperation)draggingSession:(NSDraggingSession*)session
            sourceOperationMaskForDraggingContext:(NSDraggingContext)ctx {
    (void)session; (void)ctx;
    return NSDragOperationCopy;
}
@end

// ---------------------------------------------------------------------------

@interface RNSControlPanel : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSWindow* window;
@property(nonatomic, strong) NSStackView* rootStack;
@property(nonatomic, strong) NSMutableArray* targets; // retain block targets
@property(nonatomic, weak)   id<RNSControlActions> actions;
@property(nonatomic, assign) rns::Scene scene;
@property(nonatomic, assign) rns::ImuService* imu;
@property(nonatomic, assign) id<MTLDevice> device;
@property(nonatomic, strong) RNSPreviewView* preview;
@property(nonatomic, strong) RNSPlaneEditorView* planeEditor;
@property(nonatomic, strong) NSStackView* appsStrip;
- (void)rebuild;
- (void)buildAppsStrip;
- (void)selectMode:(NSInteger)mode;   // 0 = plane editor, 1 = live mirror
@end

@implementation RNSControlPanel

- (instancetype)initWithActions:(id<RNSControlActions>)actions
                          scene:(rns::Scene)scene
                            imu:(rns::ImuService*)imu
                         device:(id<MTLDevice>)device {
    if ((self = [super init])) {
        _actions = actions;
        _scene   = scene;
        _imu     = imu;
        _device  = device;
        _targets = [NSMutableArray array];
        [self buildWindow];
        [self rebuild];
    }
    return self;
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 380, 720);
    self.window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.window.title = @"RayNeo Spatial — Screens";
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;

    NSView* content = [[NSView alloc] initWithFrame:frame];

    // --- Mode switch: 2D plane editor (default) vs live 3D mirror -----------
    RNSBlockTarget* segT = [[RNSBlockTarget alloc] initWithBlock:^(id sender){
        [self selectMode:[(NSSegmentedControl*)sender selectedSegment]];
    }];
    [self.targets addObject:segT];
    NSSegmentedControl* seg = [NSSegmentedControl
        segmentedControlWithLabels:@[@"Plane editor", @"Live mirror"]
                      trackingMode:NSSegmentSwitchTrackingSelectOne
                            target:segT action:@selector(invoke:)];
    seg.selectedSegment = 0;
    seg.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:seg];

    // 2D plane editor — drag rectangles, drop apps. Reliable hand-editing.
    self.planeEditor = [[RNSPlaneEditorView alloc] initWithActions:self.actions];
    self.planeEditor.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.planeEditor];

    // Live 3D mirror of the glasses render (overlaps the plane editor; the mode
    // switch toggles which is visible).
    self.preview = [[RNSPreviewView alloc] initWithScene:self.scene
                                                     imu:self.imu
                                                  device:self.device
                                                 actions:self.actions];
    self.preview.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.preview];

    // Follow-head toggle (mirror only) + refresh-apps button.
    RNSBlockTarget* followT = [[RNSBlockTarget alloc] initWithBlock:^(id sender){
        self.preview.followHead = ([(NSButton*)sender state] == NSControlStateValueOn);
    }];
    [self.targets addObject:followT];
    NSButton* followChk = [NSButton checkboxWithTitle:@"Follow head (mirror only)"
                                               target:followT action:@selector(invoke:)];
    followChk.state = NSControlStateValueOff;
    followChk.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:followChk];

    NSButton* appsRefresh = [self button:@"↻ apps" block:^(id s){ [self buildAppsStrip]; }];
    appsRefresh.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:appsRefresh];

    NSTextField* hint = [self label:@"drag an app ↓ onto a screen ↑" bold:NO];
    hint.textColor = [NSColor secondaryLabelColor];
    hint.font = [NSFont systemFontOfSize:10];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:hint];

    // Horizontal scroller of draggable running-app tiles.
    NSScrollView* appsScroll = [[NSScrollView alloc] init];
    appsScroll.hasHorizontalScroller = YES;
    appsScroll.hasVerticalScroller = NO;
    appsScroll.drawsBackground = NO;
    appsScroll.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView* strip = [[NSStackView alloc] init];
    strip.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    strip.alignment = NSLayoutAttributeTop;
    strip.spacing = 6;
    strip.edgeInsets = NSEdgeInsetsMake(2, 4, 2, 4);
    strip.translatesAutoresizingMaskIntoConstraints = NO;
    self.appsStrip = strip;
    appsScroll.documentView = strip;
    [NSLayoutConstraint activateConstraints:@[
        [strip.leadingAnchor constraintEqualToAnchor:appsScroll.contentView.leadingAnchor],
        [strip.topAnchor constraintEqualToAnchor:appsScroll.contentView.topAnchor],
        [strip.bottomAnchor constraintEqualToAnchor:appsScroll.contentView.bottomAnchor],
    ]];
    [content addSubview:appsScroll];

    // --- Scrollable controls (existing rows) --------------------------------
    NSScrollView* scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView* stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    self.rootStack = stack;

    [content addSubview:scroll];
    NSClipView* clip = scroll.contentView;
    scroll.documentView = stack;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:clip.topAnchor],
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [seg.topAnchor constraintEqualToAnchor:content.topAnchor constant:8],
        [seg.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:8],
        [seg.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-8],

        // Plane editor and mirror share the same slot (toggled visible).
        [self.planeEditor.topAnchor constraintEqualToAnchor:seg.bottomAnchor constant:8],
        [self.planeEditor.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:8],
        [self.planeEditor.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-8],
        [self.planeEditor.heightAnchor constraintEqualToConstant:200],

        [self.preview.topAnchor constraintEqualToAnchor:self.planeEditor.topAnchor],
        [self.preview.leadingAnchor constraintEqualToAnchor:self.planeEditor.leadingAnchor],
        [self.preview.trailingAnchor constraintEqualToAnchor:self.planeEditor.trailingAnchor],
        [self.preview.heightAnchor constraintEqualToConstant:200],

        [followChk.topAnchor constraintEqualToAnchor:self.planeEditor.bottomAnchor constant:6],
        [followChk.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:8],
        [appsRefresh.centerYAnchor constraintEqualToAnchor:followChk.centerYAnchor],
        [appsRefresh.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-8],

        [hint.topAnchor constraintEqualToAnchor:followChk.bottomAnchor constant:4],
        [hint.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:8],

        [appsScroll.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:2],
        [appsScroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:4],
        [appsScroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-4],
        [appsScroll.heightAnchor constraintEqualToConstant:64],

        [scroll.topAnchor constraintEqualToAnchor:appsScroll.bottomAnchor constant:6],
        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    ]];

    self.window.contentView = content;
    [self buildAppsStrip];
    [self selectMode:0];           // default to the reliable plane editor
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
}

// Toggle between the 2D plane editor (0) and the live 3D mirror (1). We only
// hide the inactive view (never pause its MTKView) — toggling paused on a
// previously-hidden MTKView doesn't reliably resume its draw loop on all GPUs,
// which left the mirror blank. A hidden MTKView produces no drawable, so it
// costs nothing while hidden anyway.
- (void)selectMode:(NSInteger)mode {
    BOOL mirror = (mode == 1);
    self.planeEditor.hidden = mirror;
    self.preview.hidden     = !mirror;
    if (mirror) [self.preview setNeedsDisplay:YES];
}

// Fill the apps strip with draggable tiles for currently-running apps.
- (void)buildAppsStrip {
    for (NSView* v in [self.appsStrip.arrangedSubviews copy]) {
        [self.appsStrip removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSArray<NSRunningApplication*>* apps =
        [[NSWorkspace sharedWorkspace] runningApplications];
    NSMutableSet* seen = [NSMutableSet set];
    for (NSRunningApplication* app in apps) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        NSString* name = app.localizedName;
        if (!name.length || [name isEqualToString:@"RayNeoSpatial"]) continue;
        if ([seen containsObject:name]) continue;
        [seen addObject:name];
        NSImage* icon = app.icon;
        if (icon) icon.size = NSMakeSize(32, 32);
        RNSAppDragItem* tile = [[RNSAppDragItem alloc] initWithName:name icon:icon];
        [self.appsStrip addArrangedSubview:tile];
    }
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

// Sound-output picker: a popup of all output devices (built-in, headphones,
// glasses speakers…) + a refresh button. Selecting one switches the system
// default output.
- (NSStackView*)audioRow {
    NSTextField* lbl = [self label:@"Sound" bold:NO];
    [lbl.widthAnchor constraintEqualToConstant:48].active = YES;

    NSPopUpButton* pop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [pop.widthAnchor constraintEqualToConstant:210].active = YES;

    // Capture the device-id list so the action can map selection -> device.
    auto devices = std::make_shared<std::vector<rns::AudioDevice>>(
        rns::listOutputDevices());
    NSInteger selectIdx = -1;
    for (size_t i = 0; i < devices->size(); ++i) {
        const auto& d = (*devices)[i];
        NSString* title = [NSString stringWithUTF8String:d.name.c_str()];
        [pop addItemWithTitle:title];
        if (d.isDefault) selectIdx = (NSInteger)i;
    }
    if (devices->empty()) [pop addItemWithTitle:@"(no output devices)"];
    if (selectIdx >= 0) [pop selectItemAtIndex:selectIdx];

    RNSBlockTarget* bt = [[RNSBlockTarget alloc] initWithBlock:^(id sender){
        NSInteger idx = [(NSPopUpButton*)sender indexOfSelectedItem];
        if (idx >= 0 && (size_t)idx < devices->size()) {
            rns::setDefaultOutputDevice((*devices)[idx].id);
            std::fprintf(stderr, "\n[audio -> %s]\n", (*devices)[idx].name.c_str());
        }
    }];
    [self.targets addObject:bt];
    pop.target = bt;
    pop.action = @selector(invoke:);

    NSButton* refresh = [self button:@"↻" block:^(id s){ [self rebuild]; }];

    NSStackView* row = [NSStackView stackViewWithViews:@[lbl, pop, refresh]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    return row;
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
    NSButton* deselBtn = [self button:@"○ Deselect" block:^(id s){
        rns::config().selectedSlot = -1;  // clears the cyan border in glasses
    }];
    NSStackView* top = [NSStackView stackViewWithViews:@[addBtn, recBtn, deselBtn]];
    top.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    top.spacing = 8;
    [self.rootStack addArrangedSubview:top];

    // Save / Reset row — layout is only persisted when you click Save.
    NSButton* saveBtn = [self button:@"💾 Save layout" block:^(id s){
        [self.actions saveLayout];
    }];
    NSButton* resetBtn = [self button:@"↺ Reset to defaults" block:^(id s){
        [self.actions resetLayout];
        [self rebuild];
    }];
    NSStackView* top2 = [NSStackView stackViewWithViews:@[saveBtn, resetBtn]];
    top2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    top2.spacing = 8;
    [self.rootStack addArrangedSubview:top2];

    // Audio output: choose where system sound goes (Mac speakers/headphones
    // or the glasses' built-in speakers when connected).
    [self.rootStack addArrangedSubview:[self audioRow]];

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

    // Sliders. Each edit also selects this slot so the cyan border in the
    // glasses shows which screen you're moving.
    [self.rootStack addArrangedSubview:
        [self sliderRow:@"Azimuth" min:-90 max:90 value:s.azimuthDeg format:@"%.0f°"
                 update:^(double v){ rns::config().selectedSlot=(int)i;
                                     rns::config().screens[i].azimuthDeg = (float)v; }]];
    [self.rootStack addArrangedSubview:
        [self sliderRow:@"Up/Down" min:-45 max:45 value:s.elevationDeg format:@"%.0f°"
                 update:^(double v){ rns::config().selectedSlot=(int)i;
                                     rns::config().screens[i].elevationDeg = (float)v; }]];
    [self.rootStack addArrangedSubview:
        [self sliderRow:@"Distance" min:0.5 max:4.0 value:s.distanceM format:@"%.2fm"
                 update:^(double v){ rns::config().selectedSlot=(int)i;
                                     rns::config().screens[i].distanceM = (float)v; }]];
    [self.rootStack addArrangedSubview:
        [self sliderRow:@"Size" min:0.5 max:2.5 value:s.widthM format:@"%.2fm"
                 update:^(double v){
                     rns::config().selectedSlot=(int)i;
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

ControlPanel makeControlPanel(void* actionsDelegate, Scene scene,
                              ImuService* imu, void* device) {
    id<RNSControlActions> act = (__bridge id<RNSControlActions>)actionsDelegate;
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    RNSControlPanel* p = [[RNSControlPanel alloc] initWithActions:act
                                                            scene:scene
                                                              imu:imu
                                                           device:dev];
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
