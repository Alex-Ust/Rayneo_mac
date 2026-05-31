# RayNeoSpatial — C++/Obj-C++ build via clang directly (no Xcode/SwiftPM).

PROJECT      := RayNeoSpatial
BUILD_DIR    := build
BIN          := $(BUILD_DIR)/$(PROJECT)

FRAMEWORKS_DIR := Frameworks
DYLIB          := libRayNeoSDK.dylib
INCLUDE_DIR    := include

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
    -Wall -Wextra -Wno-unused-parameter \
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
    -framework QuartzCore

.PHONY: all build run clean
all: build

build: $(BIN)

$(BIN): $(OBJS) $(FRAMEWORKS_DIR)/$(DYLIB)
	@mkdir -p $(BUILD_DIR)
	$(CXX) -target $(TARGET) $(OBJS) $(LDFLAGS) -o $@
	@cp -f $(FRAMEWORKS_DIR)/$(DYLIB) $(BUILD_DIR)/
	@# macOS 26 enforces strict dylib signatures even for ad-hoc; strip the
	@# Chrome download quarantine and re-sign so dyld accepts the lib.
	@xattr -dr com.apple.quarantine $(BUILD_DIR)/$(DYLIB) 2>/dev/null || true
	@codesign -s - -f $(BUILD_DIR)/$(DYLIB) >/dev/null
	@codesign -s - -f $@ >/dev/null

$(BUILD_DIR)/obj/%.cpp.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CPP_CXXFLAGS) -c $< -o $@

$(BUILD_DIR)/obj/%.mm.o: %.mm
	@mkdir -p $(dir $@)
	$(CXX) $(MM_CXXFLAGS) -c $< -o $@

run: build
	@$(BIN)

clean:
	rm -rf $(BUILD_DIR)

# Pick up generated header-dependency files so editing a header triggers a rebuild.
-include $(OBJS:.o=.d)
