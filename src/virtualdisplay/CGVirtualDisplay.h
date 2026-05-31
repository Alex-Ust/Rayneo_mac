// Reverse-engineered private CoreGraphics virtual-display API.
//
// These classes are NOT in any public SDK header; they live inside
// CoreGraphics / SkyLight and are used by BetterDummy, BetterDisplay,
// DisplayLink, Lumen, etc. The interface below matches the layout used on
// macOS 11–15 and (so far) 26. If Apple changes the ABI, creation will fail
// gracefully (initWithDescriptor returns an object whose displayID stays 0).
//
// Private API: ineligible for the App Store. Phase 1 works without it.
#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

// ---- Descriptor: immutable identity passed to -initWithDescriptor: --------
@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy)   NSString *name;
// Physical size; macOS derives default DPI from this. ~maxPixels / (mm/25.4)
@property(nonatomic, assign) CGSize sizeInMillimeters;
@property(nonatomic, assign) uint32_t maxPixelsWide;
@property(nonatomic, assign) uint32_t maxPixelsHigh;
@property(nonatomic, assign) uint32_t productID;
@property(nonatomic, assign) uint32_t vendorID;
@property(nonatomic, assign) uint32_t serialNum;
// Invoked when the display is torn down by the system.
@property(nonatomic, copy, nullable) void (^terminationHandler)(id terminationReason, id displayRef);
@end

// ---- One selectable resolution / refresh ----------------------------------
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  refreshRate:(double)refreshRate;
@property(nonatomic, readonly) uint32_t width;
@property(nonatomic, readonly) uint32_t height;
@property(nonatomic, readonly) double   refreshRate;
@end

// ---- Mutable settings applied after creation ------------------------------
@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic, assign) uint32_t hiDPI;          // 1 => Retina/HiDPI
@property(nonatomic, assign) uint32_t rotation;
@end

// ---- The display itself ---------------------------------------------------
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(nonatomic, readonly) uint32_t            vendorID;
@property(nonatomic, readonly) uint32_t            productID;
@property(nonatomic, readonly) uint32_t            serialNum;
@property(nonatomic, readonly) NSString           *name;
@property(nonatomic, readonly) CGSize              sizeInMillimeters;
@property(nonatomic, readonly) uint32_t            maxPixelsWide;
@property(nonatomic, readonly) uint32_t            maxPixelsHigh;
@property(nonatomic, readonly) CGDirectDisplayID   displayID;
@property(nonatomic, readonly) uint32_t            hiDPI;
@property(nonatomic, readonly) CGVirtualDisplaySettings *settings;
@end

NS_ASSUME_NONNULL_END
