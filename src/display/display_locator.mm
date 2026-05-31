// Objective-C++ implementation. Uses CoreGraphics for the canonical display
// list and AppKit's NSScreen.localizedName for a friendly name (the kernel-
// level name from IOKit is often unhelpful, e.g. "Display"). NSScreen is
// matched to CGDirectDisplayID via the deviceDescription "NSScreenNumber" key.
#include "display_locator.h"
#include "../config.h"
#include <algorithm>
#include <cctype>
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

namespace {

std::string toLower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    return s;
}

std::string localizedNameFor(uint32_t displayID) {
    @autoreleasepool {
        for (NSScreen* screen in [NSScreen screens]) {
            NSNumber* num = [[screen deviceDescription]
                             objectForKey:@"NSScreenNumber"];
            if (num && [num unsignedIntValue] == displayID) {
                NSString* n = [screen localizedName];
                if (n) return std::string([n UTF8String]);
            }
        }
    }
    char buf[32];
    std::snprintf(buf, sizeof(buf), "Display %u", displayID);
    return std::string(buf);
}

} // namespace

namespace rns {

std::vector<DisplayInfo> DisplayLocator::enumerate() {
    std::vector<DisplayInfo> out;
    uint32_t count = 0;
    if (CGGetActiveDisplayList(0, nullptr, &count) != kCGErrorSuccess || count == 0) {
        return out;
    }
    std::vector<CGDirectDisplayID> ids(count);
    if (CGGetActiveDisplayList(count, ids.data(), &count) != kCGErrorSuccess) {
        return out;
    }
    for (CGDirectDisplayID id : ids) {
        DisplayInfo info{};
        info.displayID    = id;
        info.pixelWidth   = static_cast<int>(CGDisplayPixelsWide(id));
        info.pixelHeight  = static_cast<int>(CGDisplayPixelsHigh(id));
        info.isBuiltin    = CGDisplayIsBuiltin(id) != 0;
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(id);
        info.refreshHz    = mode ? CGDisplayModeGetRefreshRate(mode) : 0.0;
        if (mode) CGDisplayModeRelease(mode);
        CGRect b = CGDisplayBounds(id);
        info.boundsX = b.origin.x; info.boundsY = b.origin.y;
        info.boundsW = b.size.width; info.boundsH = b.size.height;
        info.name = localizedNameFor(id);
        out.push_back(std::move(info));
    }
    return out;
}

DisplayInfo DisplayLocator::findGlasses() {
    const Config& cfg = config();
    auto all = enumerate();

    for (const auto& rawHint : cfg.glassesNameHints) {
        std::string hint = toLower(rawHint);
        if (hint.empty()) continue;
        for (const auto& d : all) {
            if (toLower(d.name).find(hint) != std::string::npos) return d;
        }
    }
    for (const auto& d : all) {
        if (!d.isBuiltin
            && d.pixelWidth == cfg.glassesWidth
            && d.pixelHeight == cfg.glassesHeight) return d;
    }
    for (const auto& d : all) {
        if (!d.isBuiltin) return d;
    }
    return DisplayInfo{}; // displayID == 0 sentinel
}

} // namespace rns
