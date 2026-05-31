#pragma once
#include "../tracking/imu_service.h"

#ifdef __OBJC__
@class MTKView;
@protocol MTLDevice;
#endif

namespace rns {

/// Opaque renderer handle (Obj-C `id` under the hood — declared as a void*
/// here so this header stays usable from plain C++ TUs).
struct Renderer {
    void* objc = nullptr;   // strong reference to the Obj-C delegate
};

/// Create and configure the Metal renderer; attaches itself as the MTKView's
/// delegate. The MTKView is passed as a void* (an `MTKView*` under the hood)
/// to keep this header pure C++.
Renderer makeRenderer(void* mtkView, ImuService* imu);

/// Release the renderer.
void destroyRenderer(Renderer&);

} // namespace rns
