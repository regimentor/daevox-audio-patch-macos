import AudioToolbox
import CoreAudio
import Synchronization

// Preallocated context, retained by AudioCaptureEngine until Stop + Uninitialize + Dispose finish.
private final class CaptureContext {
    var unit: AudioUnit?
    let router: AudioRoutingEngine
    let buffers: UnsafeMutableAudioBufferListPointer
    let maxFrames: UInt32
    init(router: AudioRoutingEngine, maxFrames: UInt32) {
        self.router = router; self.maxFrames = maxFrames
        buffers = AudioBufferList.allocate(maximumBuffers: router.sourceChannels)
        buffers.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(router.sourceChannels)
        for c in 0..<router.sourceChannels {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: Int(maxFrames))
            data.initialize(repeating: 0, count: Int(maxFrames))
            buffers[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: maxFrames * 4, mData: data)
        }
    }
    deinit {
        for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self).deallocate() }
        buffers.unsafeMutablePointer.deallocate()
    }
}

private let captureCallback: AURenderCallback = { ref, flags, time, _, frames, _ in
    let context = Unmanaged<CaptureContext>.fromOpaque(ref).takeUnretainedValue()
    guard let unit = context.unit, frames <= context.maxFrames else {
        context.router.captureErrors.wrappingAdd(1, ordering: .relaxed); return kAudio_ParamError
    }
    for c in 0..<context.router.sourceChannels { context.buffers[c].mDataByteSize = frames * 4 }
    let status = AudioUnitRender(unit, flags, time, 1, frames, context.buffers.unsafeMutablePointer)
    if status == noErr { context.router.push(context.buffers.unsafePointer, frames: Int(frames)) }
    else { context.router.captureErrors.wrappingAdd(1, ordering: .relaxed) }
    return status
}

final class AudioCaptureEngine {
    private var unit: AudioUnit?
    private var context: CaptureContext?
    func start(device: AudioObjectID, router: AudioRoutingEngine) throws {
        stop()
        var component = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let found = AudioComponentFindNext(nil, &component) else { throw PatchError.message("AUHAL недоступен.") }
        var newUnit: AudioUnit?
        try checkAudio(AudioComponentInstanceNew(found, &newUnit), "Создание AUHAL")
        guard let newUnit else { throw PatchError.message("Пустой AUHAL instance.") }
        unit = newUnit
        do {
            var one: UInt32 = 1, zero: UInt32 = 0, selected = device
            try checkAudio(AudioUnitSetProperty(newUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "Включение capture")
            try checkAudio(AudioUnitSetProperty(newUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "Отключение playback AUHAL")
            try checkAudio(AudioUnitSetProperty(newUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, 4), "Выбор физического входа")
            let rate = HAL.scalar(device, kAudioDevicePropertyNominalSampleRate, fallback: Double(0))
            guard abs(rate - 48_000) < 0.01 else { throw PatchError.message("MVP требует физический вход 48 kHz. Сейчас: \(rate) Hz. Измените частоту в Audio MIDI Setup.") }
            var format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: UInt32(router.sourceChannels), mBitsPerChannel: 32, mReserved: 0)
            try checkAudio(AudioUnitSetProperty(newUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Float32 capture format")
            var maximum: UInt32 = 8192
            try checkAudio(AudioUnitSetProperty(newUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum, 4), "Capture maximum frames")
            var size: UInt32 = 4
            try checkAudio(AudioUnitGetProperty(newUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum, &size), "Чтение maximum frames")
            guard maximum <= 16384 else { throw PatchError.message("Слишком большой capture slice.") }
            try checkAudio(AudioUnitSetProperty(newUnit, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1, &zero, 4), "Capture uses preallocated buffers")
            let context = CaptureContext(router: router, maxFrames: maximum)
            context.unit = newUnit; self.context = context
            var callback = AURenderCallbackStruct(inputProc: captureCallback, inputProcRefCon: Unmanaged.passUnretained(context).toOpaque())
            try checkAudio(AudioUnitSetProperty(newUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Capture callback")
            try checkAudio(AudioUnitInitialize(newUnit), "Инициализация AUHAL")
            try checkAudio(AudioOutputUnitStart(newUnit), "Запуск физического входа")
        } catch { stop(); throw error }
    }
    func stop() {
        if let unit { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
        unit = nil; context = nil
    }
    deinit { stop() }
}

private let outputCallback: AudioDeviceIOProc = { _, _, _, _, output, _, context in
    guard let context else { return noErr }
    let router = Unmanaged<AudioRoutingEngine>.fromOpaque(context).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(output)
    // Plug-in exposes exactly one interleaved Float32 output stream.
    guard buffers.count == 1, buffers[0].mNumberChannels == UInt32(router.channels),
          let data = buffers[0].mData else {
        for buffer in buffers { if let data = buffer.mData { data.initializeMemory(as: UInt8.self, repeating: 0, count: Int(buffer.mDataByteSize)) } }
        router.captureErrors.wrappingAdd(1, ordering: .relaxed)
        return noErr
    }
    let frames = Int(buffers[0].mDataByteSize) / (4 * router.channels)
    router.render(data.assumingMemoryBound(to: Float.self), frames: frames)
    return noErr
}

final class VirtualOutputEngine {
    private var device: AudioObjectID = 0
    private var proc: AudioDeviceIOProcID?
    private var router: AudioRoutingEngine?
    func start(device: AudioObjectID, router: AudioRoutingEngine) throws {
        stop(); self.device = device; self.router = router
        do {
            try checkAudio(AudioDeviceCreateIOProcID(device, outputCallback, Unmanaged.passUnretained(router).toOpaque(), &proc), "Output IOProc")
            try checkAudio(AudioDeviceStart(device, proc), "Запуск виртуального output")
        } catch { stop(); throw error }
    }
    func stop() {
        if let proc { AudioDeviceStop(device, proc); AudioDeviceDestroyIOProcID(device, proc) }
        proc = nil; router = nil; device = 0
    }
    deinit { stop() }
}
