#pragma once
#include "quat.h"
#include "orientation_filter.h"
#include "smooth_follow.h"
#include <atomic>
#include <cstdint>
#include <mutex>
#include <thread>

// Forward-declare the SDK context to keep the C header out of public C++ headers.
struct RayneoContext__;
typedef struct RayneoContext__* RAYNEO_Context;

namespace rns {

/// Owns the SDK lifecycle and drives a polling thread. Polling mode is used
/// (rather than the event-callback API) because the prebuilt SDK on this
/// machine — the same one shipped with package/examples/RayNeoExample —
/// reliably delivers IMU_SAMPLE only via Rayneo_PollEvent. The polling thread
/// also calls Rayneo_EnableImu on attach (the SDK is not ready to receive
/// commands from within its own event callback).
class ImuService {
public:
    ImuService();
    ~ImuService();

    /// Returns 0 on success; on error, prints to stderr and returns the
    /// underlying RAYNEO_Result code.
    int start();
    void stop();

    struct Snapshot {
        Quat raw;        // pre-recenter, pre-smoothing (debug)
        Quat view;       // smoothed + recentered (use for rendering)
        float gyroDps;
        uint64_t samples;
        bool attached;
    };

    Snapshot snapshot() const;

    void recenter();
    void resetFilter();

    /// Switch the glasses out of side-by-side 3D into 2D (same image to both
    /// eyes). Requested mode is applied on the next DEVICE_ATTACHED and cached
    /// so a sleep/wake re-applies it. Pass true for 2D (mono), false for 3D.
    void setMono(bool mono);

private:
    void pollLoop();
    void handleEvent(const void* eventPtr);
    void ingestImuRaw(const void* samplePtr, double hostTimeSec);

    RAYNEO_Context ctx_ = nullptr;
    OrientationFilter filter_;
    SmoothFollow smoother_;
    Recenter recenter_;

    std::thread worker_;
    std::atomic<bool> workerRunning_{false};

    mutable std::mutex mu_;
    Quat lastOrientation_ = Quat::identity();
    Quat lastSmoothed_    = Quat::identity();
    float lastGyroDps_    = 0.f;
    uint64_t sampleCount_ = 0;
    bool attached_        = false;
    bool imuEnabled_      = false;
    std::atomic<bool> wantMono_{true};   // request 2D (mono) by default
    std::atomic<bool> monoApplied_{false};

    void applyDisplayMode();
};

} // namespace rns
