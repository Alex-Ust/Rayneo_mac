#include "smooth_follow.h"
#include "../config.h"

namespace rns {

Quat SmoothFollow::process(Quat orientation, float gyroDps) {
    const Config& cfg = config();
    if (frozen_) {
        if (gyroDps > cfg.smoothFollowStartDps) {
            frozen_ = false;
            stillFrames_ = 0;
            return orientation;
        }
        return held_;
    } else {
        if (gyroDps < cfg.smoothFollowStopDps) {
            ++stillFrames_;
            if (stillFrames_ >= cfg.smoothFollowStopFrames) {
                frozen_ = true;
                held_ = orientation;
            }
        } else {
            stillFrames_ = 0;
        }
        return orientation;
    }
}

} // namespace rns
