// Opt-in real CoreAudio integration probe. Never run as a unit test.
import Foundation
import AVFoundation
import CoreAudio

@main
struct HALIntegration {
    @MainActor static func main() async {
        do { try await run() }
        catch { log("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    static func log(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    @MainActor static func run() async throws {
        let driver = VirtualDriverController()
        guard let plugin = driver.pluginID else { throw PatchError.message("AudioPatch HAL plugin not loaded") }
        log("AudioPatch HAL plugin ID: \(plugin)")
        if CommandLine.arguments.contains("--status-only") {
            for id in HAL.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) {
                if let device = HAL.describe(id), device.isAudioPatch {
                    let a = driver.statistics(device: id)
                    log("\(device.name): id=\(id), clients=\(a.clients), written=\(a.writtenFrames), missing=\(a.missingFrames), delay=\(a.delayFrames)")
                }
            }
            return
        }
        let store = ConfigurationManager()
        var config = try store.load()
        let source = HAL.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
            .compactMap(HAL.describe).first { $0.name.localizedCaseInsensitiveContains("goxlr") && $0.inputChannels.count >= 4 }
        guard let source else { throw PatchError.message("GoXLR with channels 3–4 not found") }
        var virtual = config.devices.first { $0.name == "GoXLR Discord Mic" && $0.channels == 2 } ?? VirtualDeviceConfiguration()
        virtual.sourceUID = source.uid
        if CommandLine.arguments.contains("--enable") { virtual.enabled = true }
        if let i = config.devices.firstIndex(where: { $0.id == virtual.id }) { config.devices[i] = virtual }
        else { config.devices.append(virtual) }
        _ = try config.validated()
        try driver.synchronize(config.devices)
        var virtualID: AudioObjectID?
        for _ in 0..<30 {
            virtualID = driver.deviceID(uid: virtual.uid)
            if virtualID != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let id = virtualID, let description = HAL.describe(id) else { throw PatchError.message("HAL did not publish virtual device") }
        guard description.inputChannels.count == 2, description.outputChannels.count == 2,
              description.sampleRate == 48000 else { throw PatchError.message("Wrong HAL channel/rate metadata") }
        try store.save(config)
        log("Created real HAL device: \(description.name), ID=\(id), in=2 out=2 48000 Hz")
        if CommandLine.arguments.contains("--create-only") { return }
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        log("Microphone authorization: \(permission.rawValue)")
        var allowed = permission == .authorized
        if permission == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .audio) }
        guard allowed else { throw PatchError.message("Microphone permission required for integration probe") }
        if CommandLine.arguments.contains("--meter") { try await meter(source); return }
        guard driver.statistics(device: id).clients == 0 else {
            throw PatchError.message("Stop AudioPatch routing and close microphone clients before the tone/voice integration test; --status-only is read-only")
        }
        let sink = try AudioRoutingEngine(sourceChannels: 2, channels: 2,
            mapping: [ChannelRoute(input: 1, output: 1), ChannelRoute(input: 2, output: 2)])
        let receiver = AudioCaptureEngine()
        try receiver.start(device: id, router: sink)
        defer { receiver.stop() }
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { buffer.deallocate() }
        let output = VirtualOutputEngine()
        defer { output.stop() }
        // First: known stereo tone through actual HAL output → plug-in → HAL input → AUHAL.
        let tone = try AudioRoutingEngine(sourceChannels: 1, channels: 2, mapping: [
            ChannelRoute(input: 1, output: 1), ChannelRoute(input: 1, output: 2, gain: -1)])
        let planar = AudioBufferList.allocate(maximumBuffers: 1)
        planar.unsafeMutablePointer.pointee.mNumberBuffers = 1
        let generated = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        planar[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 512 * 4, mData: generated)
        defer { generated.deallocate(); planar.unsafeMutablePointer.deallocate() }
        try output.start(device: id, router: tone)
        var phase = 0.0
        var frames = 0, energy = 0.0, stereoError = 0.0
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if tone.statistics().bufferedFrames < 2048 {
                for i in 0..<512 { generated[i] = Float(sin(phase) * 0.25); phase += 2 * .pi * 440 / 48000 }
                tone.push(planar.unsafePointer, frames: 512)
            }
            while sink.statistics().bufferedFrames >= 1024 {
                sink.render(buffer, frames: 256)
                for i in 0..<256 {
                    let left = Double(buffer[i * 2]), right = Double(buffer[i * 2 + 1])
                    energy += left * left + right * right; stereoError += (left + right) * (left + right)
                }
                frames += 256
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        output.stop()
        let rms = sqrt(energy / Double(max(1, frames * 2)))
        log("HAL tone roundtrip: \(frames) frames, RMS=\(rms), stereo error=\(stereoError), captureErrors=\(sink.statistics().captureErrors)")
        guard frames > 48000, rms > 0.10, rms < 0.22, stereoError < energy * 0.0001,
              sink.statistics().captureErrors == 0 else { throw PatchError.message("HAL stereo tone roundtrip failed") }
        log("PASS: real system HAL stereo tone roundtrip")
        receiver.stop()
        // Second: the actual GoXLR mapping, inspected only as levels/counters (no voice file saved).
        let physical = try AudioRoutingEngine(sourceChannels: source.inputChannels.count, channels: 2,
            mapping: virtual.routes, target: max(1024, Int(source.bufferFrames) * 2 + 128))
        let capture = AudioCaptureEngine()
        defer { capture.stop() }
        let received = try AudioRoutingEngine(sourceChannels: 2, channels: 2,
            mapping: [ChannelRoute(input: 1, output: 1), ChannelRoute(input: 2, output: 2)])
        try receiver.start(device: id, router: received)
        try output.start(device: id, router: physical)
        try capture.start(device: source.id, router: physical)
        log("GoXLR 3–4 → real virtual input 1–2: speak for 10 seconds")
        let until = ContinuousClock.now.advanced(by: .seconds(10))
        var peak: Float = 0
        while ContinuousClock.now < until {
            while received.statistics().bufferedFrames >= 1024 {
                received.render(buffer, frames: 256)
                for i in 0..<512 { peak = max(peak, abs(buffer[i])) }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let stats = physical.statistics()
        let inputStats = received.statistics()
        let driverStats = driver.statistics(device: id)
        log("GoXLR captured=\(stats.capturedFrames) output=\(stats.renderedFrames) received=\(inputStats.capturedFrames), peak=\(peak)")
        log("underruns=\(stats.underruns) overruns=\(stats.overruns) errors=\(stats.captureErrors) fill=\(stats.bufferedFrames) ppm=\(stats.correctionPPM)")
        log("driver written=\(driverStats.writtenFrames) missing=\(driverStats.missingFrames) clients=\(driverStats.clients)")
        guard stats.capturedFrames > 400000, stats.renderedFrames > 400000,
              inputStats.capturedFrames > 400000, stats.captureErrors == 0, inputStats.captureErrors == 0,
              peak > 0.00001 else { throw PatchError.message("GoXLR capture/signal verification failed; check Utility mix and mic level") }
        log("PASS: GoXLR 3–4 → system virtual microphone 1–2")
    }
    @MainActor static func meter(_ source: AudioDeviceDescription) async throws {
        var peaks = [Float](repeating: 0, count: source.inputChannels.count)
        for base in stride(from: 0, to: source.inputChannels.count, by: 16) {
            let count = min(16, source.inputChannels.count - base)
            let router = try AudioRoutingEngine(sourceChannels: source.inputChannels.count, channels: count,
                mapping: (0..<count).map { ChannelRoute(input: base + $0 + 1, output: $0 + 1) })
            let capture = AudioCaptureEngine()
            try capture.start(device: source.id, router: router)
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: 256 * count)
            let until = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < until {
                while router.statistics().bufferedFrames >= 1024 {
                    router.render(samples, frames: 256)
                    for f in 0..<256 { for c in 0..<count { peaks[base+c] = max(peaks[base+c], abs(samples[f*count+c])) } }
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            capture.stop(); samples.deallocate()
            log("Metered physical channels \(base+1)…\(base+count): captured=\(router.statistics().capturedFrames), errors=\(router.statistics().captureErrors)")
        }
        for (i, peak) in peaks.enumerated() { log("input \(i+1) \(source.inputChannels[i]): peak=\(peak)") }
    }

}
