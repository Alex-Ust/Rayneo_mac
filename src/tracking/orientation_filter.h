#pragma once
#include "quat.h"

namespace rns {

/// Complementary filter: integrate gyro (high-frequency truth) and slowly pull
/// pitch+roll toward the accelerometer's gravity direction. Yaw is left alone
/// (gravity carries no heading; magnetometer is unreliable per SDK docs).
class OrientationFilter {
public:
    void reset();

    /// Feed one IMU sample. `tick` is the device-side counter (treated as ms
    /// since this is the typical HID stack convention); hostTimeSec is a
    /// monotonic seconds clock used to sanity-clamp tick deltas.
    void ingest(float gyroRadX, float gyroRadY, float gyroRadZ,
                float accX,     float accY,     float accZ,
                unsigned int tick, double hostTimeSec);

    Quat orientation() const { return q_; }

private:
    Quat q_ = Quat::identity(); // WORLD -> HEAD
    unsigned int lastTick_ = 0;
    double lastHost_ = 0.0;
    bool initialized_ = false;
};

} // namespace rns
