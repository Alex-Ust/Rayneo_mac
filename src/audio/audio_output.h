#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace rns {

struct AudioDevice {
    uint32_t id;        // AudioDeviceID
    std::string name;
    bool isDefault;
    bool isBuiltin;     // Mac's built-in speakers
};

/// All output-capable audio devices (built-in speakers, headphones, the
/// glasses' speakers when connected, etc.).
std::vector<AudioDevice> listOutputDevices();

/// Switch the system default output device. Returns true on success.
bool setDefaultOutputDevice(uint32_t deviceID);

} // namespace rns
