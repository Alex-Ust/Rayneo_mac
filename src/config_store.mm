#include "config_store.h"
#include "config.h"
#import <Foundation/Foundation.h>
#include <cstdio>

namespace {

NSString* layoutPath() {
    NSArray* dirs = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString* base = dirs.firstObject ?: NSTemporaryDirectory();
    NSString* dir = [base stringByAppendingPathComponent:@"RayNeoSpatial"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [dir stringByAppendingPathComponent:@"layout.plist"];
}

} // namespace

namespace rns {

bool ConfigStore::load() {
    @autoreleasepool {
        NSString* path = layoutPath();
        NSDictionary* root = [NSDictionary dictionaryWithContentsOfFile:path];
        if (!root) return false;
        NSArray* arr = root[@"screens"];
        if (![arr isKindOfClass:[NSArray class]] || arr.count == 0) return false;

        Config& cfg = config();
        cfg.screens.clear();
        for (NSDictionary* d in arr) {
            ScreenPose s{};
            s.azimuthDeg   = [d[@"azimuthDeg"]   floatValue];
            s.elevationDeg = [d[@"elevationDeg"] floatValue];
            s.distanceM    = [d[@"distanceM"]    floatValue];
            s.widthM       = [d[@"widthM"]       floatValue];
            s.heightM      = [d[@"heightM"]      floatValue];
            s.visible      = d[@"visible"] ? [d[@"visible"] boolValue] : true;
            NSString* app  = d[@"appName"];
            if (app.length > 0) {
                s.source  = SlotSource::App;
                s.appName = std::string([app UTF8String]);
            } else {
                s.source = SlotSource::Display;
            }
            // Guard against a corrupt/zeroed entry.
            if (s.distanceM < 0.1f) s.distanceM = 1.7f;
            if (s.widthM    < 0.1f) s.widthM    = 1.2f;
            if (s.heightM   < 0.1f) s.heightM   = 0.675f;
            cfg.screens.push_back(s);
        }
        // selectedSlot is intentionally NOT restored — start with nothing
        // selected (no highlight) until the user picks a screen.
        cfg.selectedSlot = -1;
        std::fprintf(stderr, "Loaded layout: %zu screen(s) from %s\n",
                     cfg.screens.size(), path.UTF8String);
        return true;
    }
}

bool ConfigStore::save() {
    @autoreleasepool {
        Config& cfg = config();
        NSMutableArray* arr = [NSMutableArray array];
        for (const auto& s : cfg.screens) {
            [arr addObject:@{
                @"azimuthDeg":   @(s.azimuthDeg),
                @"elevationDeg": @(s.elevationDeg),
                @"distanceM":    @(s.distanceM),
                @"widthM":       @(s.widthM),
                @"heightM":      @(s.heightM),
                @"visible":      @(s.visible),
                @"appName":      [NSString stringWithUTF8String:
                                    s.source == SlotSource::App
                                        ? s.appName.c_str() : ""],
            }];
        }
        NSDictionary* root = @{
            @"screens": arr,
            @"selectedSlot": @(cfg.selectedSlot),
        };
        NSString* path = layoutPath();
        BOOL ok = [root writeToFile:path atomically:YES];
        std::fprintf(stderr, "%s layout: %zu screen(s) -> %s\n",
                     ok ? "Saved" : "FAILED to save",
                     cfg.screens.size(), path.UTF8String);
        return ok;
    }
}

} // namespace rns
