#pragma once
#include <array>
#include <string>
#include <vector>

namespace rns {

/// What feeds a slot's quad.
enum class SlotSource {
    Display,   // mirror a whole display (built-in now; virtual display in Phase 2)
    App,       // capture a specific application's window (matched by appName)
};

struct ScreenPose {
    float azimuthDeg;
    float elevationDeg;
    float distanceM;
    float widthM;
    float heightM;

    // --- Slot behavior (Phase A) ---
    bool visible = true;             // hidden slots are not drawn (toggle 1/2/3)
    SlotSource source = SlotSource::App;
    std::string appName;             // when source==App: substring of the app's
                                     // name, e.g. "Terminal", "Chrome".
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
    // Y (yaw) sign is flipped: on the device, turning the head right
    // integrated yaw the wrong way, so world-anchored panels drifted with
    // the head instead of against it. Verified on hardware.
    std::array<int, 3>   gyroAxisPermutation = {0, 1, 2};
    std::array<float, 3> gyroAxisSign        = {1.f, -1.f, 1.f};
    std::array<int, 3>   accAxisPermutation  = {0, 1, 2};
    std::array<float, 3> accAxisSign         = {1.f, 1.f, 1.f};

    bool yawEnabled   = true;
    bool pitchEnabled = true;

    float fovDiagonalDeg = 46.f;

    // Three slots in front of the user, each a REAL virtual monitor you can
    // drag any window onto (Terminal, Chrome, anything). Tighter spread
    // (±28°) so two of the three fit the ~46° FOV at once; turn the head to
    // reach the third. Toggle visibility with keys 1/2/3.
    //
    // To instead pin a specific app's window to a slot, set
    //   s.source = SlotSource::App; s.appName = "Terminal";
    // Layout note: a screen of width W at distance D spans an angular width
    // of 2*atan((W/2)/D). To avoid overlap, the azimuth spacing between
    // adjacent screens must exceed that. Here W=1.2, D=2.0 → ~33.4° wide,
    // spaced 35° apart → ~1.6° gap, no overlap. Tune live with [ / ].
    std::vector<ScreenPose> screens = {
        []{ ScreenPose s{ -35.f, 0.f, 2.0f, 1.2f, 0.675f };
            s.source = SlotSource::Display; return s; }(),
        []{ ScreenPose s{   0.f, 0.f, 2.0f, 1.2f, 0.675f };
            s.source = SlotSource::Display; return s; }(),
        []{ ScreenPose s{  35.f, 0.f, 2.0f, 1.2f, 0.675f };
            s.source = SlotSource::Display; return s; }(),
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
