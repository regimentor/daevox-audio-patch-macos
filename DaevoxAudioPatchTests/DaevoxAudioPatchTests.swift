import XCTest
import CoreAudio
@testable import DaevoxAudioPatch

private final class PlanarFixture: @unchecked Sendable {
    let buffers: UnsafeMutableAudioBufferListPointer
    let maxFrames: Int
    init(channels: Int, frames: Int = 4096) {
        maxFrames = frames
        buffers = AudioBufferList.allocate(maximumBuffers: channels)
        buffers.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(channels)
        for c in 0..<channels {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            samples.initialize(repeating: Float(c + 1) * 0.1, count: frames)
            buffers[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: samples)
        }
    }
    func setFrames(_ frames: Int) { for c in 0..<buffers.count { buffers[c].mDataByteSize = UInt32(frames * 4) } }
    deinit {
        for buffer in buffers { buffer.mData!.assumingMemoryBound(to: Float.self).deallocate() }
        buffers.unsafeMutablePointer.deallocate()
    }
}

final class AudioRoutingTests: XCTestCase {
    func testGoXLRChannelsThreeAndFourAreMappedToStereo() throws {
        let engine = try AudioRoutingEngine(sourceChannels: 21, channels: 2,
            mapping: [ChannelRoute(input: 3, output: 1), ChannelRoute(input: 4, output: 2)])
        let source = PlanarFixture(channels: 21)
        engine.push(source.buffers.unsafePointer, frames: 2048)
        var output = [Float](repeating: -1, count: 512)
        output.withUnsafeMutableBufferPointer { engine.render($0.baseAddress!, frames: 256) }
        for f in 0..<256 { XCTAssertEqual(output[f * 2], 0.3, accuracy: 0.000001); XCTAssertEqual(output[f * 2 + 1], 0.4, accuracy: 0.000001) }
        XCTAssertEqual(engine.statistics().renderedFrames, 256)
    }
    func testMixingGainDisabledRoutesAndClipping() throws {
        let engine = try AudioRoutingEngine(sourceChannels: 4, channels: 2, mapping: [
            ChannelRoute(input: 1, output: 1, gain: 2), ChannelRoute(input: 2, output: 1, gain: 2),
            ChannelRoute(input: 4, output: 2, gain: 4), ChannelRoute(input: 3, output: 1, enabled: false)])
        let source = PlanarFixture(channels: 4); engine.push(source.buffers.unsafePointer, frames: 2048)
        var output = [Float](repeating: 0, count: 512)
        output.withUnsafeMutableBufferPointer { engine.render($0.baseAddress!, frames: 256) }
        XCTAssertEqual(output[0], 0.6, accuracy: 0.000001); XCTAssertEqual(output[1], 1)
    }
    func testNoConnectionsProducesSilence() throws {
        let engine = try AudioRoutingEngine(sourceChannels: 2, channels: 2, mapping: [])
        let source = PlanarFixture(channels: 2); engine.push(source.buffers.unsafePointer, frames: 2048)
        var output = [Float](repeating: 1, count: 512)
        output.withUnsafeMutableBufferPointer { engine.render($0.baseAddress!, frames: 256) }
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
    }
    func testPrimingAndUnderrunSilenceThenRecovery() throws {
        let engine = try AudioRoutingEngine(sourceChannels: 1, channels: 1, mapping: [ChannelRoute(input: 1, output: 1)])
        let source = PlanarFixture(channels: 1)
        var output = [Float](repeating: 9, count: 256)
        output.withUnsafeMutableBufferPointer { engine.render($0.baseAddress!, frames: 256) }
        XCTAssertTrue(output.allSatisfy { $0 == 0 }); XCTAssertEqual(engine.statistics().underruns, 0)
        engine.push(source.buffers.unsafePointer, frames: 2048)
        for _ in 0..<8 { output.withUnsafeMutableBufferPointer { engine.render($0.baseAddress!, frames: 256) } }
        XCTAssertGreaterThan(engine.statistics().underruns, 0); XCTAssertTrue(output.allSatisfy { $0 == 0 })
        engine.push(source.buffers.unsafePointer, frames: 2048)
        output.withUnsafeMutableBufferPointer { engine.render($0.baseAddress!, frames: 256) }
        XCTAssertEqual(output[0], 0.1, accuracy: 0.00001)
    }
    func testOverrunDropsNewDataAndNeverOverwritesUnreadFrames() throws {
        let engine = try AudioRoutingEngine(sourceChannels: 1, channels: 1, mapping: [ChannelRoute(input: 1, output: 1)], capacity: 64, target: 16)
        let source = PlanarFixture(channels: 1)
        engine.push(source.buffers.unsafePointer, frames: 48)
        source.buffers[0].mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.9, count: 32)
        engine.push(source.buffers.unsafePointer, frames: 32)
        XCTAssertEqual(engine.statistics().overruns, 1)
        var output = [Float](repeating: 0, count: 8)
        output.withUnsafeMutableBufferPointer { engine.render($0.baseAddress!, frames: 8) }
        XCTAssertTrue(output.allSatisfy { abs($0 - 0.1) < 0.000001 })
    }
    func testInvalidChannelsAndNonFiniteGainsAreRejected() {
        XCTAssertThrowsError(try AudioRoutingEngine(sourceChannels: 4, channels: 2, mapping: [ChannelRoute(input: 7, output: 1)]))
        XCTAssertThrowsError(try AudioRoutingEngine(sourceChannels: 4, channels: 2, mapping: [ChannelRoute(input: 0, output: 1)]))
        XCTAssertThrowsError(try AudioRoutingEngine(sourceChannels: 4, channels: 2, mapping: [ChannelRoute(input: 1, output: 3)]))
        XCTAssertThrowsError(try AudioRoutingEngine(sourceChannels: 4, channels: 2, mapping: [ChannelRoute(input: 1, output: 1, gain: .nan)]))
    }
    func testMalformedInputBufferIsRejected() throws {
        let engine = try AudioRoutingEngine(sourceChannels: 2, channels: 2, mapping: [])
        let source = PlanarFixture(channels: 2); source.buffers[0].mDataByteSize = 1
        engine.push(source.buffers.unsafePointer, frames: 32)
        XCTAssertEqual(engine.statistics().captureErrors, 1); XCTAssertEqual(engine.statistics().capturedFrames, 0)
    }
    func testNonFiniteSamplesCannotPoisonOutput() throws {
        let engine = try AudioRoutingEngine(sourceChannels: 1, channels: 1, mapping: [ChannelRoute(input: 1, output: 1)])
        let source = PlanarFixture(channels: 1)
        source.buffers[0].mData!.assumingMemoryBound(to: Float.self).update(repeating: .nan, count: 2048)
        engine.push(source.buffers.unsafePointer, frames: 2048)
        var output = [Float](repeating: 1, count: 256)
        output.withUnsafeMutableBufferPointer { engine.render($0.baseAddress!, frames: 256) }
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
    }
    func testIndependentClocksPositiveAndNegativeDrift() throws {
        for drift in [-0.001, 0.001] {
            let engine = try AudioRoutingEngine(sourceChannels: 1, channels: 1, mapping: [ChannelRoute(input: 1, output: 1)])
            let source = PlanarFixture(channels: 1)
            engine.push(source.buffers.unsafePointer, frames: 1536)
            var output = [Float](repeating: 0, count: 256)
            var fraction = 0.0
            for _ in 0..<20_000 {
                fraction += 256 * (1 + drift)
                let count = Int(fraction); fraction -= Double(count)
                engine.push(source.buffers.unsafePointer, frames: count)
                output.withUnsafeMutableBufferPointer { engine.render($0.baseAddress!, frames: 256) }
            }
            let stats = engine.statistics()
            XCTAssertEqual(stats.underruns, 0, "drift=\(drift)"); XCTAssertEqual(stats.overruns, 0)
            XCTAssertLessThan(stats.bufferedFrames, 2200); XCTAssertGreaterThan(stats.bufferedFrames, 100)
            XCTAssertLessThan(abs(Double(stats.correctionPPM) - drift * 1_000_000), 400)
        }
    }
    func testConcurrentSPSCWraparound() throws {
        let engine = try AudioRoutingEngine(sourceChannels: 2, channels: 2, mapping: [ChannelRoute(input: 1, output: 1), ChannelRoute(input: 2, output: 2)])
        let source = PlanarFixture(channels: 2)
        DispatchQueue.concurrentPerform(iterations: 2) { lane in
            if lane == 0 { for _ in 0..<5000 { engine.push(source.buffers.unsafePointer, frames: 256) } }
            else {
                let output = UnsafeMutablePointer<Float>.allocate(capacity: 512); defer { output.deallocate() }
                for _ in 0..<5000 { engine.render(output, frames: 256) }
            }
        }
        XCTAssertGreaterThan(engine.statistics().capturedFrames, 0)
        XCTAssertLessThanOrEqual(engine.statistics().bufferedFrames, 32768)
    }
}

final class ConfigurationTests: XCTestCase {
    func testAtomicSaveAndRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConfigurationManager(url: folder.appending(path: "configuration.json"))
        var config = PatchConfiguration(); config.devices = [VirtualDeviceConfiguration()]
        try store.save(config); XCTAssertEqual(try store.load(), config)
        config.devices[0].name = "Микрофон Discord"; try store.save(config)
        XCTAssertEqual(try store.load(), config)
    }
    func testCorruptAndNewerConfigurationAreNotOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ConfigurationManager(url: folder.appending(path: "configuration.json"))
        let bad = Data("{broken".utf8); try bad.write(to: store.url)
        XCTAssertThrowsError(try store.load()); XCTAssertEqual(try Data(contentsOf: store.url), bad)
        var future = PatchConfiguration(); future.version = 999
        XCTAssertThrowsError(try store.save(future))
        XCTAssertEqual(try Data(contentsOf: store.url), bad)
    }
    func testDuplicateUIDsAndInvalidRoutesAreRejected() {
        var config = PatchConfiguration(); let device = VirtualDeviceConfiguration()
        config.devices = [device, device]; XCTAssertThrowsError(try config.validated())
        config.devices = [device]; config.devices[0].routes[0].output = 3
        XCTAssertThrowsError(try config.validated())
    }
}
