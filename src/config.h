#pragma once
#include <array>
#include <cstdint>
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
    std::string appName;             // label: app shown on this slot.

    // Runtime only: CGDirectDisplayID of this slot's virtual monitor.
    uint32_t backingDisplayID = 0;
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

    // Which slot the control hotkeys act on (index into screens).
    // -1 = nothing selected (no highlight until the user picks one).
    int selectedSlot = -1;

    // When true, dragging an app onto a screen MOVES the app's window onto that
    // screen's virtual monitor (it leaves the Mac). When false, it mirrors the
    // window (a copy; the original stays on the Mac). Default ON now that the
    // virtual displays are real (1:1, non-HiDPI) and host moved windows.
    bool moveAppOntoScreen = true;

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
    // adjacent screens must exceed that. Here W=1.2, D=1.7 → ~38.8° wide,
    // spaced 40° apart → ~1.2° gap, no overlap. Closer than before so the
    // panels feel bigger. Tune live with [ / ] (spread) and - / = (distance).
    std::vector<ScreenPose> screens = {
        []{ ScreenPose s{ -40.f, 0.f, 1.7f, 1.2f, 0.675f };
            s.source = SlotSource::Display; return s; }(),
        []{ ScreenPose s{   0.f, 0.f, 1.7f, 1.2f, 0.675f };
            s.source = SlotSource::Display; return s; }(),
        []{ ScreenPose s{  40.f, 0.f, 1.7f, 1.2f, 0.675f };
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
