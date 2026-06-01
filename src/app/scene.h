#pragma once
#include "../tracking/imu_service.h"
#include "../tracking/quat.h"

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

/// Grow/shrink the scene's per-slot capture-source table to `count` entries
/// (new entries start as null → procedural texture). Call after adding or
/// removing a slot so the table stays index-aligned with cfg.screens.
void sceneEnsureSlotCount(Scene scene, int count);

/// Render the scene's quads into `mtkView` from a camera oriented by
/// `camOrient` (WORLD->HEAD quaternion). Lets a second view (the on-Mac
/// preview) reuse the exact same pipeline + live capture textures. Pass the
/// IMU view quat to mirror the glasses, or Quat::identity() for a stable view.
/// `commandQueue` (an id<MTLCommandQueue>, or null to use the scene's own) lets
/// the preview submit on its own queue so two MTKViews don't share one.
void sceneRenderInto(Scene scene, void* mtkView, Quat camOrient, float fovDiagDeg,
                     void* commandQueue);

} // namespace rns
