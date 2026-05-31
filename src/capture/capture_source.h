#pragma once
#include <vector>
#include <cstdint>
#include <string>

#ifdef __OBJC__
@protocol MTLDevice;
@protocol MTLTexture;
#endif

namespace rns {

/// Opaque capture source wrapping an SCStream that pushes CVPixelBuffers
/// (BGRA) into a CVMetalTextureCache. The latest captured texture can be
/// retrieved as an `id<MTLTexture>` (returned as a void* to keep this header
/// pure C++). The returned texture is autoreleased; bridge-retain it before
/// crossing the autorelease-pool boundary.
struct CaptureSource {
    void* objc = nullptr;
};

/// One-shot prompt for the Screen Recording permission. Returns true if the
/// permission was already granted. If false, an OS dialog is queued and the
/// caller should re-launch (the app cannot dynamically gain access mid-run).
bool requestScreenRecordingPermission();

/// Make a CaptureSource that captures the macOS built-in display.
/// `device` is the Metal device the produced textures must be valid on.
/// On failure (missing permission, OS too old, no displays), returns a
/// CaptureSource with objc == nullptr and prints to stderr.
CaptureSource makeBuiltinDisplayCapture(void* device, int width, int height);

/// Discover up to `maxCount` interesting on-screen windows (biggest first,
/// excluding desktop / menu bar / our own window) and create a CaptureSource
/// for each. Returns the number of sources actually populated in `out`.
/// `out` is resized to that count.
int discoverWindowCaptures(void* device,
                           int maxCount,
                           int width, int height,
                           std::vector<CaptureSource>& out);

/// Latest texture as `id<MTLTexture>` (cast to void* for the header). May be
/// nullptr if no frame has arrived yet.
void* captureLatestTexture(CaptureSource&);

void destroyCapture(CaptureSource&);

} // namespace rns
