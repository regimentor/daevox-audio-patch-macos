import Foundation
import CoreAudio

struct ChannelRoute: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var input: Int // one-based UI and persistence
    var output: Int
    var gain: Float = 1
    var enabled = true
}

struct VirtualDeviceConfiguration: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = "GoXLR Discord Mic"
    var channels = 2
    var sampleRate: Double = 48_000
    var sourceUID: String = ""
    var routes = [ChannelRoute(input: 3, output: 1), ChannelRoute(input: 4, output: 2)]
    var enabled = false
    var uid: String { "audio.audio-patch.virtual.\(id.uuidString)" }
}

struct PatchConfiguration: Codable, Equatable, Sendable {
    var version = 1
    var devices: [VirtualDeviceConfiguration] = []
    var restoreOnLaunch = true
    var targetBufferFrames = 1024

    func validated() throws -> Self {
        guard version == 1, devices.count <= 8, (512...8192).contains(targetBufferFrames),
              Set(devices.map(\.id)).count == devices.count else {
            throw PatchError.message("Неподдерживаемая или повреждённая конфигурация.")
        }
        for device in devices {
            guard !device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  device.name.utf8.count <= 240, (1...16).contains(device.channels),
                  device.sampleRate == 48_000, device.routes.count <= 256,
                  device.routes.allSatisfy({ (1...256).contains($0.input) &&
                      (1...device.channels).contains($0.output) && $0.gain.isFinite && abs($0.gain) <= 4 }) else {
                throw PatchError.message("Некорректные каналы, название или маршруты: \(device.name).")
            }
        }
        return self
    }
}

struct AudioDeviceDescription: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    let inputChannels: [String]
    let outputChannels: [String]
    let sampleRate: Double
    let bufferFrames: UInt32
    let alive: Bool
    let formats: [String]
    let sampleRates: [String]
    var isAudioPatch: Bool { uid.hasPrefix("audio.audio-patch.virtual.") }
    var isPhysical: Bool { transport != kAudioDeviceTransportTypeVirtual &&
        transport != kAudioDeviceTransportTypeAggregate && !isAudioPatch }
    var transportName: String {
        switch transport {
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeBuiltIn: "Встроенное"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeVirtual: "Виртуальное"
        case kAudioDeviceTransportTypeAggregate: "Агрегатное"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        default: "CoreAudio"
        }
    }
}

enum PatchError: LocalizedError {
    case status(String, OSStatus)
    case message(String)
    var errorDescription: String? {
        switch self {
        case let .status(operation, code): "\(operation): OSStatus \(code)"
        case let .message(message): message
        }
    }
}

func checkAudio(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw PatchError.status(operation, status) }
}
