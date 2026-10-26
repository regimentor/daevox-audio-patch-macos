import CoreAudio
import Foundation

struct DriverStatistics: Sendable {
    var missingFrames: UInt64 = 0
    var writtenFrames: UInt64 = 0
    var clients: UInt64 = 0
    var delayFrames: UInt64 = 1024
}

@MainActor
final class VirtualDriverController {
    static let bundleID = "audio.audio-patch.driver"
    static let configurationSelector: AudioObjectPropertySelector = 0x61706366 // apcf
    static let statisticsSelector: AudioObjectPropertySelector = 0x61707374 // apst
    var pluginID: AudioObjectID? {
        var address = HAL.address(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
        var bundleID: CFString = Self.bundleID as CFString
        var id: AudioObjectID = 0
        var size: UInt32 = 4
        let status = withUnsafePointer(to: &bundleID) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id)
        }
        return status == noErr && id != 0 ? id : nil
    }
    func synchronize(_ devices: [VirtualDeviceConfiguration]) throws {
        guard let pluginID else { throw PatchError.message("AudioPatch.driver не загружен. Установите драйвер и перезагрузите Mac.") }
        var property: CFPropertyList = devices.map {
            ["uid": $0.uid, "name": $0.name, "channels": $0.channels] as [String: Any]
        } as CFArray
        var address = HAL.address(Self.configurationSelector)
        // Read before writing, including with older installed drivers that notify
        // for an unchanged property. Never depend on notifications being deduplicated.
        var current: Unmanaged<CFPropertyList>?
        var currentSize = UInt32(MemoryLayout<CFPropertyList>.size)
        let readStatus = withUnsafeMutablePointer(to: &current) {
            AudioObjectGetPropertyData(pluginID, &address, 0, nil, &currentSize, $0)
        }
        try checkAudio(readStatus, "Чтение конфигурации виртуальных устройств")
        if let current = current?.takeRetainedValue(), CFEqual(current, property) { return }
        let status = withUnsafePointer(to: &property) {
            AudioObjectSetPropertyData(pluginID, &address, 0, nil, UInt32(MemoryLayout<CFPropertyList>.size), $0)
        }
        if status == kAudioHardwareIllegalOperationError {
            throw PatchError.message("Драйвер занят аудиоклиентом или отклонил конфигурацию. Закройте Discord/QuickTime и остановите маршруты перед изменением списка устройств.")
        }
        try checkAudio(status, "Конфигурация виртуальных устройств")
    }
    func deviceID(uid: String) -> AudioObjectID? {
        HAL.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).first {
            HAL.string($0, kAudioDevicePropertyDeviceUID) == uid
        }
    }
    func statistics(device: AudioObjectID) -> DriverStatistics {
        var address = HAL.address(Self.statisticsSelector)
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<CFPropertyList>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr, let property = value?.takeRetainedValue() as? [String: NSNumber] else { return DriverStatistics() }
        return DriverStatistics(missingFrames: property["missingFrames"]?.uint64Value ?? 0,
            writtenFrames: property["writtenFrames"]?.uint64Value ?? 0, clients: property["clients"]?.uint64Value ?? 0,
            delayFrames: property["delayFrames"]?.uint64Value ?? 1024)
    }
    var embeddedDriver: URL? { Bundle.main.resourceURL?.appending(path: "Driver/AudioPatch.driver") }
    var isInstalled: Bool { FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/HAL/AudioPatch.driver") }

    func install() async throws {
        guard let source = embeddedDriver, FileManager.default.fileExists(atPath: source.path) else {
            throw PatchError.message("В приложении отсутствует собранный AudioPatch.driver.")
        }
        // Validate the exact payload before asking macOS for administrator authorization.
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: source.appending(path: "Contents/Info.plist")), format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == Self.bundleID else { throw PatchError.message("Некорректный bundle ID драйвера.") }
        try await Task.detached {
            let verify = Process(); verify.executableURL = URL(filePath: "/usr/bin/codesign")
            verify.arguments = ["--verify", "--strict", source.path]
            let errors = Pipe(); verify.standardError = errors
            try verify.run()
            let message = errors.fileHandleForReading.readDataToEndOfFile()
            verify.waitUntilExit()
            guard verify.terminationStatus == 0 else {
                throw PatchError.message("Подпись драйвера не прошла проверку: " + (String(data: message, encoding: .utf8) ?? "codesign"))
            }
        }.value
        let destination = "/Library/Audio/Plug-Ins/HAL/AudioPatch.driver"
        let staging = "/Library/Audio/Plug-Ins/HAL/.AudioPatch-install-\(UUID().uuidString)"
        let command = "/bin/mkdir -p /Library/Audio/Plug-Ins/HAL && /usr/bin/ditto \(Self.shellQuote(source.path)) \(Self.shellQuote(staging)) && /usr/sbin/chown -R root:wheel \(Self.shellQuote(staging)) && /bin/chmod -R go-w \(Self.shellQuote(staging)) && /bin/rm -rf \(Self.shellQuote(destination)) && /bin/mv \(Self.shellQuote(staging)) \(Self.shellQuote(destination))"
        try await Self.administrator(command)
    }
    func uninstall() async throws {
        try await Self.administrator("/bin/rm -rf /Library/Audio/Plug-Ins/HAL/AudioPatch.driver")
    }
    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func administrator(_ command: String) async throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        // Process IO and admin dialog wait are outside MainActor and outside audio threads.
        try await Task.detached {
            let process = Process(); process.executableURL = URL(filePath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let pipe = Pipe(); process.standardError = pipe
            try process.run()
            let errors = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw PatchError.message(String(data: errors, encoding: .utf8) ?? "Установка отменена.")
            }
        }.value
    }
}
