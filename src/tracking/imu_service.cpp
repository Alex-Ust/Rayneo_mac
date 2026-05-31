#include "imu_service.h"
#include "rayneo_api.h"
#include <chrono>
#include <cmath>
#include <cstdio>

namespace rns {

static double hostTimeSec() {
    using clock = std::chrono::steady_clock;
    static auto t0 = clock::now();
    return std::chrono::duration<double>(clock::now() - t0).count();
}

ImuService::ImuService() = default;
ImuService::~ImuService() { stop(); }

int ImuService::start() {
    // Enable verbose SDK logging for the first run so the human can see what
    // the driver is doing if anything looks off. Tune down to 0 later.
    Rayneo_SetLogLevel(1);

    RAYNEO_Result r = Rayneo_Create(&ctx_);
    if (r != RAYNEO_OK || !ctx_) {
        std::fprintf(stderr, "Rayneo_Create failed: %d (%s)\n",
                     (int)r, Rayneo_ResultToString(r));
        return (int)r;
    }

    // RayNeo Air 3s Pro USB VID/PID (extracted from package/examples/RayNeoExample
    // disassembly). The AUTODETECT service flag did not work here — possibly
    // because libusb on this Mac doesn't see the HID interface without an
    // explicit VID/PID match — and ASYNC_IMU stopped IMU_SAMPLE events from
    // reaching PollEvent. The example program runs with flags=0.
    Rayneo_SetTargetVidPid(ctx_, 0x1bbb, 0xaf50);

    r = Rayneo_Start(ctx_, /*flags=*/0);
    if (r != RAYNEO_OK) {
        std::fprintf(stderr, "Rayneo_Start failed: %d (%s)\n",
                     (int)r, Rayneo_ResultToString(r));
        Rayneo_Destroy(ctx_);
        ctx_ = nullptr;
        return (int)r;
    }

    workerRunning_.store(true);
    worker_ = std::thread(&ImuService::pollLoop, this);
    return 0;
}

void ImuService::stop() {
    workerRunning_.store(false);
    if (worker_.joinable()) worker_.join();
    if (ctx_) {
        Rayneo_DisableImu(ctx_);
        Rayneo_Stop(ctx_);
        Rayneo_Destroy(ctx_);
        ctx_ = nullptr;
    }
}

ImuService::Snapshot ImuService::snapshot() const {
    std::lock_guard<std::mutex> lk(mu_);
    Snapshot s;
    s.raw      = lastOrientation_;
    s.view     = recenter_.apply(lastSmoothed_);
    s.gyroDps  = lastGyroDps_;
    s.samples  = sampleCount_;
    s.attached = attached_;
    return s;
}

void ImuService::recenter() {
    Quat cur;
    {
        std::lock_guard<std::mutex> lk(mu_);
        cur = lastSmoothed_;
    }
    recenter_.capture(cur);
}

void ImuService::resetFilter() {
    std::lock_guard<std::mutex> lk(mu_);
    filter_.reset();
    lastOrientation_ = Quat::identity();
    lastSmoothed_    = Quat::identity();
}

void ImuService::setMono(bool mono) {
    wantMono_.store(mono);
    monoApplied_.store(false);
    // If the device is already attached, apply now from the poll thread next
    // tick is simplest — but we can also fire it immediately since command
    // sends are thread-safe in the SDK once attached.
    bool att;
    { std::lock_guard<std::mutex> lk(mu_); att = attached_; }
    if (att) applyDisplayMode();
}

void ImuService::applyDisplayMode() {
    if (monoApplied_.load()) return;
    bool mono = wantMono_.load();
    RAYNEO_Result r = mono ? Rayneo_DisplaySet2D(ctx_)
                           : Rayneo_DisplaySet3D(ctx_);
    std::fprintf(stderr, "\n[display %s] -> %d (%s)\n",
                 mono ? "2D/mono" : "3D/SBS",
                 (int)r, Rayneo_ResultToString(r));
    if (r == RAYNEO_OK) monoApplied_.store(true);
}

void ImuService::pollLoop() {
    RAYNEO_Event evt{};
    while (workerRunning_.load()) {
        // 5 ms timeout: stays responsive to shutdown while letting the SDK
        // amortize USB I/O between dequeues.
        RAYNEO_Result r = Rayneo_PollEvent(ctx_, &evt, 5);
        if (r == RAYNEO_OK) {
            handleEvent(&evt);
        } else if (r != RAYNEO_ERR_TIMEOUT) {
            // Non-fatal: log and keep spinning.
            std::fprintf(stderr, "\nPollEvent err: %d (%s)\n",
                         (int)r, Rayneo_ResultToString(r));
        }
    }
}

void ImuService::handleEvent(const void* eventPtr) {
    const RAYNEO_Event* evt = static_cast<const RAYNEO_Event*>(eventPtr);
    switch (evt->type) {
        case RAYNEO_EVENT_DEVICE_ATTACHED: {
            {
                std::lock_guard<std::mutex> lk(mu_);
                attached_ = true;
                imuEnabled_ = false;
            }
            // Now safe to send commands: we're on the poll thread, not inside
            // the SDK's own callback. Order copies RayNeoExample: request
            // device info, switch to 2D (mono) mode so the same image is
            // shown to both eyes — otherwise the glasses ship in SBS 3D and
            // each lens only sees half the panel — then enable IMU.
            (void)Rayneo_RequestDeviceInfo(ctx_);
            applyDisplayMode();
            RAYNEO_Result e = Rayneo_EnableImu(ctx_);
            if (e == RAYNEO_OK) {
                std::lock_guard<std::mutex> lk(mu_);
                imuEnabled_ = true;
            } else {
                std::fprintf(stderr,
                             "\nwarn: Rayneo_EnableImu on attach -> %d (%s) "
                             "(will retry on IMU_ON notify)\n",
                             (int)e, Rayneo_ResultToString(e));
            }
            break;
        }
        case RAYNEO_EVENT_DEVICE_DETACHED: {
            std::lock_guard<std::mutex> lk(mu_);
            attached_ = false;
            imuEnabled_ = false;
            break;
        }
        case RAYNEO_EVENT_NOTIFY: {
            // The device announces IMU_ON / IMU_OFF / SLEEP / WAKE here.
            int code = evt->data.notify.code;
            if (code == RAYNEO_NOTIFY_IMU_ON) {
                std::lock_guard<std::mutex> lk(mu_);
                imuEnabled_ = true;
            } else if (code == RAYNEO_NOTIFY_IMU_OFF) {
                std::lock_guard<std::mutex> lk(mu_);
                imuEnabled_ = false;
            } else if (code == RAYNEO_NOTIFY_WAKE) {
                // After wake the device often needs IMU re-enabled and the
                // display mode re-applied.
                (void)Rayneo_EnableImu(ctx_);
                monoApplied_.store(false);
                applyDisplayMode();
            }
            break;
        }
        case RAYNEO_EVENT_IMU_SAMPLE: {
            if (evt->data.imu.valid != 1) return;
            ingestImuRaw(&evt->data.imu, hostTimeSec());
            break;
        }
        default:
            break;
    }
}

void ImuService::ingestImuRaw(const void* samplePtr, double host) {
    const RAYNEO_ImuSample* s = static_cast<const RAYNEO_ImuSample*>(samplePtr);
    float gyroDpsMag = std::sqrt(
        s->gyroDps[0] * s->gyroDps[0] +
        s->gyroDps[1] * s->gyroDps[1] +
        s->gyroDps[2] * s->gyroDps[2]
    );

    std::lock_guard<std::mutex> lk(mu_);
    filter_.ingest(
        s->gyroRad[0], s->gyroRad[1], s->gyroRad[2],
        s->acc[0],     s->acc[1],     s->acc[2],
        s->tick, host
    );
    Quat raw = filter_.orientation();
    Quat smoothed = smoother_.process(raw, gyroDpsMag);
    lastOrientation_ = raw;
    lastSmoothed_    = smoothed;
    lastGyroDps_     = gyroDpsMag;
    ++sampleCount_;
}

} // namespace rns
