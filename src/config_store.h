#pragma once

namespace rns {

/// Persist the slot layout (poses, source, appName, visibility) to a plist in
/// ~/Library/Application Support/RayNeoSpatial/layout.plist. Filter tunables
/// (axis signs, alpha, FOV) are intentionally not persisted — only the
/// user-facing layout.
class ConfigStore {
public:
    /// Load layout into the global Config if a saved file exists. No-op
    /// otherwise (defaults remain). Returns true if a file was loaded.
    static bool load();

    /// Save the current global Config layout. Returns true on success.
    static bool save();
};

} // namespace rns
