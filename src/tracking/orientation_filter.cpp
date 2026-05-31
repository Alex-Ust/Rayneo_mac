#include "orientation_filter.h"
#include "../config.h"
#include <algorithm>

namespace rns {

void OrientationFilter::reset() {
    q_ = Quat::identity();
    initialized_ = false;
}

static Vec3 remap(float a, float b, float c,
                  const std::array<int, 3>& perm,
                  const std::array<float, 3>& sign) {
    float arr[3] = {a, b, c};
    return {arr[perm[0]] * sign[0],
            arr[perm[1]] * sign[1],
            arr[perm[2]] * sign[2]};
}

void OrientationFilter::ingest(float gx, float gy, float gz,
                               float ax, float ay, float az,
                               unsigned int tick, double host) {
    const Config& cfg = config();

    // dt: prefer device tick deltas (treated as ms), but clamp against host
    // clock to defeat outliers (first sample, wraparound, USB stalls).
    float dt;
    if (initialized_) {
        unsigned int tickDelta = tick - lastTick_; // unsigned wrap is fine
        float tickSeconds = static_cast<float>(tickDelta) * 0.001f;
        float hostDelta = static_cast<float>(host - lastHost_);
        float candidate = (tickSeconds > 0.f) ? std::min(tickSeconds, hostDelta) : hostDelta;
        dt = std::clamp(candidate, 0.0001f, 0.05f);
    } else {
        dt = 0.005f;
        initialized_ = true;
    }
    lastTick_ = tick;
    lastHost_ = host;

    Vec3 gyro = remap(gx, gy, gz, cfg.gyroAxisPermutation, cfg.gyroAxisSign);
    Vec3 acc  = remap(ax, ay, az, cfg.accAxisPermutation,  cfg.accAxisSign);

    // === Predict: integrate gyro in body frame ===
    Vec3 rv{gyro.x * dt, gyro.y * dt, gyro.z * dt};
    if (!cfg.yawEnabled)   rv.y = 0.f;
    if (!cfg.pitchEnabled) rv.x = 0.f;
    Quat delta = Quat::fromRotationVector(rv);
    // q rotates WORLD -> HEAD; body-frame angular velocity updates by
    // right-multiplication.
    q_ = (q_ * delta).normalized();

    // === Correct: pull pitch/roll toward accel gravity ===
    // Skip during large linear-accel events (magnitude far from 1g) or during
    // fast head turns (gyro-magnitude high) — those inject noise.
    float accLen = acc.length();
    const float gNominal = 9.81f;
    bool oneG = std::fabs(accLen - gNominal) < 0.25f * gNominal;
    float gyroMag = std::sqrt(gyro.x * gyro.x + gyro.y * gyro.y + gyro.z * gyro.z);
    if (oneG && gyroMag < 1.5f) {
        // Body-frame gravity: sensor reports +g UP when stationary, so the
        // world-down direction in body frame is -acc.normalized.
        Vec3 gravBody = (acc * -1.f).normalized();
        Vec3 expectedBody = q_.rotate({0.f, -1.f, 0.f});
        // Cross product = axis * sin(theta) → use directly as scaled rotvec.
        Vec3 err = expectedBody.cross(gravBody);
        // Zero the body-Y (yaw) component → corrects pitch/roll only.
        Vec3 errNoYaw{err.x, 0.f, err.z};
        Vec3 correction = errNoYaw * cfg.accelAlpha;
        Quat corr = Quat::fromRotationVector(correction);
        q_ = (q_ * corr).normalized();
    }
}

} // namespace rns
