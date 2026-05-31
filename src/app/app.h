#pragma once
#include "../tracking/imu_service.h"
#include "../display/display_locator.h"
#include "../capture/capture_source.h"

namespace rns {

/// Bring up the AppKit app: NSApplication, borderless fullscreen NSWindow on
/// the given glasses display, MTKView-backed Metal renderer, key handler.
/// Blocks until the user quits (⌘Q or Esc). Returns 0 on clean exit.
int runApp(ImuService& imu, const DisplayInfo& glasses);

} // namespace rns
