#pragma once
#include <array>
#include <string>
#include <vector>

namespace rns {

struct ScreenPose {
    float azimuthDeg;
    float elevationDeg;
    float distanceM;
    float widthM;
    float heightM;
};

/// Runtime tunables. Will eventually be persisted to a file and live-edited
/// via hotkeys (M3); for M0 the defaults are reasonable enough to see motion.
struct Config {
    // Complementary filter: accel-based pitch/roll correction blend, per sample.
    // 0.01–0.05 recommended. Higher = follows accel faster, less smooth.
    float accelAlpha = 0.02f;

    // Smooth-follow hysteresis (deg/sec).
    float smoothFollowStopDps   = 0.9f;
    float smoothFollowStartDps  = 3.0f;
    int   smoothFollowStopFrames = 6;

    // Axis remap / sign flips. Defaults: identity. The user verifies by
    // rotating the glasses on each axis and inverting signs / swapping
    // axes here until the printed YPR matches motion.
    std::array<int, 3>   gyroAxisPermutation = {0, 1, 2};
    std::array<float, 3> gyroAxisSign        = {1.f, 1.f, 1.f};
    std::array<int, 3>   accAxisPermutation  = {0, 1, 2};
    std::array<float, 3> accAxisSign         = {1.f, 1.f, 1.f};

    bool yawEnabled   = true;
    bool pitchEnabled = true;

    float fovDiagonalDeg = 46.f;

    std::vector<ScreenPose> screens = {
        { -40.f, 0.f, 2.f, 1.6f, 0.9f },
        {   0.f, 0.f, 2.f, 1.6f, 0.9f },
        {  40.f, 0.f, 2.f, 1.6f, 0.9f },
    };

    // Glasses display heuristic. Each name hint is matched as a case-insensitive
    // substring against the display's localized name; the first hit wins.
    // RayNeo Air 3s Pro have been observed announcing as "SmartGlasses".
    std::vector<std::string> glassesNameHints = { "rayneo", "smartglasses" };
    int glassesWidth  = 1920;
    int glassesHeight = 1080;
};

inline Config& config() {
    static Config c;
    return c;
}

} // namespace rns
