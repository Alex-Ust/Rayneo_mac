#pragma once
#include <cmath>

namespace rns {

struct Vec3 {
    float x{0}, y{0}, z{0};

    float length() const { return std::sqrt(x * x + y * y + z * z); }

    Vec3 normalized() const {
        float n = length();
        return n > 1e-9f ? Vec3{x / n, y / n, z / n} : Vec3{};
    }

    Vec3 operator*(float s) const { return {x * s, y * s, z * s}; }
    Vec3 operator+(Vec3 b) const  { return {x + b.x, y + b.y, z + b.z}; }
    Vec3 operator-(Vec3 b) const  { return {x - b.x, y - b.y, z - b.z}; }

    float dot(Vec3 b) const { return x * b.x + y * b.y + z * b.z; }
    Vec3  cross(Vec3 b) const {
        return {y * b.z - z * b.y,
                z * b.x - x * b.z,
                x * b.y - y * b.x};
    }
};

/// Unit quaternion (w, x, y, z). Convention: rotates WORLD -> HEAD,
/// i.e. v_head = q.rotate(v_world).
struct Quat {
    float w{1}, x{0}, y{0}, z{0};

    static Quat identity() { return {}; }

    Quat conjugate() const { return {w, -x, -y, -z}; }
    Quat inverse()   const { return conjugate(); } // unit quat

    Quat normalized() const {
        float n = std::sqrt(w * w + x * x + y * y + z * z);
        if (n < 1e-9f) return identity();
        return {w / n, x / n, y / n, z / n};
    }

    Quat operator*(Quat b) const {
        return {
            w * b.w - x * b.x - y * b.y - z * b.z,
            w * b.x + x * b.w + y * b.z - z * b.y,
            w * b.y - x * b.z + y * b.w + z * b.x,
            w * b.z + x * b.y - y * b.x + z * b.w
        };
    }

    Vec3 rotate(Vec3 v) const {
        Vec3 qv{x, y, z};
        Vec3 t = qv.cross(v) * 2.0f;
        return v + t * w + qv.cross(t);
    }

    /// Quaternion from a rotation vector (axis * angle, radians).
    static Quat fromRotationVector(Vec3 rv) {
        float theta = rv.length();
        if (theta < 1e-7f) {
            return Quat{1.0f, rv.x * 0.5f, rv.y * 0.5f, rv.z * 0.5f}.normalized();
        }
        float half = theta * 0.5f;
        float s = std::sin(half) / theta;
        return {std::cos(half), rv.x * s, rv.y * s, rv.z * s};
    }

    /// Tait–Bryan: yaw around Y, pitch around X, roll around Z (radians).
    /// Useful for human-readable HUD print.
    void toYPR(float& yaw, float& pitch, float& roll) const {
        float sinp = 2.0f * (w * x - y * z);
        pitch = std::fabs(sinp) >= 1.0f ? std::copysign(static_cast<float>(M_PI_2), sinp)
                                        : std::asin(sinp);
        yaw   = std::atan2(2.0f * (w * y + x * z), 1.0f - 2.0f * (x * x + y * y));
        roll  = std::atan2(2.0f * (w * z + x * y), 1.0f - 2.0f * (x * x + z * z));
    }
};

inline float radToDeg(float r) { return r * 57.29577951308232f; }
inline float degToRad(float d) { return d * 0.017453292519943295f; }

} // namespace rns
