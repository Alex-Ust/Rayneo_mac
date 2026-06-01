#include "config.h"
#include "config_store.h"
#include "tracking/imu_service.h"
#include "display/display_locator.h"
#include "app/app.h"
#include "rayneo_api.h"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <thread>

using namespace rns;

namespace {

std::atomic<bool> g_keepLogging{true};

void onSigint(int) { g_keepLogging.store(false); }

// Background heartbeat: every 250 ms print current YPR to stderr. The Metal
// window is the visual output; this keeps a tracking trace in the terminal
// for headless debugging and hardware verification.
void heartbeat(ImuService* imu) {
    uint64_t lastSamples = 0;
    auto lastWall = std::chrono::steady_clock::now();
    while (g_keepLogging.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
        auto snap = imu->snapshot();
        float yV, pV, rV, yR, pR, rR;
        snap.view.toYPR(yV, pV, rV);
        snap.raw.toYPR(yR, pR, rR);
        auto now = std::chrono::steady_clock::now();
        double dt = std::chrono::duration<double>(now - lastWall).count();
        if (dt < 0.001) dt = 0.001;
        uint64_t dN = snap.samples - lastSamples;
        double hz = static_cast<double>(dN) / dt;
        lastSamples = snap.samples;
        lastWall = now;
        std::fprintf(stderr,
            "\r[%s %5.0fHz] view y=%+6.1f° p=%+6.1f° r=%+6.1f°  "
            "raw y=%+6.1f° p=%+6.1f° r=%+6.1f°  n=%llu   ",
            snap.attached ? "att" : "DET", hz,
            radToDeg(yV), radToDeg(pV), radToDeg(rV),
            radToDeg(yR), radToDeg(pR), radToDeg(rR),
            static_cast<unsigned long long>(snap.samples));
        std::fflush(stderr);
    }
    std::fprintf(stderr, "\n");
}

} // namespace

int main() {
    std::signal(SIGINT, onSigint);

    // Restore the user's saved slot layout (if any) before anything reads it.
    ConfigStore::load();

    unsigned int v = Rayneo_GetApiVersion();
    std::fprintf(stderr,
        "RayNeoSpatial — build: robust AX window-move + file log (B22)\n"
        "RayNeo SDK API version: %u.%u\n\n",
        (v >> 16) & 0xFFFF, v & 0xFFFF);

    auto displays = DisplayLocator::enumerate();
    std::fprintf(stderr, "=== Displays ===\n");
    for (const auto& d : displays) {
        std::fprintf(stderr, "  id=%-8u %s %-30s %dx%d @ %.0fHz\n",
            d.displayID, d.isBuiltin ? "[builtin] " : "[external]",
            d.name.c_str(), d.pixelWidth, d.pixelHeight, d.refreshHz);
    }
    DisplayInfo glasses = DisplayLocator::findGlasses();
    if (glasses.displayID == 0) {
        std::fprintf(stderr, "Error: no glasses display detected.\n"
                             "Connect the RayNeo glasses via USB-C and ensure "
                             "the display is extended (not mirrored).\n");
        return 1;
    }
    std::fprintf(stderr,
        "--> Targeting glasses display: id=%u %s %dx%d @ %.0fHz\n\n",
        glasses.displayID, glasses.name.c_str(),
        glasses.pixelWidth, glasses.pixelHeight, glasses.refreshHz);

    ImuService imu;
    int rc = imu.start();
    if (rc != 0) {
        std::fprintf(stderr,
            "Failed to start IMU service (rc=%d).\n", rc);
        return 1;
    }

    std::thread hb(heartbeat, &imu);

    int appRc = runApp(imu, glasses);

    g_keepLogging.store(false);
    if (hb.joinable()) hb.join();
    imu.stop();
    return appRc;
}
