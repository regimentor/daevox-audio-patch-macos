import Foundation

struct ConfigurationManager {
    let url: URL
    init(url: URL? = nil) {
        self.url = url ?? URL.applicationSupportDirectory.appending(path: "AudioPatch/configuration.json")
    }
    func load() throws -> PatchConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return PatchConfiguration() }
        // Do not silently overwrite corrupt or newer configurations.
        return try JSONDecoder().decode(PatchConfiguration.self, from: Data(contentsOf: url)).validated()
    }
    func save(_ configuration: PatchConfiguration) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration.validated())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}
