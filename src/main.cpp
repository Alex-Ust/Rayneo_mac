#include "config.h"
#include "tracking/imu_service.h"
#include "display/display_locator.h"
#include "rayneo_api.h"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <iostream>

using namespace rns;

namespace {

std::atomic<bool> g_running{true};

void onSigint(int) { g_running.store(false); }

void stdinThread(ImuService& imu) {
    std::string line;
    while (std::getline(std::cin, line)) {
        // trim + lowercase
        auto begin = line.find_first_not_of(" \t\r\n");
        auto end   = line.find_last_not_of(" \t\r\n");
        std::string cmd = (begin == std::string::npos) ? "" : line.substr(begin, end - begin + 1);
        for (auto& c : cmd) c = std::tolower(static_cast<unsigned char>(c));

        if (cmd == "r") {
            imu.recenter();
            std::printf("\n[recentered]\n");
        } else if (cmd == "reset") {
            imu.resetFilter();
            std::printf("\n[filter reset]\n");
        } else if (cmd == "q" || cmd == "quit" || cmd == "exit") {
            g_running.store(false);
            return;
        } else if (!cmd.empty()) {
            std::printf("\n[?] unknown command: %s\n", cmd.c_str());
        }
    }
}

} // namespace

int main() {
    std::signal(SIGINT, onSigint);

    unsigned int apiVersion = Rayneo_GetApiVersion();
    unsigned int major = (apiVersion >> 16) & 0xFFFF;
    unsigned int minor =  apiVersion        & 0xFFFF;
    std::printf("RayNeoSpatial — M0\n");
    std::printf("RayNeo SDK API version: %u.%u\n\n", major, minor);

    std::printf("=== Connected displays ===\n");
    auto displays = DisplayLocator::enumerate();
    for (const auto& d : displays) {
        const char* tag = d.isBuiltin ? "[builtin]" : "[external]";
        std::printf("  id=%-8u %s %-30s %dx%d @ %.0fHz\n",
                    d.displayID, tag, d.name.c_str(),
                    d.pixelWidth, d.pixelHeight, d.refreshHz);
    }
    DisplayInfo glasses = DisplayLocator::findGlasses();
    if (glasses.displayID != 0) {
        std::printf("--> Glasses candidate: id=%u %s  %dx%d @ %.0fHz\n",
                    glasses.displayID, glasses.name.c_str(),
                    glasses.pixelWidth, glasses.pixelHeight, glasses.refreshHz);
    } else {
        std::printf("--> No external glasses display detected.\n");
    }
    std::printf("\n");

    ImuService imu;
    int rc = imu.start();
    if (rc != 0) {
        std::fprintf(stderr, "Failed to start IMU service (rc=%d). "
                             "Is the device connected and libusb available?\n", rc);
        return 1;
    }

    std::printf("IMU service running. Commands (type + Enter):\n");
    std::printf("  r       recenter\n");
    std::printf("  reset   reset filter to identity\n");
    std::printf("  q       quit\n");
    std::printf("Waiting for samples…\n\n");

    std::thread reader(stdinThread, std::ref(imu));
    reader.detach();

    uint64_t lastSamples = 0;
    auto lastWall = std::chrono::steady_clock::now();
    while (g_running.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        auto snap = imu.snapshot();
        float yawV, pitchV, rollV;
        float yawR, pitchR, rollR;
        snap.view.toYPR(yawV, pitchV, rollV); // smoothed + recentered
        snap.raw.toYPR(yawR, pitchR, rollR);  // raw filter output

        auto now = std::chrono::steady_clock::now();
        double dt = std::chrono::duration<double>(now - lastWall).count();
        if (dt < 0.001) dt = 0.001;
        uint64_t dN = snap.samples - lastSamples;
        double hz = static_cast<double>(dN) / dt;
        lastSamples = snap.samples;
        lastWall = now;

        const char* attached = snap.attached ? "att" : "DET";
        std::printf("\r[%s %5.0fHz] view y=%+6.1f° p=%+6.1f° r=%+6.1f°  "
                    "raw y=%+6.1f° p=%+6.1f° r=%+6.1f°  gyro=%5.1f°/s  n=%llu   ",
                    attached, hz,
                    radToDeg(yawV), radToDeg(pitchV), radToDeg(rollV),
                    radToDeg(yawR), radToDeg(pitchR), radToDeg(rollR),
                    snap.gyroDps,
                    static_cast<unsigned long long>(snap.samples));
        std::fflush(stdout);
    }

    std::printf("\nStopping…\n");
    imu.stop();
    std::printf("Bye.\n");
    return 0;
}
