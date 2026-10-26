#include <CoreAudio/AudioServerPlugIn.h>
#include <dlfcn.h>
#include <cassert>
#include <cstdio>
#include <vector>
#include <thread>
#include <cmath>
#include <cstring>

static int notifications = 0;
static int storageWrites = 0;
static CFPropertyListRef stored = nullptr;
static OSStatus notify(AudioServerPlugInHostRef, AudioObjectID, UInt32, const AudioObjectPropertyAddress*) { ++notifications; return 0; }
static OSStatus readStorage(AudioServerPlugInHostRef, CFStringRef, CFPropertyListRef* value) { *value = stored ? CFRetain(stored) : nullptr; return 0; }
static OSStatus writeStorage(AudioServerPlugInHostRef, CFStringRef, CFPropertyListRef value) { ++storageWrites; if(stored) CFRelease(stored); stored = CFRetain(value); return 0; }
static OSStatus deleteStorage(AudioServerPlugInHostRef, CFStringRef) { return 0; }
static OSStatus request(AudioServerPlugInHostRef, AudioObjectID, UInt64, void*) { return 0; }
static auto address(UInt32 p) { return AudioObjectPropertyAddress{p, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}; }
int main(int argc, char** argv) {
    assert(argc == 2);
    auto library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if(!library) { std::fprintf(stderr, "%s\n", dlerror()); return 1; }
    auto factory = (void*(*)(CFAllocatorRef, CFUUIDRef))dlsym(library, "AudioPatchFactory");
    assert(factory);
    auto driver = (AudioServerPlugInDriverRef)factory(nullptr, kAudioServerPlugInTypeUUID);
    assert(driver);
    AudioServerPlugInHostInterface host{notify, readStorage, writeStorage, deleteStorage, request};
    assert((*driver)->Initialize(driver, &host) == 0);
    auto configAddress = address('apcf');
    auto configure = [&](const char* xml) {
        auto data = CFDataCreate(nullptr, (const UInt8*)xml, std::strlen(xml));
        auto plist = CFPropertyListCreateWithData(nullptr, data, kCFPropertyListImmutable, nullptr, nullptr);
        assert(plist);
        auto result = (*driver)->SetPropertyData(driver, 1, 0, &configAddress, 0, nullptr, sizeof(plist), &plist);
        CFRelease(plist); CFRelease(data); return result;
    };
    const char* config = "<plist version=\"1.0\"><array><dict><key>uid</key><string>test-one</string><key>name</key><string>Test Mic</string><key>channels</key><integer>2</integer></dict></array></plist>";
    assert(configure(config) == 0); assert(notifications > 0); assert(stored);
    // Regression: unchanged writes must not feed PropertiesChanged back into a client resync.
    const auto initialNotifications = notifications, initialStorageWrites = storageWrites;
    for(int n = 0; n < 32; ++n) assert(configure(config) == 0);
    assert(notifications == initialNotifications);
    assert(storageWrites == initialStorageWrites);
    auto list = address(kAudioPlugInPropertyDeviceList); UInt32 bytes = 0;
    assert((*driver)->GetPropertyDataSize(driver, 1, 0, &list, 0, nullptr, &bytes) == 0 && bytes == 4);
    AudioObjectID id = 0;
    assert((*driver)->GetPropertyData(driver, 1, 0, &list, 0, nullptr, 4, &bytes, &id) == 0 && id == 2);
    // Property boundary checks, unknown selectors, marshalling metadata.
    auto name = address(kAudioObjectPropertyName);
    UInt32 dummy = 0;
    assert((*driver)->GetPropertyData(driver, id, 0, &name, 0, nullptr, 1, &bytes, &dummy) == kAudioHardwareBadPropertySizeError);
    auto unknown = address('nope'); assert(!(*driver)->HasProperty(driver, id, 0, &unknown));
    auto custom = address(kAudioObjectPropertyCustomPropertyInfoList);
    AudioServerPlugInCustomPropertyInfo info{};
    assert((*driver)->GetPropertyData(driver, 1, 0, &custom, 0, nullptr, sizeof(info), &bytes, &info) == 0);
    assert(info.mSelector == 'apcf' && info.mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
    assert(configure("<plist><array><dict><key>uid</key><string>x</string><key>name</key><string>x</string><key>channels</key><integer>999</integer></dict></array></plist>") != 0);
    assert((*driver)->StartIO(driver, id, 1) == 0);
    assert(configure("<plist><array/></plist>") != 0); // running clients protect structure
    const auto runningNotifications = notifications;
    assert(configure(config) == 0); // idempotent sync is permitted during IO
    assert(notifications == runningNotifications);
    assert(storageWrites == initialStorageWrites);
    Float64 sample = 0; UInt64 time = 0, seed = 0;
    assert((*driver)->GetZeroTimeStamp(driver, id, 1, &sample, &time, &seed) == 0 && seed == 1 && time > 0);
    auto previous = time;
    assert((*driver)->GetZeroTimeStamp(driver, id, 1, &sample, &time, &seed) == 0 && time >= previous);
    constexpr UInt32 frames = 256;
    std::vector<float> input(frames * 2), output(frames * 2, -1), second(frames * 2);
    for(size_t i = 0; i < input.size(); ++i) input[i] = std::sin(double(i) * 0.13);
    AudioServerPlugInIOCycleInfo cycle{};
    cycle.mOutputTime.mSampleTime = 4096;
    assert((*driver)->DoIOOperation(driver, id, id + 2, 1, kAudioServerPlugInIOOperationWriteMix, frames, &cycle, input.data(), nullptr) == 0);
    cycle.mInputTime.mSampleTime = 4096 + 1024;
    assert((*driver)->DoIOOperation(driver, id, id + 1, 2, kAudioServerPlugInIOOperationReadInput, frames, &cycle, output.data(), nullptr) == 0);
    assert(output == input);
    // Multiple clients must get identical frames, not consume a FIFO.
    assert((*driver)->DoIOOperation(driver, id, id + 1, 3, kAudioServerPlugInIOOperationReadInput, frames, &cycle, second.data(), nullptr) == 0);
    assert(second == input);
    cycle.mInputTime.mSampleTime += 32768;
    (*driver)->DoIOOperation(driver, id, id + 1, 2, kAudioServerPlugInIOOperationReadInput, frames, &cycle, output.data(), nullptr);
    for(auto v : output) assert(v == 0); // stale timestamps are silent
    cycle.mInputTime.mSampleTime = 4096 + 1024 + 4294967296.0;
    (*driver)->DoIOOperation(driver, id, id + 1, 2, kAudioServerPlugInIOOperationReadInput, frames, &cycle, output.data(), nullptr);
    for(auto v : output) assert(v == 0); // 32-bit timestamp rollover cannot replay day-old audio
    // Concurrent writer + multiple readers, wraparound, samples remain finite.
    std::thread writer([&] { for(int n=0; n<1200; ++n) { auto c=cycle; c.mOutputTime.mSampleTime=65536+n*frames; (*driver)->DoIOOperation(driver,id,id+2,1,kAudioServerPlugInIOOperationWriteMix,frames,&c,input.data(),nullptr); } });
    auto reader = [&] { auto b=output; for(int n=0; n<1200; ++n) { auto c=cycle; c.mInputTime.mSampleTime=65536+n*frames+1024; (*driver)->DoIOOperation(driver,id,id+1,2,kAudioServerPlugInIOOperationReadInput,frames,&c,b.data(),nullptr); for(auto v:b) assert(std::isfinite(v)); } };
    std::thread r1(reader), r2(reader); writer.join(); r1.join(); r2.join();
    assert((*driver)->StopIO(driver, id, 1) == 0);
    assert(configure("<plist><array/></plist>") == 0);
    assert(!(*driver)->HasProperty(driver, id, 0, &name));
    puts("PASS: HAL properties, validation, persistence, clock, PCM loopback, multi-client reads, stale silence, concurrency, lifecycle");
}
