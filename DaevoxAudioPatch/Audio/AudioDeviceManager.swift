import CoreAudio
import Foundation
import Combine

// All property queries and notifications run outside audio callbacks.
enum HAL {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
    static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, fallback: T) -> T {
        var address = address(selector, scope)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : fallback
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       element: UInt32 = kAudioObjectPropertyElementMain) -> String? {
        var address = address(selector, scope, element)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    static func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = result.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? Array(result.prefix(Int(size) / 4)) : []
    }
    static func channels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> [String] {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { data.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, data) == noErr else { return [] }
        let buffers = UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self))
        let count = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard count > 0 else { return [] }
        return (1...count).map { channel in
            string(id, kAudioObjectPropertyElementName, scope: scope, element: UInt32(channel)) ?? "Канал \(channel)"
        }
    }
    static func describe(_ id: AudioObjectID) -> AudioDeviceDescription? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        var formats: [String] = []
        for stream in ids(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput) {
            let f = scalar(stream, kAudioStreamPropertyPhysicalFormat, fallback: AudioStreamBasicDescription())
            formats.append("\(Int(f.mSampleRate)) Hz · \(f.mBitsPerChannel) bit \((f.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? "Float" : "Integer") · \(f.mChannelsPerFrame) ch")
            var formatAddress = address(kAudioStreamPropertyAvailablePhysicalFormats)
            var formatBytes: UInt32 = 0
            if AudioObjectGetPropertyDataSize(stream, &formatAddress, 0, nil, &formatBytes) == noErr, formatBytes > 0 {
                var supported = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(), count: Int(formatBytes) / MemoryLayout<AudioStreamRangedDescription>.size)
                let status = supported.withUnsafeMutableBytes { AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &formatBytes, $0.baseAddress!) }
                if status == noErr {
                    for item in supported {
                        let pcm = item.mFormat
                        let rates = item.mSampleRateRange.mMinimum == item.mSampleRateRange.mMaximum ? "\(Int(item.mSampleRateRange.mMinimum))" : "\(Int(item.mSampleRateRange.mMinimum))–\(Int(item.mSampleRateRange.mMaximum))"
                        let description = "Доступно: \(rates) Hz · \(pcm.mBitsPerChannel) bit \((pcm.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? "Float" : "Integer") · \(pcm.mChannelsPerFrame) ch"
                        if !formats.contains(description) { formats.append(description) }
                    }
                }
            }
        }
        var address = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var bytes: UInt32 = 0
        var rates: [String] = []
        if AudioObjectGetPropertyDataSize(id, &address, 0, nil, &bytes) == noErr, bytes > 0 {
            var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(bytes) / MemoryLayout<AudioValueRange>.size)
            let status = ranges.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, $0.baseAddress!) }
            if status == noErr { rates = ranges.map { $0.mMinimum == $0.mMaximum ? "\(Int($0.mMinimum))" : "\(Int($0.mMinimum))–\(Int($0.mMaximum))" } }
        }
        return AudioDeviceDescription(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
            transport: scalar(id, kAudioDevicePropertyTransportType, fallback: UInt32(0)),
            inputChannels: channels(id, scope: kAudioObjectPropertyScopeInput),
            outputChannels: channels(id, scope: kAudioObjectPropertyScopeOutput),
            sampleRate: scalar(id, kAudioDevicePropertyNominalSampleRate, fallback: Double(0)),
            bufferFrames: scalar(id, kAudioDevicePropertyBufferFrameSize, fallback: UInt32(0)),
            alive: scalar(id, kAudioDevicePropertyDeviceIsAlive, fallback: UInt32(0)) != 0,
            formats: formats, sampleRates: rates)
    }
}

@MainActor
final class AudioDeviceManager: ObservableObject {
    @Published private(set) var devices: [AudioDeviceDescription] = []
    @Published private(set) var error: String?
    var onChange: (() -> Void)?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var refreshing = false
    private var scheduledRefresh: Task<Void, Never>?

    init() { refresh() }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        stopMonitoring()
        let ids = HAL.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        let next = ids.compactMap(HAL.describe).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let nextError = ids.isEmpty ? "CoreAudio не вернул устройства. Проверьте доступ к аудиосерверу." : nil
        let changed = next != devices || nextError != error
        if next != devices { devices = next }
        if nextError != error { error = nextError }
        listen(AudioObjectID(kAudioObjectSystemObject), HAL.address(kAudioHardwarePropertyDevices))
        for id in ids {
            for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate,
                             kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyName] {
                listen(id, HAL.address(selector))
            }
            for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
                listen(id, HAL.address(kAudioDevicePropertyStreamConfiguration, scope))
                listen(id, HAL.address(kAudioObjectPropertyElementName, scope, kAudioObjectPropertyElementWildcard))
                for stream in HAL.ids(id, kAudioDevicePropertyStreams, scope: scope) {
                    listen(stream, HAL.address(kAudioStreamPropertyPhysicalFormat))
                    listen(stream, HAL.address(kAudioStreamPropertyVirtualFormat))
                }
            }
        }
        if changed { onChange?() }
    }
    func stopMonitoring() {
        scheduledRefresh?.cancel(); scheduledRefresh = nil
        for (id, var address, block) in listeners { AudioObjectRemovePropertyListenerBlock(id, &address, .main, block) }
        listeners.removeAll()
    }
    private func scheduleRefresh() {
        guard scheduledRefresh == nil else { return }
        scheduledRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.scheduledRefresh = nil
            self.refresh()
        }
    }
    private func listen(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // HAL delivers this listener on DispatchQueue.main. Coalesce a burst
            // without enqueuing one unbounded Swift task per property notification.
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        if AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr {
            listeners.append((id, address, block))
        }
    }
}
