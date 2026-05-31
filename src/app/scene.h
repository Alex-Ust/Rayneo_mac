#pragma once
#include "../tracking/imu_service.h"

#ifdef __OBJC__
@class MTKView;
#endif

namespace rns {

struct CaptureSource; // fwd

/// Builds and owns the Metal pipeline for rendering N textured quads in world
/// space, viewed through a head-tracked camera. M2: one quad is fed by a
/// ScreenCaptureKit source if provided; remaining quads show procedural
/// gradients.
struct Scene {
    void* objc = nullptr; // strong reference to the Obj-C scene
};

Scene makeScene(void* mtkView, ImuService* imu);
void  destroyScene(Scene&);

/// Wire a CaptureSource as the texture for quad index `quadIndex`. The Scene
/// will read `captureLatestTexture(source)` every frame.
/// Takes Scene by value: only the .objc pointer is read, the underlying
/// Obj-C scene object is mutated.
void sceneSetCaptureSource(Scene scene, int quadIndex, CaptureSource* source);

} // namespace rns
