import CoreAudio
import Synchronization

struct RoutingStatistics: Sendable {
    var capturedFrames: UInt64 = 0
    var renderedFrames: UInt64 = 0
    var underruns: UInt64 = 0
    var overruns: UInt64 = 0
    var captureErrors: UInt64 = 0
    var bufferedFrames: UInt64 = 0
    var correctionPPM: Float = 0
    var peak: Float = 0
}

private struct RealtimeRoute {
    let input: Int
    let output: Int
    let gain: Float
}

/// Single capture producer, single output consumer. Immutable mapping for the entire IO lifetime.
/// No arrays, locks, dispatch, Foundation or async work in push/render.
final class AudioRoutingEngine: @unchecked Sendable {
    let channels: Int
    let sourceChannels: Int
    let capacity: Int
    let target: Int
    private let samples: UnsafeMutablePointer<Float>
    private let routes: UnsafeMutablePointer<RealtimeRoute>
    private let routeCount: Int
    private let writePosition = Atomic<UInt64>(0)
    private let readPosition = Atomic<UInt64>(0)
    private let captured = Atomic<UInt64>(0)
    private let rendered = Atomic<UInt64>(0)
    private let underruns = Atomic<UInt64>(0)
    private let overruns = Atomic<UInt64>(0)
    let captureErrors = Atomic<UInt64>(0)
    private let correction = Atomic<UInt32>(0)
    private let peakBits = Atomic<UInt32>(0)
    // Consumer-owned state only.
    private var fraction = 0.0
    private var primed = false
    private var integral = 0.0
    private var ratio = 1.0

    init(sourceChannels: Int, channels: Int, mapping: [ChannelRoute],
         capacity: Int = 32768, target: Int = 1024) throws {
        guard sourceChannels > 0, sourceChannels <= 256, (1...16).contains(channels),
              capacity >= 32, capacity.nonzeroBitCount == 1, target >= 2, target * 2 < capacity,
              mapping.count <= 256, mapping.allSatisfy({
                  (1...sourceChannels).contains($0.input) && (1...channels).contains($0.output) &&
                  $0.gain.isFinite && abs($0.gain) <= 4
              }) else { throw PatchError.message("Маршрут ссылается на недоступный канал или неверный буфер.") }
        self.sourceChannels = sourceChannels; self.channels = channels
        self.capacity = capacity; self.target = target
        samples = .allocate(capacity: capacity * channels)
        samples.initialize(repeating: 0, count: capacity * channels)
        let enabled = mapping.filter(\.enabled)
        routeCount = enabled.count
        routes = .allocate(capacity: max(1, routeCount))
        for (index, route) in enabled.enumerated() {
            routes.advanced(by: index).initialize(to: RealtimeRoute(input: route.input - 1, output: route.output - 1, gain: route.gain))
        }
    }
    deinit {
        samples.deinitialize(count: capacity * channels); samples.deallocate()
        routes.deinitialize(count: routeCount); routes.deallocate()
    }
    func push(_ input: UnsafePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard frames > 0, frames < capacity, buffers.count == sourceChannels else {
            captureErrors.wrappingAdd(1, ordering: .relaxed); return
        }
        for c in 0..<sourceChannels {
            if buffers[c].mData == nil || buffers[c].mNumberChannels != 1 || Int(buffers[c].mDataByteSize) < frames * 4 {
                captureErrors.wrappingAdd(1, ordering: .relaxed); return
            }
        }
        let w = writePosition.load(ordering: .relaxed)
        let r = readPosition.load(ordering: .acquiring)
        guard UInt64(frames) <= UInt64(capacity) - (w - r) else {
            overruns.wrappingAdd(1, ordering: .relaxed); return // never overwrite consumer-owned data
        }
        var peak: Float = 0
        for f in 0..<frames {
            let base = (Int(w &+ UInt64(f)) & (capacity - 1)) * channels
            for c in 0..<channels { samples[base + c] = 0 }
            for i in 0..<routeCount {
                let route = routes[i]
                let sample = buffers[route.input].mData!.assumingMemoryBound(to: Float.self)[f]
                if sample.isFinite { samples[base + route.output] += sample * route.gain }
            }
            for c in 0..<channels {
                let value = min(1, max(-1, samples[base + c]))
                samples[base + c] = value
                peak = max(peak, abs(value))
            }
        }
        peakBits.store(peak.bitPattern, ordering: .relaxed)
        captured.wrappingAdd(UInt64(frames), ordering: .relaxed)
        writePosition.store(w + UInt64(frames), ordering: .releasing)
    }
    func render(_ output: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        // Silence first: every early return is deterministic and cannot expose stale memory.
        output.update(repeating: 0, count: frames * channels)
        guard frames < capacity / 2 else { captureErrors.wrappingAdd(1, ordering: .relaxed); return }
        let w = writePosition.load(ordering: .acquiring)
        var r = readPosition.load(ordering: .relaxed)
        let available = Int(w - r)
        if !primed {
            guard available >= max(target, frames + 2) else { return }
            // Drop startup excess on consumer only, keeping the chosen bounded latency.
            r = w - UInt64(max(target, frames + 2))
            primed = true; fraction = 0; integral = 0; ratio = 1
        }
        let fill = Int(w - r)
        // PI gains are damped against the fill integrator; verified at ±1000 ppm.
        let error = Double(fill - target) / Double(target)
        integral = min(0.0015, max(-0.0015, integral + error * 0.000004 * Double(frames) / 256))
        let wanted = 1 + min(0.002, max(-0.002, error * 0.008 + integral))
        ratio += (wanted - ratio) * 0.02
        correction.store(Float((ratio - 1) * 1_000_000).bitPattern, ordering: .relaxed)
        let needed = Int(fraction + Double(frames) * ratio) + 2
        guard fill >= needed else {
            underruns.wrappingAdd(1, ordering: .relaxed)
            primed = false; fraction = 0
            readPosition.store(w, ordering: .releasing)
            return
        }
        var position = fraction
        for f in 0..<frames {
            let offset = Int(position)
            let blend = Float(position - Double(offset))
            let first = (Int(r &+ UInt64(offset)) & (capacity - 1)) * channels
            let next = (Int(r &+ UInt64(offset + 1)) & (capacity - 1)) * channels
            for c in 0..<channels {
                output[f * channels + c] = samples[first + c] + (samples[next + c] - samples[first + c]) * blend
            }
            position += ratio
        }
        let consumed = Int(position)
        fraction = position - Double(consumed)
        readPosition.store(r + UInt64(consumed), ordering: .releasing)
        rendered.wrappingAdd(UInt64(frames), ordering: .relaxed)
    }
    func statistics() -> RoutingStatistics {
        let r = readPosition.load(ordering: .acquiring)
        let w = writePosition.load(ordering: .acquiring)
        return RoutingStatistics(capturedFrames: captured.load(ordering: .relaxed),
            renderedFrames: rendered.load(ordering: .relaxed), underruns: underruns.load(ordering: .relaxed),
            overruns: overruns.load(ordering: .relaxed), captureErrors: captureErrors.load(ordering: .relaxed),
            bufferedFrames: w >= r ? w - r : 0, correctionPPM: Float(bitPattern: correction.load(ordering: .relaxed)),
            peak: Float(bitPattern: peakBits.load(ordering: .relaxed)))
    }
}
