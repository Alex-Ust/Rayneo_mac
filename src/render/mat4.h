#pragma once
#include "../tracking/quat.h"
#include <array>
#include <cmath>

namespace rns {

/// Column-major 4x4 matrix, layout-compatible with Metal's float4x4 once
/// uploaded as a uniform buffer.
struct Mat4 {
    // Stored column-major: m[col][row]. m[0]={col0_x, col0_y, col0_z, col0_w}.
    std::array<float, 16> m{};

    static Mat4 identity() {
        Mat4 r;
        r.m[0] = 1; r.m[5] = 1; r.m[10] = 1; r.m[15] = 1;
        return r;
    }

    /// Translation by (tx, ty, tz).
    static Mat4 translation(float tx, float ty, float tz) {
        Mat4 r = identity();
        r.m[12] = tx; r.m[13] = ty; r.m[14] = tz;
        return r;
    }

    /// From a quaternion (rotation matrix, row/col-major same form on unit q).
    /// Convention: q rotates v_world -> v_head. Returns the matrix that maps
    /// world coordinates into the head/eye frame (used as the view matrix).
    static Mat4 fromQuat(Quat q) {
        const float x = q.x, y = q.y, z = q.z, w = q.w;
        const float xx = x*x, yy = y*y, zz = z*z;
        const float xy = x*y, xz = x*z, yz = y*z;
        const float wx = w*x, wy = w*y, wz = w*z;
        Mat4 r;
        // column 0
        r.m[0]  = 1 - 2*(yy + zz);
        r.m[1]  =     2*(xy + wz);
        r.m[2]  =     2*(xz - wy);
        r.m[3]  = 0;
        // column 1
        r.m[4]  =     2*(xy - wz);
        r.m[5]  = 1 - 2*(xx + zz);
        r.m[6]  =     2*(yz + wx);
        r.m[7]  = 0;
        // column 2
        r.m[8]  =     2*(xz + wy);
        r.m[9]  =     2*(yz - wx);
        r.m[10] = 1 - 2*(xx + yy);
        r.m[11] = 0;
        // column 3
        r.m[12] = 0; r.m[13] = 0; r.m[14] = 0; r.m[15] = 1;
        return r;
    }

    /// Perspective projection, right-handed, depth in [0,1] (Metal convention).
    /// fovYRad = vertical FOV in radians; aspect = width/height.
    static Mat4 perspective(float fovYRad, float aspect, float zNear, float zFar) {
        const float f = 1.0f / std::tan(fovYRad * 0.5f);
        Mat4 r;
        r.m[0]  = f / aspect;
        r.m[5]  = f;
        r.m[10] = zFar / (zNear - zFar);
        r.m[11] = -1.0f;
        r.m[14] = (zFar * zNear) / (zNear - zFar);
        return r;
    }

    /// Standard 4x4 matrix multiply: result = a * b.
    static Mat4 mul(const Mat4& a, const Mat4& b) {
        Mat4 r;
        for (int c = 0; c < 4; ++c) {
            for (int rr = 0; rr < 4; ++rr) {
                float sum = 0;
                for (int k = 0; k < 4; ++k) {
                    sum += a.m[k * 4 + rr] * b.m[c * 4 + k];
                }
                r.m[c * 4 + rr] = sum;
            }
        }
        return r;
    }
};

/// Build the model matrix for a screen quad at (azimuth, elevation, distance)
/// around the world origin, billboarded to face the origin, with (widthM,
/// heightM) extent. Azimuth rotates around +Y (positive = right when
/// looking down -Z); elevation around the resulting +X (positive = up).
inline Mat4 quadModelMatrix(float azimuthDeg, float elevationDeg,
                            float distanceM, float widthM, float heightM) {
    const float az = degToRad(azimuthDeg);
    const float el = degToRad(elevationDeg);

    // Direction in world from origin to the quad's center, then position.
    const float cx = std::cos(el) * std::sin(az);
    const float cy = std::sin(el);
    const float cz = -std::cos(el) * std::cos(az);   // forward is -Z at az=0
    const float px = cx * distanceM, py = cy * distanceM, pz = cz * distanceM;

    // The quad's local +Z faces back toward the origin (i.e. -dir).
    // Build a basis: forward = -dir (so the quad's normal points at the eye),
    // up = world up projected, right = up × forward.
    Vec3 forward{-cx, -cy, -cz};        // unit
    Vec3 worldUp{0, 1, 0};
    Vec3 right = worldUp.cross(forward).normalized();
    // If forward is nearly parallel to worldUp (looking straight up/down),
    // fall back to a fixed right.
    if (right.length() < 1e-4f) right = Vec3{1, 0, 0};
    Vec3 up = forward.cross(right).normalized();

    // Compose model matrix: basis * scale, translated to (px,py,pz).
    const float sx = widthM * 0.5f, sy = heightM * 0.5f;
    Mat4 r = Mat4::identity();
    // column 0 = right * sx
    r.m[0] = right.x * sx;   r.m[1] = right.y * sx;   r.m[2] = right.z * sx;
    // column 1 = up * sy
    r.m[4] = up.x    * sy;   r.m[5] = up.y    * sy;   r.m[6] = up.z    * sy;
    // column 2 = forward (z extent is 0 — flat quad)
    r.m[8] = forward.x;      r.m[9] = forward.y;      r.m[10]= forward.z;
    // column 3 = position
    r.m[12]= px;             r.m[13]= py;             r.m[14]= pz;
    return r;
}

} // namespace rns
