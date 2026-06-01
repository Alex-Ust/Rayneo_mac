#pragma once
#include "../config.h"
#include "../render/mat4.h"
#include "../tracking/quat.h"
#include <cmath>

// Mouse picking / cursor-direction math for the preview view. Pure geometry on
// rns::config().screens — no scene/Metal state. The preview camera sits at the
// world origin (the head is the origin; quads are placed around it), oriented
// by `cam` (a WORLD->HEAD quaternion, same convention as the IMU view quat).

namespace rns {

// Direction of a cursor ray in WORLD space. (ndcX, ndcY) in [-1,1], y up.
inline Vec3 cursorWorldDir(float ndcX, float ndcY, float aspect,
                           float fovDiagDeg, const Quat& cam) {
    const float diag = degToRad(fovDiagDeg);
    const float fovY = 2.0f * std::atan(std::tan(diag * 0.5f) /
                                        std::sqrt(1.0f + aspect * aspect));
    const float tanY = std::tan(fovY * 0.5f);
    const float tanX = tanY * aspect;
    Vec3 dirEye{ ndcX * tanX, ndcY * tanY, -1.0f };   // camera looks down -Z
    // cam maps world->head; its conjugate maps head/eye->world.
    return cam.conjugate().rotate(dirEye.normalized()).normalized();
}

// Index of the nearest visible screen the cursor ray hits, or -1 if none.
inline int pickSlot(float ndcX, float ndcY, float aspect,
                    float fovDiagDeg, const Quat& cam) {
    const Vec3 D = cursorWorldDir(ndcX, ndcY, aspect, fovDiagDeg, cam);
    const Config& cfg = config();
    int best = -1;
    float bestT = 1e30f;
    for (size_t i = 0; i < cfg.screens.size(); ++i) {
        const auto& s = cfg.screens[i];
        if (!s.visible) continue;
        Mat4 m = quadModelMatrix(s.azimuthDeg, s.elevationDeg,
                                 s.distanceM, s.widthM, s.heightM);
        Vec3 col0{ m.m[0], m.m[1], m.m[2] };     // right * sx
        Vec3 col1{ m.m[4], m.m[5], m.m[6] };     // up    * sy
        Vec3 N   { m.m[8], m.m[9], m.m[10] };    // forward (unit normal)
        Vec3 P   { m.m[12], m.m[13], m.m[14] };  // center
        float sx = col0.length(), sy = col1.length();
        if (sx < 1e-6f || sy < 1e-6f) continue;
        Vec3 right = col0 * (1.0f / sx);
        Vec3 up    = col1 * (1.0f / sy);

        float denom = D.dot(N);
        if (std::fabs(denom) < 1e-6f) continue;  // ray parallel to quad
        float t = P.dot(N) / denom;              // origin is (0,0,0)
        if (t <= 0.0f || t >= bestT) continue;
        Vec3 hit = D * t;
        Vec3 rel = hit - P;
        if (std::fabs(rel.dot(right)) <= sx && std::fabs(rel.dot(up)) <= sy) {
            best = (int)i;
            bestT = t;
        }
    }
    return best;
}

// Like pickSlot but never misses: if the ray hits no quad, returns the visible
// screen whose center direction is closest to the cursor ray. Used for drops.
inline int pickNearestSlot(float ndcX, float ndcY, float aspect,
                           float fovDiagDeg, const Quat& cam) {
    int hit = pickSlot(ndcX, ndcY, aspect, fovDiagDeg, cam);
    if (hit >= 0) return hit;
    const Vec3 D = cursorWorldDir(ndcX, ndcY, aspect, fovDiagDeg, cam);
    const Config& cfg = config();
    int best = -1; float bestDot = -2.0f;
    for (size_t i = 0; i < cfg.screens.size(); ++i) {
        const auto& s = cfg.screens[i];
        if (!s.visible) continue;
        float az = degToRad(s.azimuthDeg), el = degToRad(s.elevationDeg);
        Vec3 c{ std::cos(el) * std::sin(az), std::sin(el),
                -std::cos(el) * std::cos(az) };       // screen center direction
        float d = D.dot(c);
        if (d > bestDot) { bestDot = d; best = (int)i; }
    }
    return best;
}

// Azimuth/elevation (degrees) of the cursor ray — used to move a screen so its
// center follows the cursor. Inverse of quadModelMatrix's direction mapping.
inline void cursorToAzEl(float ndcX, float ndcY, float aspect,
                         float fovDiagDeg, const Quat& cam,
                         float& azDeg, float& elDeg) {
    const Vec3 d = cursorWorldDir(ndcX, ndcY, aspect, fovDiagDeg, cam);
    elDeg = radToDeg(std::asin(std::max(-1.0f, std::min(1.0f, d.y))));
    azDeg = radToDeg(std::atan2(d.x, -d.z));
}

} // namespace rns
