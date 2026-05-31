#include "virtual_display_manager.h"
#include "CGVirtualDisplay.h"
#import <Foundation/Foundation.h>
#include <cstdio>

namespace rns {

VirtualDisplayManager::~VirtualDisplayManager() { teardown(); }

uint32_t VirtualDisplayManager::create(const std::string& name,
                                       int width, int height,
                                       double refreshHz, bool hidpi) {
    @autoreleasepool {
        if (!objcHolders_) {
            objcHolders_ = (__bridge_retained void*)[NSMutableArray array];
        }
        NSMutableArray* holders = (__bridge NSMutableArray*)objcHolders_;

        Class descClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class setClass  = NSClassFromString(@"CGVirtualDisplaySettings");
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        Class dispClass = NSClassFromString(@"CGVirtualDisplay");
        if (!descClass || !setClass || !modeClass || !dispClass) {
            std::fprintf(stderr,
                "VirtualDisplay: private CGVirtualDisplay classes not found on "
                "this macOS build — virtual monitors unavailable.\n");
            return 0;
        }

        CGVirtualDisplayDescriptor* desc = [[descClass alloc] init];
        desc.queue = dispatch_get_main_queue();
        desc.name = [NSString stringWithUTF8String:name.c_str()];
        // Physical size ~ a 24" 16:9 panel; only affects default DPI.
        desc.sizeInMillimeters = CGSizeMake(531, 299);
        desc.maxPixelsWide = (uint32_t)width;
        desc.maxPixelsHigh = (uint32_t)height;
        desc.productID = 0x1234;
        desc.vendorID  = 0x3456;
        // Vary the serial per display so macOS treats them as distinct.
        desc.serialNum = 0x0001 + (uint32_t)holders.count;

        CGVirtualDisplay* disp = [[dispClass alloc] initWithDescriptor:desc];
        if (!disp) {
            std::fprintf(stderr, "VirtualDisplay: initWithDescriptor failed\n");
            return 0;
        }

        CGVirtualDisplayMode* mode =
            [[modeClass alloc] initWithWidth:(uint32_t)width
                                      height:(uint32_t)height
                                 refreshRate:refreshHz];
        CGVirtualDisplaySettings* settings = [[setClass alloc] init];
        settings.modes = @[ mode ];
        settings.hiDPI = hidpi ? 1 : 0;

        if (![disp applySettings:settings]) {
            std::fprintf(stderr, "VirtualDisplay: applySettings failed\n");
            return 0;
        }

        CGDirectDisplayID did = disp.displayID;
        if (did == 0) {
            std::fprintf(stderr, "VirtualDisplay: got displayID 0\n");
            return 0;
        }

        // Keep the display + its mode/settings retained for its lifetime.
        [holders addObject:disp];
        [holders addObject:settings];

        Created c{ (uint32_t)did, name, width, height };
        created_.push_back(c);
        std::fprintf(stderr, "VirtualDisplay '%s' created: id=%u %dx%d%s\n",
                     name.c_str(), (unsigned)did, width, height,
                     hidpi ? " (HiDPI)" : "");
        return (uint32_t)did;
    }
}

void VirtualDisplayManager::teardown() {
    if (objcHolders_) {
        NSMutableArray* holders = (__bridge_transfer NSMutableArray*)objcHolders_;
        [holders removeAllObjects]; // releasing CGVirtualDisplay destroys it
        objcHolders_ = nullptr;
    }
    created_.clear();
}

} // namespace rns
