#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace rns {

/// Creates and owns one or more real macOS virtual displays via the private
/// CGVirtualDisplay API. Each appears in System Settings ▸ Displays and can be
/// dragged onto like a physical monitor. Capture each by its displayID.
class VirtualDisplayManager {
public:
    struct Created {
        uint32_t displayID;   // 0 if creation failed
        std::string name;
        int width;
        int height;
    };

    ~VirtualDisplayManager();

    /// Create one virtual display. Returns displayID (0 on failure).
    /// `hidpi` true makes it a Retina (2x) panel — text looks crisp through
    /// the glasses but the backing pixels double.
    uint32_t create(const std::string& name, int width, int height,
                    double refreshHz, bool hidpi);

    const std::vector<Created>& displays() const { return created_; }

    /// Tear down every virtual display. Called automatically on destruction,
    /// but call explicitly on quit so the user is never left with phantom
    /// monitors.
    void teardown();

private:
    // Holds the Obj-C CGVirtualDisplay objects (and their settings) alive;
    // releasing them destroys the display.
    void* objcHolders_ = nullptr; // NSMutableArray*
    std::vector<Created> created_;
};

} // namespace rns
