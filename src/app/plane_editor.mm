#include "plane_editor.h"
#include "control_actions.h"
#include "../config.h"
#include "../tracking/quat.h"
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cmath>

namespace {
constexpr float kAzMax  = 90.0f;   // horizontal axis spans ±90°
constexpr float kElMax  = 45.0f;   // vertical axis spans ±45°
constexpr float kMargin = 20.0f;

// Per-slot fill hues (cyan / orange / magenta, then spread) matching the
// procedural colors used on the glasses so a slot is recognizable in both.
NSColor* slotColor(size_t i, float alpha) {
    float hue = (i == 0) ? 0.52f : (i == 1) ? 0.08f : (i == 2) ? 0.85f
                                                               : std::fmod(i * 0.31f, 1.0f);
    return [NSColor colorWithHue:hue saturation:0.55 brightness:0.95 alpha:alpha];
}
}

@implementation RNSPlaneEditorView {
    NSTimer* _redraw;
    CGFloat  _grabDX, _grabDY;   // cursor offset from the dragged screen center
}

- (instancetype)initWithActions:(id<RNSControlActions>)actions {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, 340, 200)])) {
        _actions = actions;
        self.wantsLayer = YES;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [NSColor colorWithWhite:0.3 alpha:1.0].CGColor;
        self.layer.cornerRadius = 4.0;
        [self registerForDraggedTypes:@[NSPasteboardTypeString]];

        __weak RNSPlaneEditorView* weak = self;
        _redraw = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0
                                                  repeats:YES
                                                    block:^(NSTimer* t){ (void)t;
            [weak setNeedsDisplay:YES]; }];
    }
    return self;
}

- (void)dealloc { [_redraw invalidate]; }

- (BOOL)isFlipped { return NO; }      // AppKit default: origin bottom-left, y up

// --- coordinate mapping -----------------------------------------------------

- (CGFloat)kx { return (self.bounds.size.width  * 0.5f - kMargin) / kAzMax; }
- (CGFloat)ky { return (self.bounds.size.height * 0.5f - kMargin) / kElMax; }
- (NSPoint)centerForAz:(float)az el:(float)el {
    return NSMakePoint(self.bounds.size.width  * 0.5f + az * [self kx],
                       self.bounds.size.height * 0.5f + el * [self ky]);
}
- (NSRect)rectForScreen:(const rns::ScreenPose&)s {
    NSPoint c = [self centerForAz:s.azimuthDeg el:s.elevationDeg];
    float awDeg = rns::radToDeg(2.0f * std::atan((s.widthM  * 0.5f) / s.distanceM));
    float ahDeg = rns::radToDeg(2.0f * std::atan((s.heightM * 0.5f) / s.distanceM));
    CGFloat w = std::max<CGFloat>(28, awDeg * [self kx]);
    CGFloat h = std::max<CGFloat>(18, ahDeg * [self ky]);
    return NSMakeRect(c.x - w * 0.5f, c.y - h * 0.5f, w, h);
}

// Topmost visible screen under a point, or -1.
- (NSInteger)slotAtPoint:(NSPoint)p {
    const auto& screens = rns::config().screens;
    for (NSInteger i = (NSInteger)screens.size() - 1; i >= 0; --i) {
        if (!screens[i].visible) continue;
        if (NSPointInRect(p, [self rectForScreen:screens[i]])) return i;
    }
    return -1;
}

// Like slotAtPoint: but never misses — falls back to the nearest visible
// screen by center distance. Used for app drops so a slightly-off drop still
// lands on a screen.
- (NSInteger)nearestSlotAtPoint:(NSPoint)p {
    NSInteger hit = [self slotAtPoint:p];
    if (hit >= 0) return hit;
    const auto& screens = rns::config().screens;
    NSInteger best = -1; CGFloat bestD = 1e18;
    for (size_t i = 0; i < screens.size(); ++i) {
        if (!screens[i].visible) continue;
        NSPoint c = [self centerForAz:screens[i].azimuthDeg el:screens[i].elevationDeg];
        CGFloat d = (c.x - p.x) * (c.x - p.x) + (c.y - p.y) * (c.y - p.y);
        if (d < bestD) { bestD = d; best = (NSInteger)i; }
    }
    return best;
}

// --- drawing ----------------------------------------------------------------

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect b = self.bounds;
    [[NSColor colorWithWhite:0.10 alpha:1.0] setFill];
    NSRectFill(b);

    CGFloat cx = b.size.width * 0.5f, cy = b.size.height * 0.5f;

    // Grid lines.
    [[NSColor colorWithWhite:0.22 alpha:1.0] setStroke];
    NSBezierPath* grid = [NSBezierPath bezierPath];
    grid.lineWidth = 1.0;
    for (float a = -90; a <= 90.0f; a += 45.0f) {
        NSPoint c = [self centerForAz:a el:0];
        [grid moveToPoint:NSMakePoint(c.x, kMargin)];
        [grid lineToPoint:NSMakePoint(c.x, b.size.height - kMargin)];
    }
    for (float e = -45; e <= 45.0f; e += 22.5f) {
        NSPoint c = [self centerForAz:0 el:e];
        [grid moveToPoint:NSMakePoint(kMargin, c.y)];
        [grid lineToPoint:NSMakePoint(b.size.width - kMargin, c.y)];
    }
    [grid stroke];

    // Center crosshair (straight ahead).
    [[NSColor colorWithWhite:0.4 alpha:1.0] setStroke];
    NSBezierPath* cross = [NSBezierPath bezierPath];
    cross.lineWidth = 1.0;
    [cross moveToPoint:NSMakePoint(cx, kMargin)];
    [cross lineToPoint:NSMakePoint(cx, b.size.height - kMargin)];
    [cross moveToPoint:NSMakePoint(kMargin, cy)];
    [cross lineToPoint:NSMakePoint(b.size.width - kMargin, cy)];
    [cross stroke];

    NSDictionary* axisAttr = @{
        NSFontAttributeName: [NSFont systemFontOfSize:9],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.5 alpha:1.0] };
    [@"L" drawAtPoint:NSMakePoint(kMargin, cy + 2) withAttributes:axisAttr];
    [@"R" drawAtPoint:NSMakePoint(b.size.width - kMargin - 8, cy + 2) withAttributes:axisAttr];
    [@"up"   drawAtPoint:NSMakePoint(cx + 3, b.size.height - kMargin - 12) withAttributes:axisAttr];
    [@"down" drawAtPoint:NSMakePoint(cx + 3, kMargin + 2) withAttributes:axisAttr];

    // Screens.
    const auto& screens = rns::config().screens;
    int sel = rns::config().selectedSlot;
    for (size_t i = 0; i < screens.size(); ++i) {
        const auto& s = screens[i];
        if (!s.visible) continue;
        NSRect r = [self rectForScreen:s];
        NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:r xRadius:4 yRadius:4];
        [slotColor(i, 0.85f) setFill];
        [path fill];
        BOOL isSel = ((int)i == sel);
        [(isSel ? [NSColor cyanColor] : [NSColor colorWithWhite:0.85 alpha:1.0]) setStroke];
        path.lineWidth = isSel ? 3.0 : 1.0;
        [path stroke];

        NSString* label = !s.appName.empty()
            ? [NSString stringWithUTF8String:s.appName.c_str()]
            : [NSString stringWithFormat:@"Screen %zu", i + 1];
        NSMutableParagraphStyle* ps = [NSMutableParagraphStyle new];
        ps.alignment = NSTextAlignmentCenter;
        ps.lineBreakMode = NSLineBreakByTruncatingTail;
        NSDictionary* attr = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:11],
            NSForegroundColorAttributeName: [NSColor colorWithWhite:0.1 alpha:1.0],
            NSParagraphStyleAttributeName: ps };
        NSRect tr = NSInsetRect(r, 3, 0);
        tr.origin.y = r.origin.y + (r.size.height - 14) * 0.5f;
        tr.size.height = 14;
        [label drawInRect:tr withAttributes:attr];
    }
}

// --- mouse: select + move ---------------------------------------------------

- (void)mouseDown:(NSEvent*)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger idx = [self slotAtPoint:p];
    rns::config().selectedSlot = (int)idx;       // -1 (empty click) deselects
    if (idx >= 0) {
        NSPoint c = [self centerForAz:rns::config().screens[idx].azimuthDeg
                                   el:rns::config().screens[idx].elevationDeg];
        _grabDX = p.x - c.x;
        _grabDY = p.y - c.y;
    }
    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent*)e {
    rns::Config& cfg = rns::config();
    int sel = cfg.selectedSlot;
    if (sel < 0 || sel >= (int)cfg.screens.size()) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    CGFloat ncx = p.x - _grabDX, ncy = p.y - _grabDY;
    float az = (float)((ncx - self.bounds.size.width  * 0.5f) / [self kx]);
    float el = (float)((ncy - self.bounds.size.height * 0.5f) / [self ky]);
    cfg.screens[sel].azimuthDeg   = std::max(-kAzMax, std::min(kAzMax, az));
    cfg.screens[sel].elevationDeg = std::max(-kElMax, std::min(kElMax, el));
    [self setNeedsDisplay:YES];
}

- (void)scrollWheel:(NSEvent*)e {
    rns::Config& cfg = rns::config();
    int sel = cfg.selectedSlot;
    if (sel < 0 || sel >= (int)cfg.screens.size()) return;
    float d = cfg.screens[sel].distanceM - (float)e.scrollingDeltaY * 0.01f;
    cfg.screens[sel].distanceM = std::max(0.3f, std::min(6.0f, d));
    [self setNeedsDisplay:YES];
}

// --- drag destination: drop an app onto a screen ----------------------------

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { (void)sender; return NSDragOperationCopy; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender { (void)sender; return NSDragOperationCopy; }

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSString* name = [sender.draggingPasteboard stringForType:NSPasteboardTypeString];
    if (!name.length) return NO;
    NSPoint p = [self convertPoint:sender.draggingLocation fromView:nil];
    NSInteger idx = [self nearestSlotAtPoint:p];
    if (idx < 0) return NO;
    rns::config().selectedSlot = (int)idx;
    [self.actions pinAppNamed:name toIndex:idx];
    [self setNeedsDisplay:YES];
    return YES;
}

@end
