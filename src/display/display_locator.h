#pragma once
#include <string>
#include <vector>
#include <cstdint>

namespace rns {

struct DisplayInfo {
    uint32_t displayID;
    std::string name;
    int pixelWidth;
    int pixelHeight;
    double refreshHz;
    bool isBuiltin;
    // Global coordinate-space bounds (points). origin is top-left of the main display.
    double boundsX, boundsY, boundsW, boundsH;
};

class DisplayLocator {
public:
    static std::vector<DisplayInfo> enumerate();

    /// Best-effort match. Order:
    ///   1) name contains config.glassesNameHint
    ///   2) non-builtin display matching configured WxH
    ///   3) any non-builtin display
    /// Returns nullptr-ish (displayID == 0) if no candidate.
    static DisplayInfo findGlasses();
};

} // namespace rns
