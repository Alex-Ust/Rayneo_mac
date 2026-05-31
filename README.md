# RayNeoSpatial (macOS, C++/Obj-C++)

Native macOS app for the **RayNeo Air 3s Pro** glasses: head-tracked
floating virtual screens. The plan it implements is in
`../RayNeo-Spatial-Mac-PLAN.md`. This directory holds the in-progress
implementation.

## Current status

| Milestone | What | Status |
| --------- | ---- | ------ |
| M0 | CLI: SDK link, live head orientation print, identify glasses display | ✅ done |
| M1 | Borderless fullscreen Metal window on the glasses display | ✅ done |
| M2 | ScreenCaptureKit → Metal texture, head-tracked perspective camera | ✅ done |
| M3 | Three quads, configurable poses, hotkeys (Phase 1 acceptance) | ✅ done |

## Why not Swift / Xcode?

The plan asks for Swift + Metal + AppKit. The Command Line Tools on this
Mac (macOS 26.5 / SDK 15.2) ship a mismatched SwiftPM
PackageDescription (`SwiftVersion` vs `SwiftLanguageMode` symbol divergence)
and a mismatched compiler/SDK swiftlang minor build, so `swift build` and
`swiftc` both fail before reaching the project code. C/C++/Obj-C++ via
`clang++` work fine, and the user's existing upstream `orientation_demo`
already validated that path, so the implementation is in C++/Obj-C++.

Switch back to Swift if a full Xcode is installed — the algorithms in
`src/tracking/` translate line-for-line.

## Build / run

Requirements:
- macOS 14+ on Apple Silicon (tested on macOS 26.5)
- Xcode Command Line Tools (`xcode-select --install`)
- `brew install libusb` — the SDK dylib has a hard link to
  `/opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib`.

```sh
make build       # ./build/RayNeoSpatial + libRayNeoSDK.dylib next to it
./build/RayNeoSpatial
```

Hotkeys — all chords use **⌃⌥ (Control+Option)** and work GLOBALLY (even
while you're typing in another app), once you grant Accessibility access
(System Settings ▸ Privacy & Security ▸ Accessibility, then relaunch).

| Action | Keys |
| --- | --- |
| Select slot 1 / 2 / 3 | `⌃⌥1` / `⌃⌥2` / `⌃⌥3` |
| Cycle selection | `⌃⌥[` / `⌃⌥]` |
| Move selected left / right (azimuth) | `⌃⌥A` / `⌃⌥D` |
| Move selected up / down (elevation) | `⌃⌥W` / `⌃⌥S` |
| Move selected nearer / farther | `⌃⌥-` / `⌃⌥=` |
| Recenter (bring screens to your gaze) | `⌃⌥R` |
| Hide / show selected | `⌃⌥V` |
| Add a screen | `⌃⌥N` |
| Remove selected screen | `⌃⌥X` |
| Pin frontmost app to selected slot | `⌃⌥P` |
| Revert selected slot to a virtual screen | `⌃⌥O` |
| Toggle yaw / pitch tracking | `⌃⌥Y` / `⌃⌥G` |
| Quit | `⌘Q` or `Esc` (app focused) |

The selected screen shows a cyan border. Layout (positions, sizes,
which slot is an app vs a screen, count) is saved on quit to
`~/Library/Application Support/RayNeoSpatial/layout.plist` and restored
on next launch. The terminal also prints a live yaw/pitch/roll heartbeat.

## Architecture

```
   RayNeo IMU --(USB libusb)--> libRayNeoSDK.dylib
                                       │
                                       │  Rayneo_PollEvent (5 ms timeout)
                                       ▼
              src/tracking/imu_service.cpp        (background thread)
                                       │
                                       ▼
              src/tracking/orientation_filter.*    (complementary filter:
                                                    integrate gyro,
                                                    pitch+roll → accel gravity)
                                       │
                                       ▼
              src/tracking/smooth_follow.*         (drift/jitter mask + recenter)
                                       │
                                       ▼          snapshot() under mutex
                                  Render thread
                                  (src/app/scene.mm — Metal pipeline; one
                                   textured quad per configured screen pose)
                                       ▲
                                       │
       ScreenCaptureKit ─ src/capture/capture_source.mm ─┘
       (CVPixelBuffer → CVMetalTextureCache, zero-copy)
```

`src/display/display_locator.mm` enumerates the macOS display tree via
CoreGraphics and identifies the glasses by name hint
(`SmartGlasses` / `RayNeo`) or by resolution heuristic
(non-builtin + matching WxH).

## Notes on SDK usage (learned from the prebuilt example)

The prebuilt SDK on this machine expects a **specific calling sequence**
that differs from the plan's recommendation:

- **Target VID/PID must be set explicitly.** `AUTODETECT` does not find
  the device.  `Rayneo_SetTargetVidPid(ctx, 0x1bbb, 0xaf50)` before
  `Rayneo_Start` (the value comes from disassembling
  `package/examples/RayNeoExample`).
- **Service flags = 0.** `ASYNC_IMU` *suppresses* `IMU_SAMPLE` events in
  this build — they only flow through `Rayneo_PollEvent` if no service
  flags are set.
- **Use `Rayneo_PollEvent`, not the event callback.** Issuing
  `Rayneo_EnableImu` from inside the SDK's own event callback fails with
  `RAYNEO_ERR_IO` (-4); doing it from the poll loop succeeds.
- **The dylib must be re-signed.** macOS 26 rejects the upstream dylib
  signature; `codesign -s - -f` ad-hoc resigning is mandatory.  The
  Makefile does this automatically.

## First-run permission

On the very first launch macOS will block ScreenCaptureKit and queue a
prompt. The app keeps running and shows procedural textures on the
center quad. To switch to the live desktop:

1. Open **System Settings → Privacy & Security → Screen Recording**.
2. Enable `RayNeoSpatial` (or `RayNeoSpatial` in the toggle list).
3. Quit and re-launch the app.

On launch the app picks the three biggest on-screen windows (excluding
its own) and routes each onto a quad. If fewer than three windows are
captureable, the remaining quads mirror the built-in display so all
three panels stay visible. The console prints the captured window
titles + sizes at startup.

## Project layout

```
RayNeoSpatial/
├── Frameworks/libRayNeoSDK.dylib   # the SDK (bundled, re-signed in build/)
├── include/rayneo_api.h            # SDK public header
├── src/
│   ├── config.h                    # runtime tunables (filter α, thresholds…)
│   ├── main.cpp                    # M0 entry: banner, CLI, status print
│   ├── tracking/
│   │   ├── quat.h                  # Quat / Vec3 math
│   │   ├── orientation_filter.*    # complementary filter
│   │   ├── smooth_follow.*         # drift/jitter mask + recenter
│   │   └── imu_service.*           # SDK lifecycle + poll thread
│   └── display/
│       ├── display_locator.h
│       └── display_locator.mm      # CoreGraphics + NSScreen
└── Makefile                        # clang++/clang -ObjC++ with -MMD dep tracking
```
