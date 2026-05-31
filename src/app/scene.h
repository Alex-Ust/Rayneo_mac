#pragma once
#include "../tracking/imu_service.h"

#ifdef __OBJC__
@class MTKView;
#endif

namespace rns {

/// Builds and owns the Metal pipeline for rendering N textured quads in world
/// space, viewed through a head-tracked camera. For M2 each quad shows a
/// procedural gradient; M3 will replace the texture with a captured window.
struct Scene {
    void* objc = nullptr; // strong reference to the Obj-C scene
};

Scene makeScene(void* mtkView, ImuService* imu);
void  destroyScene(Scene&);

} // namespace rns
