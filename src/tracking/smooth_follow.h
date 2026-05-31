#pragma once
#include "quat.h"

namespace rns {

/// "Smooth Follow" drift/jitter mask — when the head is still for a few
/// frames, freeze output to the last-known orientation. Hides slow gyro
/// drift and the tiny breathing sway that makes panels shimmer. Hysteresis
/// (separate stop/start thresholds) prevents flicker around the boundary.
class SmoothFollow {
public:
    Quat process(Quat orientation, float gyroDps);

private:
    bool frozen_ = false;
    int  stillFrames_ = 0;
    Quat held_ = Quat::identity();
};

/// Recenter: remembers a reference orientation; downstream applies it so the
/// current pose becomes straight-ahead.
class Recenter {
public:
    void capture(Quat current) { reference_ = current; }
    Quat apply(Quat current) const {
        return (current * reference_.inverse()).normalized();
    }
private:
    Quat reference_ = Quat::identity();
};

} // namespace rns
