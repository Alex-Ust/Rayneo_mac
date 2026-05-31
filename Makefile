# RayNeoSpatial — C++/Obj-C++ build via clang directly (no Xcode/SwiftPM).

PROJECT      := RayNeoSpatial
BUILD_DIR    := build
BIN          := $(BUILD_DIR)/$(PROJECT)

FRAMEWORKS_DIR := Frameworks
DYLIB          := libRayNeoSDK.dylib
INCLUDE_DIR    := include

# Code-signing identity. If the stable self-signed cert exists (created by
# `make signing`), use it so TCC permissions persist across rebuilds;
# otherwise fall back to ad-hoc (-), which re-prompts every build.
CERT_NAME := RayNeoSpatial Self-Signed
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "$(CERT_NAME)" && echo "$(CERT_NAME)" || echo -)

# Find C++/Obj-C++ sources.
CPP_SRCS := $(shell find src -name '*.cpp')
MM_SRCS  := $(shell find src -name '*.mm')

# Object file paths (mirror src/ tree under build/obj/).
CPP_OBJS := $(CPP_SRCS:%.cpp=$(BUILD_DIR)/obj/%.cpp.o)
MM_OBJS  := $(MM_SRCS:%.mm=$(BUILD_DIR)/obj/%.mm.o)
OBJS     := $(CPP_OBJS) $(MM_OBJS)

# Tools.
CXX      := clang++
TARGET   ?= arm64-apple-macosx14.0

# Compile flags.
COMMON_CXXFLAGS := \
    -std=c++17 \
    -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers \
    -O0 -g \
    -fno-omit-frame-pointer \
    -MMD -MP \
    -I $(INCLUDE_DIR) \
    -I src \
    -target $(TARGET)

CPP_CXXFLAGS := $(COMMON_CXXFLAGS)
MM_CXXFLAGS  := $(COMMON_CXXFLAGS) -fobjc-arc

# Link flags. rpath @loader_path lets us ship libRayNeoSDK.dylib next to the binary.
LDFLAGS := \
    -L $(FRAMEWORKS_DIR) -lRayNeoSDK \
    -Xlinker -rpath -Xlinker @loader_path \
    -framework Foundation \
    -framework AppKit \
    -framework CoreGraphics \
    -framework IOKit \
    -framework Metal \
    -framework MetalKit \
    -framework QuartzCore \
    -framework ScreenCaptureKit \
    -framework CoreMedia \
    -framework CoreVideo

APP_BUNDLE := $(BUILD_DIR)/RayNeoSpatial.app

.PHONY: all build run clean app runapp signing
all: build

# One-time: create the stable self-signed signing identity.
signing:
	@bash scripts/setup-signing.sh

build: $(BIN)

$(BIN): $(OBJS) $(FRAMEWORKS_DIR)/$(DYLIB)
	@mkdir -p $(BUILD_DIR)
	$(CXX) -target $(TARGET) $(OBJS) $(LDFLAGS) -o $@
	@cp -f $(FRAMEWORKS_DIR)/$(DYLIB) $(BUILD_DIR)/
	@# macOS 26 enforces strict dylib signatures even for ad-hoc; strip the
	@# Chrome download quarantine and re-sign so dyld accepts the lib.
	@xattr -dr com.apple.quarantine $(BUILD_DIR)/$(DYLIB) 2>/dev/null || true
	@codesign -s "$(SIGN_ID)" -f $(BUILD_DIR)/$(DYLIB) >/dev/null
	@codesign -s "$(SIGN_ID)" -f $@ >/dev/null

$(BUILD_DIR)/obj/%.cpp.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CPP_CXXFLAGS) -c $< -o $@

$(BUILD_DIR)/obj/%.mm.o: %.mm
	@mkdir -p $(dir $@)
	$(CXX) $(MM_CXXFLAGS) -c $< -o $@

run: build
	@$(BIN)

# Assemble a proper .app bundle. The stable CFBundleIdentifier means macOS
# keeps Screen-Recording / Accessibility grants across rebuilds (TCC keys on
# the bundle id), so you grant permissions once instead of every build.
app: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	@cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@cp $(BIN) $(APP_BUNDLE)/Contents/MacOS/RayNeoSpatial
	@cp $(FRAMEWORKS_DIR)/$(DYLIB) $(APP_BUNDLE)/Contents/Frameworks/
	@# The binary's rpath is @loader_path (next to the exe). Add the bundle's
	@# Frameworks dir so the dylib resolves inside the .app too.
	@install_name_tool -add_rpath @executable_path/../Frameworks \
		$(APP_BUNDLE)/Contents/MacOS/RayNeoSpatial 2>/dev/null || true
	@xattr -dr com.apple.quarantine $(APP_BUNDLE) 2>/dev/null || true
	@codesign -s "$(SIGN_ID)" -f $(APP_BUNDLE)/Contents/Frameworks/$(DYLIB) >/dev/null
	@codesign -s "$(SIGN_ID)" -f --identifier com.rayneo.spatial \
		$(APP_BUNDLE)/Contents/MacOS/RayNeoSpatial >/dev/null
	@codesign -s "$(SIGN_ID)" -f --deep $(APP_BUNDLE) >/dev/null
	@echo "Built $(APP_BUNDLE)  (signed: $(SIGN_ID))"

# Build the bundle and launch it.
runapp: app
	@open $(APP_BUNDLE)

clean:
	rm -rf $(BUILD_DIR)

# Pick up generated header-dependency files so editing a header triggers a rebuild.
-include $(OBJS:.o=.d)
