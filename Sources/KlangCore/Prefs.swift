import Foundation

public struct Prefs: Codable, Equatable {
    public var autoStart: Bool
    public var bufferFrames: Int
    public var outputUID: String?
    /// Maps a physical output device UID to the profile applied when it is the target.
    public var deviceProfiles: [String: String]

    public init(autoStart: Bool, bufferFrames: Int, outputUID: String?,
                deviceProfiles: [String: String] = [:]) {
        self.autoStart = autoStart
        self.bufferFrames = bufferFrames
        self.outputUID = outputUID
        self.deviceProfiles = deviceProfiles
    }

    // Custom decode so an older prefs.json (written before deviceProfiles existed)
    // upgrades in place instead of resetting every field to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        bufferFrames = try c.decodeIfPresent(Int.self, forKey: .bufferFrames) ?? 256
        outputUID = try c.decodeIfPresent(String.self, forKey: .outputUID)
        deviceProfiles = try c.decodeIfPresent([String: String].self, forKey: .deviceProfiles) ?? [:]
    }

    public static let defaults = Prefs(autoStart: false, bufferFrames: 256,
                                       outputUID: nil, deviceProfiles: [:])
}

public enum PrefsStore {
    public static func load(from url: URL) -> Prefs {
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(Prefs.self, from: data) else {
            return .defaults
        }
        return p
    }
    public static func save(_ prefs: Prefs, to url: URL) throws {
        let data = try JSONEncoder().encode(prefs)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
