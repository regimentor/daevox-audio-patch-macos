// AudioPatch HAL plug-in. Original implementation; no third-party driver code.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <atomic>
#include <array>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>
#include <bit>

namespace {
constexpr UInt32 configProperty = 'apcf', statsProperty = 'apst';
constexpr UInt32 slots = 8, maxChannels = 16, ringFrames = 32768;
constexpr UInt32 delayFrames = 1024, clockPeriod = 16384;
constexpr Float64 rate = 48000;
static_assert(std::atomic<UInt64>::is_always_lock_free);
struct Device {
    std::atomic<bool> active{false};
    std::atomic<UInt32> channels{2}, clients{0};
    std::atomic<UInt64> missingFrames{0}, writtenFrames{0};
    std::atomic<int64_t> writtenEnd{INT64_MIN};
    CFStringRef uid = nullptr, name = nullptr;
    // Atomically pack frame timestamp + Float32 bits. No racing non-atomic sample memory.
    std::unique_ptr<std::atomic<UInt64>[]> ring;
};
std::array<Device, slots> devices;
std::mutex stateMutex; // control/property plane ONLY
std::atomic<UInt32> references{1};
AudioServerPlugInHostRef host = nullptr;
CFArrayRef configuration = nullptr;
UInt64 anchor = 0;
double ticksPerFrame = 0;
AudioObjectID deviceID(unsigned slot) { return 2 + slot * 3; }
Device* deviceFor(AudioObjectID id) {
    if(id < 2 || id >= 2 + slots * 3) return nullptr;
    auto& d = devices[(id - 2) / 3];
    return d.active.load(std::memory_order_acquire) ? &d : nullptr;
}
bool isDevice(AudioObjectID id) { return id >= 2 && (id - 2) % 3 == 0; }
bool isInput(AudioObjectID id) { return id >= 2 && (id - 2) % 3 == 1; }
AudioStreamBasicDescription format(UInt32 channels) {
    return {rate, kAudioFormatLinearPCM, kAudioFormatFlagsNativeFloatPacked,
        4 * channels, 1, 4 * channels, channels, 32, 0};
}
OSStatus copyBytes(UInt32 capacity, UInt32* size, void* output, const void* value, UInt32 bytes) {
    if(!size) return kAudioHardwareIllegalOperationError;
    *size = bytes;
    if(!output) return noErr;
    if(capacity < bytes) return kAudioHardwareBadPropertySizeError;
    if(bytes) std::memcpy(output, value, bytes);
    return noErr;
}
template<class T> OSStatus scalar(UInt32 capacity, UInt32* size, void* output, const T& value) {
    return copyBytes(capacity, size, output, &value, sizeof(T));
}
OSStatus cfValue(UInt32 capacity, UInt32* size, void* output, CFTypeRef value) {
    if(output && capacity >= sizeof(value) && value) CFRetain(value);
    return scalar(capacity, size, output, value);
}
std::vector<AudioObjectID> ids(AudioObjectID object, AudioObjectPropertyScope scope, bool owned) {
    std::vector<AudioObjectID> result;
    if(object == kAudioObjectPlugInObject) {
        for(unsigned i = 0; i < slots; ++i) if(devices[i].active.load()) result.push_back(deviceID(i));
    } else if(isDevice(object)) {
        if(owned || scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput) result.push_back(object + 1);
        if(owned || scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeOutput) result.push_back(object + 2);
    }
    return result;
}
CFStringRef dictionaryString(CFDictionaryRef dict, CFStringRef key) {
    auto v = CFDictionaryGetValue(dict, key);
    return v && CFGetTypeID(v) == CFStringGetTypeID() ? (CFStringRef)v : nullptr;
}
OSStatus applyConfiguration(CFTypeRef value, bool persist) {
    // Called under control-plane mutex. No device changes while any IO client is running.
    if(!value || CFGetTypeID(value) != CFArrayGetTypeID()) return kAudioHardwareIllegalOperationError;
    auto array = (CFArrayRef)value;
    if(configuration && CFEqual(configuration, array)) return noErr;
    auto count = CFArrayGetCount(array);
    if(count > slots) return kAudioHardwareIllegalOperationError;
    for(auto& d : devices) if(d.clients.load() != 0) return kAudioHardwareIllegalOperationError;
    std::vector<CFStringRef> uids, names;
    std::vector<UInt32> channels;
    for(CFIndex i = 0; i < count; ++i) {
        auto entry = CFArrayGetValueAtIndex(array, i);
        if(CFGetTypeID(entry) != CFDictionaryGetTypeID()) return kAudioHardwareIllegalOperationError;
        auto dict = (CFDictionaryRef)entry;
        auto uid = dictionaryString(dict, CFSTR("uid"));
        auto name = dictionaryString(dict, CFSTR("name"));
        auto n = CFDictionaryGetValue(dict, CFSTR("channels"));
        int ch = 0;
        if(!uid || !name || CFStringGetLength(uid) < 1 || CFStringGetLength(uid) > 240 ||
           CFStringGetLength(name) < 1 || CFStringGetLength(name) > 240 || !n ||
           CFGetTypeID(n) != CFNumberGetTypeID() || !CFNumberGetValue((CFNumberRef)n, kCFNumberIntType, &ch) ||
           ch < 1 || ch > maxChannels) return kAudioHardwareIllegalOperationError;
        for(auto previous : uids) if(CFEqual(previous, uid)) return kAudioHardwareIllegalOperationError;
        // Channel layout is immutable for a UID. A new layout must be a new device.
        // This avoids changing stream structure without HAL configuration arbitration.
        for(auto& d : devices) if(d.uid && CFEqual(d.uid, uid) && d.channels.load() != UInt32(ch))
            return kAudioHardwareIllegalOperationError;
        uids.push_back(uid); names.push_back(name); channels.push_back(ch);
    }
    if(persist && host) {
        auto status = host->WriteToStorage(host, CFSTR("AudioPatchDevicesV1"), array);
        if(status != noErr) return status;
    }
    // Keep stable object IDs for retained UIDs. Allocate new UIDs to unused slots.
    std::array<int, slots> assignment; assignment.fill(-1);
    std::array<bool, slots> used{};
    for(size_t i = 0; i < uids.size(); ++i) {
        for(unsigned j = 0; j < slots; ++j) if(devices[j].uid && CFEqual(devices[j].uid, uids[i])) {
            assignment[i] = (int)j; used[j] = true; break;
        }
    }
    for(size_t i = 0; i < uids.size(); ++i) if(assignment[i] < 0) {
        for(unsigned j = 0; j < slots; ++j) if(!used[j]) { assignment[i] = (int)j; used[j] = true; break; }
    }
    for(auto& d : devices) d.active.store(false, std::memory_order_release);
    for(size_t i = 0; i < uids.size(); ++i) {
        auto& d = devices[assignment[i]];
        auto uid = (CFStringRef)CFRetain(uids[i]);
        auto name = (CFStringRef)CFRetain(names[i]);
        if(d.uid) CFRelease(d.uid);
        if(d.name) CFRelease(d.name);
        d.uid = uid; d.name = name; d.channels.store(channels[i]);
        for(unsigned k = 0; k < ringFrames * maxChannels; ++k) d.ring[k].store(UINT64_MAX, std::memory_order_relaxed);
        d.writtenEnd.store(INT64_MIN);
        d.active.store(true, std::memory_order_release);
    }
    auto saved = (CFArrayRef)CFPropertyListCreateDeepCopy(nullptr, array, kCFPropertyListImmutable);
    if(configuration) CFRelease(configuration);
    configuration = saved;
    return noErr;
}

OSStatus getProperty(AudioObjectID object, const AudioObjectPropertyAddress* a,
    UInt32 qualifierSize, const void* qualifier, UInt32 capacity, UInt32* size, void* output) {
    if(!a || !size) return kAudioHardwareIllegalOperationError;
    std::lock_guard lock(stateMutex);
    Device* d = deviceFor(object);
    bool plugin = object == kAudioObjectPlugInObject;
    if(!plugin && !d) return kAudioHardwareBadObjectError;
    bool dev = !plugin && isDevice(object);
    UInt32 channels = d ? d->channels.load() : 0;
    auto prop = a->mSelector;
    switch(prop) {
        case kAudioObjectPropertyBaseClass:
            return scalar(capacity, size, output, UInt32(kAudioObjectClassID));
        case kAudioObjectPropertyClass:
            return scalar(capacity, size, output, (plugin ? UInt32(kAudioPlugInClassID) : dev ? UInt32(kAudioDeviceClassID) : UInt32(kAudioStreamClassID)));
        case kAudioObjectPropertyOwner:
            return scalar(capacity, size, output, UInt32(plugin ? kAudioObjectUnknown : dev ? kAudioObjectPlugInObject : 2 + ((object - 2) / 3) * 3));
        case kAudioObjectPropertyName:
            return cfValue(capacity, size, output, plugin ? CFSTR("AudioPatch") : d->name);
        case kAudioObjectPropertyManufacturer:
            return cfValue(capacity, size, output, CFSTR("AudioPatch"));
        case kAudioObjectPropertyOwnedObjects: {
            auto list = ids(object, a->mScope, true);
            // Optional qualifier filters AudioClassIDs.
            if(qualifierSize && qualifier) {
                auto wanted = (const AudioClassID*)qualifier;
                auto cls = plugin ? UInt32(kAudioDeviceClassID) : UInt32(kAudioStreamClassID);
                if(std::find(wanted, wanted + qualifierSize / sizeof(AudioClassID), cls) == wanted + qualifierSize / sizeof(AudioClassID)) list.clear();
            }
            return copyBytes(capacity, size, output, list.data(), UInt32(list.size() * sizeof(AudioObjectID)));
        }
    }
    if(plugin) switch(prop) {
        case kAudioPlugInPropertyBundleID: return cfValue(capacity, size, output, CFSTR("audio.audio-patch.driver"));
        case kAudioPlugInPropertyResourceBundle: return cfValue(capacity, size, output, CFSTR(""));
        case kAudioPlugInPropertyDeviceList: {
            auto list = ids(object, a->mScope, false);
            return copyBytes(capacity, size, output, list.data(), UInt32(list.size() * sizeof(AudioObjectID)));
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID result = kAudioObjectUnknown;
            if(qualifier && qualifierSize == sizeof(CFStringRef)) {
                auto uid = *(const CFStringRef*)qualifier;
                if(uid && CFGetTypeID(uid) == CFStringGetTypeID())
                    for(unsigned i = 0; i < slots; ++i) if(devices[i].active.load() && CFEqual(devices[i].uid, uid)) result = deviceID(i);
            }
            return scalar(capacity, size, output, result);
        }
        case kAudioObjectPropertyCustomPropertyInfoList: {
            AudioServerPlugInCustomPropertyInfo info{configProperty, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone};
            return scalar(capacity, size, output, info);
        }
        case configProperty: return cfValue(capacity, size, output, configuration);
    }
    else if(dev) switch(prop) {
        case kAudioDevicePropertyDeviceUID: return cfValue(capacity, size, output, d->uid);
        case kAudioDevicePropertyModelUID: return cfValue(capacity, size, output, CFSTR("audio.audio-patch.model.v1"));
        case kAudioDevicePropertyTransportType: return scalar(capacity, size, output, UInt32(kAudioDeviceTransportTypeVirtual));
        case kAudioDevicePropertyClockDomain: return scalar(capacity, size, output, UInt32(0));
        case kAudioDevicePropertyDeviceIsAlive: return scalar(capacity, size, output, UInt32(1));
        case kAudioDevicePropertyDeviceIsRunning: return scalar(capacity, size, output, UInt32(d->clients.load() > 0));
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: return scalar(capacity, size, output, UInt32(a->mScope == kAudioObjectPropertyScopeInput));
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertySafetyOffset: return scalar(capacity, size, output, UInt32(0));
        case kAudioDevicePropertyLatency: return scalar(capacity, size, output, UInt32(a->mScope == kAudioObjectPropertyScopeInput ? delayFrames : 0));
        case kAudioDevicePropertyStreams: {
            auto list = ids(object, a->mScope, false);
            return copyBytes(capacity, size, output, list.data(), UInt32(list.size() * sizeof(AudioObjectID)));
        }
        case kAudioObjectPropertyControlList: return copyBytes(capacity, size, output, nullptr, 0);
        case kAudioDevicePropertyNominalSampleRate: return scalar(capacity, size, output, rate);
        case kAudioDevicePropertyAvailableNominalSampleRates: return scalar(capacity, size, output, AudioValueRange{rate, rate});
        case kAudioDevicePropertyZeroTimeStampPeriod: return scalar(capacity, size, output, clockPeriod);
        case kAudioDevicePropertyClockAlgorithm: return scalar(capacity, size, output, UInt32(kAudioDeviceClockAlgorithmRaw));
        case kAudioDevicePropertyClockIsStable: return scalar(capacity, size, output, UInt32(1));
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            UInt32 pair[2] = {1, std::min(channels, UInt32(2))};
            return copyBytes(capacity, size, output, pair, sizeof(pair));
        }
        case kAudioObjectPropertyCustomPropertyInfoList: {
            AudioServerPlugInCustomPropertyInfo info{statsProperty, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone};
            return scalar(capacity, size, output, info);
        }
        case statsProperty: {
            if(!output) { *size = sizeof(CFPropertyListRef); return noErr; }
            auto dict = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            auto put = [&](CFStringRef key, UInt64 v) { auto n = CFNumberCreate(nullptr, kCFNumberSInt64Type, &v); CFDictionarySetValue(dict, key, n); CFRelease(n); };
            put(CFSTR("missingFrames"), d->missingFrames.load()); put(CFSTR("writtenFrames"), d->writtenFrames.load());
            put(CFSTR("clients"), d->clients.load()); put(CFSTR("delayFrames"), delayFrames);
            auto status = cfValue(capacity, size, output, dict); CFRelease(dict); return status;
        }
    }
    else switch(prop) {
        case kAudioStreamPropertyIsActive: return scalar(capacity, size, output, UInt32(1));
        case kAudioStreamPropertyDirection: return scalar(capacity, size, output, UInt32(isInput(object)));
        case kAudioStreamPropertyTerminalType: return scalar(capacity, size, output, UInt32(isInput(object) ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine));
        case kAudioStreamPropertyStartingChannel: return scalar(capacity, size, output, UInt32(1));
        case kAudioStreamPropertyLatency: return scalar(capacity, size, output, UInt32(0));
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: return scalar(capacity, size, output, format(channels));
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription description{format(channels), {rate, rate}};
            return scalar(capacity, size, output, description);
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

HRESULT query(void*, REFIID uuid, LPVOID* result);
ULONG addRef(void*) { return ++references; }
ULONG release(void*) { auto value = references.load(); while(value > 1 && !references.compare_exchange_weak(value, value - 1)) {} return references.load(); }
OSStatus initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef h) {
    std::lock_guard lock(stateMutex); host = h;
    mach_timebase_info_data_t info; mach_timebase_info(&info);
    ticksPerFrame = (1e9 * info.denom / info.numer) / rate; anchor = mach_absolute_time();
    for(auto& d : devices) {
        d.ring = std::make_unique<std::atomic<UInt64>[]>(ringFrames * maxChannels);
        for(unsigned i = 0; i < ringFrames * maxChannels; ++i) d.ring[i].store(UINT64_MAX);
    }
    CFPropertyListRef stored = nullptr;
    host->CopyFromStorage(host, CFSTR("AudioPatchDevicesV1"), &stored);
    auto status = stored ? applyConfiguration(stored, false) : kAudioHardwareIllegalOperationError;
    if(stored) CFRelease(stored);
    if(status != noErr) configuration = CFArrayCreate(nullptr, nullptr, 0, &kCFTypeArrayCallBacks);
    return noErr;
}
OSStatus create(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*) { return kAudioHardwareUnsupportedOperationError; }
OSStatus destroy(AudioServerPlugInDriverRef, AudioObjectID) { return kAudioHardwareUnsupportedOperationError; }
OSStatus client(AudioServerPlugInDriverRef, AudioObjectID id, const AudioServerPlugInClientInfo*) { return deviceFor(id) && isDevice(id) ? OSStatus(noErr) : OSStatus(kAudioHardwareBadObjectError); }
OSStatus change(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*) { return kAudioHardwareUnsupportedOperationError; }
Boolean has(AudioServerPlugInDriverRef, AudioObjectID id, pid_t, const AudioObjectPropertyAddress* a) {
    UInt32 size = 0; return getProperty(id, a, 0, nullptr, 0, &size, nullptr) == noErr;
}
OSStatus settable(AudioServerPlugInDriverRef driver, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a, Boolean* result) {
    if(!result || !has(driver, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    *result = id == kAudioObjectPlugInObject && a->mSelector == configProperty; return noErr;
}
OSStatus dataSize(AudioServerPlugInDriverRef, AudioObjectID id, pid_t, const AudioObjectPropertyAddress* a, UInt32 qs, const void* q, UInt32* size) {
    return getProperty(id, a, qs, q, 0, size, nullptr);
}
OSStatus data(AudioServerPlugInDriverRef, AudioObjectID id, pid_t, const AudioObjectPropertyAddress* a, UInt32 qs, const void* q, UInt32 cap, UInt32* size, void* out) {
    return getProperty(id, a, qs, q, cap, size, out);
}
OSStatus setData(AudioServerPlugInDriverRef, AudioObjectID id, pid_t, const AudioObjectPropertyAddress* a, UInt32, const void*, UInt32 size, const void* value) {
    if(id != kAudioObjectPlugInObject || !a || a->mSelector != configProperty || !value || size != sizeof(CFPropertyListRef)) return kAudioHardwareIllegalOperationError;
    OSStatus status;
    {
        std::lock_guard lock(stateMutex);
        auto desired = *(CFPropertyListRef const*)value;
        // An idempotent write is not a hardware change. Notifying the host here
        // creates a resync → notification → resync loop in listening clients.
        if(configuration && desired && CFEqual(configuration, desired)) return noErr;
        status = applyConfiguration(desired, true);
    }
    if(status == noErr && host) {
        AudioObjectPropertyAddress addresses[] = {
            {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
            {kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
            {configProperty, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}};
        host->PropertiesChanged(host, kAudioObjectPlugInObject, 3, addresses);
        for(unsigned i = 0; i < slots; ++i) if(devices[i].active.load()) {
            AudioObjectPropertyAddress name{kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            host->PropertiesChanged(host, deviceID(i), 1, &name);
        }
    }
    return status;
}
void notifyRunning(AudioObjectID id) {
    if(host) {
        AudioObjectPropertyAddress a{kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        host->PropertiesChanged(host, id, 1, &a);
    }
}
OSStatus start(AudioServerPlugInDriverRef, AudioObjectID id, UInt32) {
    bool first;
    { std::lock_guard lock(stateMutex); auto d = deviceFor(id);
      if(!d || !isDevice(id)) return kAudioHardwareBadObjectError;
      first = d->clients.fetch_add(1) == 0; }
    if(first) notifyRunning(id);
    return noErr;
}
OSStatus stop(AudioServerPlugInDriverRef, AudioObjectID id, UInt32) {
    bool last;
    { std::lock_guard lock(stateMutex); auto d = deviceFor(id);
      if(!d || !isDevice(id) || d->clients.load() == 0) return kAudioHardwareBadObjectError;
      last = d->clients.fetch_sub(1) == 1; }
    if(last) notifyRunning(id);
    return noErr;
}
OSStatus timestamp(AudioServerPlugInDriverRef, AudioObjectID id, UInt32, Float64* sample, UInt64* time, UInt64* seed) {
    if(!deviceFor(id) || !sample || !time || !seed) return kAudioHardwareBadObjectError;
    auto periods = UInt64(double(mach_absolute_time() - anchor) / (ticksPerFrame * clockPeriod));
    *sample = double(periods * clockPeriod); *time = anchor + UInt64(*sample * ticksPerFrame); *seed = 1; return noErr;
}
OSStatus will(AudioServerPlugInDriverRef, AudioObjectID id, UInt32, UInt32 op, Boolean* yes, Boolean* inplace) {
    if(!deviceFor(id) || !yes || !inplace) return kAudioHardwareBadObjectError;
    *yes = op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix;
    *inplace = true; return noErr;
}
OSStatus boundary(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*) { return noErr; }
OSStatus io(AudioServerPlugInDriverRef, AudioObjectID id, AudioObjectID stream, UInt32, UInt32 op, UInt32 frames,
    const AudioServerPlugInIOCycleInfo* cycle, void* buffer, void*) {
    auto d = deviceFor(id);
    if(!d || !cycle || !buffer || frames > ringFrames) return kAudioHardwareIllegalOperationError;
    UInt32 ch = d->channels.load(std::memory_order_relaxed);
    auto samples = (Float32*)buffer;
    if(op == kAudioServerPlugInIOOperationWriteMix && stream == id + 2) {
        auto t = int64_t(cycle->mOutputTime.mSampleTime);
        for(UInt32 f = 0; f < frames; ++f) for(UInt32 c = 0; c < ch; ++c) {
            auto sampleTime = t + f;
            Float32 value = samples[f * ch + c];
            if(!std::isfinite(value)) value = 0;
            UInt64 packed = (UInt64(UInt32(sampleTime)) << 32) | std::bit_cast<UInt32>(value);
            d->ring[(UInt64(sampleTime) % ringFrames) * maxChannels + c].store(packed, std::memory_order_release);
        }
        d->writtenEnd.store(t + frames, std::memory_order_release);
        d->writtenFrames.fetch_add(frames, std::memory_order_relaxed);
    } else if(op == kAudioServerPlugInIOOperationReadInput && stream == id + 1) {
        auto t = int64_t(cycle->mInputTime.mSampleTime) - delayFrames;
        UInt64 missing = 0;
        const auto end = d->writtenEnd.load(std::memory_order_acquire);
        for(UInt32 f = 0; f < frames; ++f) {
            bool absent = false;
            for(UInt32 c = 0; c < ch; ++c) {
                auto sampleTime = t + f;
                UInt64 packed = d->ring[(UInt64(sampleTime) % ringFrames) * maxChannels + c].load(std::memory_order_acquire);
                bool valid = sampleTime >= 0 && end != INT64_MIN && sampleTime < end && sampleTime >= end - ringFrames &&
                    UInt32(packed >> 32) == UInt32(sampleTime);
                samples[f * ch + c] = valid ? std::bit_cast<Float32>(UInt32(packed)) : 0;
                absent |= !valid;
            }
            missing += absent;
        }
        d->missingFrames.fetch_add(missing, std::memory_order_relaxed);
    }
    return noErr;
}
AudioServerPlugInDriverInterface interface = { nullptr, query, addRef, release, initialize, create, destroy,
    client, client, change, change, has, settable, dataSize, data, setData, start, stop,
    timestamp, will, boundary, io, boundary };
AudioServerPlugInDriverInterface* interfacePointer = &interface;
HRESULT query(void*, REFIID uuid, LPVOID* result) {
    if(!result) return E_POINTER;
    auto cf = CFUUIDCreateFromUUIDBytes(nullptr, uuid);
    bool matches = CFEqual(cf, IUnknownUUID) || CFEqual(cf, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(cf); *result = matches ? &interfacePointer : nullptr;
    if(matches) { ++references; return S_OK; } return E_NOINTERFACE;
}
}
extern "C" __attribute__((visibility("default"))) void* AudioPatchFactory(CFAllocatorRef, CFUUIDRef type) {
    if(!CFEqual(type, kAudioServerPlugInTypeUUID)) return nullptr;
    ++references; return &interfacePointer;
}
