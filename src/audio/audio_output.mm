#include "audio_output.h"
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#include <cstdio>

namespace {

constexpr AudioObjectPropertyAddress kDevicesAddr = {
    kAudioHardwarePropertyDevices,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain
};
constexpr AudioObjectPropertyAddress kDefaultOutAddr = {
    kAudioHardwarePropertyDefaultOutputDevice,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain
};

bool deviceHasOutput(AudioDeviceID dev) {
    AudioObjectPropertyAddress a = {
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, nullptr, &size) != noErr)
        return false;
    return size > 0;
}

std::string deviceName(AudioDeviceID dev) {
    AudioObjectPropertyAddress a = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef name = nullptr;
    UInt32 size = sizeof(name);
    if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, &name) != noErr
        || !name)
        return "Unknown";
    char buf[256];
    if (!CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8)) {
        CFRelease(name);
        return "Unknown";
    }
    CFRelease(name);
    return std::string(buf);
}

bool deviceIsBuiltin(AudioDeviceID dev) {
    AudioObjectPropertyAddress a = {
        kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 transport = 0, size = sizeof(transport);
    if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, &transport) != noErr)
        return false;
    return transport == kAudioDeviceTransportTypeBuiltIn;
}

AudioDeviceID currentDefaultOutput() {
    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &kDefaultOutAddr,
                               0, nullptr, &size, &dev);
    return dev;
}

} // namespace

namespace rns {

std::vector<AudioDevice> listOutputDevices() {
    std::vector<AudioDevice> out;
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &kDevicesAddr,
                                       0, nullptr, &size) != noErr || size == 0)
        return out;
    int count = (int)(size / sizeof(AudioDeviceID));
    std::vector<AudioDeviceID> ids(count);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &kDevicesAddr,
                                   0, nullptr, &size, ids.data()) != noErr)
        return out;

    AudioDeviceID def = currentDefaultOutput();
    for (AudioDeviceID id : ids) {
        if (!deviceHasOutput(id)) continue;
        AudioDevice d;
        d.id        = (uint32_t)id;
        d.name      = deviceName(id);
        d.isDefault = (id == def);
        d.isBuiltin = deviceIsBuiltin(id);
        out.push_back(std::move(d));
    }
    return out;
}

bool setDefaultOutputDevice(uint32_t deviceID) {
    AudioDeviceID dev = (AudioDeviceID)deviceID;
    OSStatus s = AudioObjectSetPropertyData(
        kAudioObjectSystemObject, &kDefaultOutAddr,
        0, nullptr, sizeof(dev), &dev);
    if (s != noErr) {
        std::fprintf(stderr, "setDefaultOutputDevice failed: %d\n", (int)s);
        return false;
    }
    return true;
}

} // namespace rns
