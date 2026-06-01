#pragma once
#include "scene.h"
#include "../tracking/imu_service.h"

namespace rns {

/// A normal AppKit window on the Mac's main display that lets the user edit
/// the slot layout by hand (sliders/checkboxes/buttons) instead of hotkeys.
struct ControlPanel {
    void* objc = nullptr;
};

/// Create and show the control panel. `actionsDelegate` is an
/// id<RNSControlActions> (passed as void* to keep this header pure C++).
/// `scene`/`imu`/`device` feed the embedded live preview of the glasses
/// render (where screens can be dragged and apps dropped onto them).
ControlPanel makeControlPanel(void* actionsDelegate, Scene scene,
                              ImuService* imu, void* device);
void destroyControlPanel(ControlPanel&);

/// Rebuild the panel's rows from the current config (call after a slot is
/// added/removed/pinned so the UI reflects it).
void controlPanelRefresh(ControlPanel&);

} // namespace rns
