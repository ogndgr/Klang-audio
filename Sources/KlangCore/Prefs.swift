import Foundation

public struct Prefs: Codable, Equatable {
    public var autoStart: Bool
    public var bufferFrames: Int
    public var outputUID: String?
    public var inputUID: String?

    public static let defaults = Prefs(autoStart: false, bufferFrames: 256,
                                       outputUID: nil, inputUID: nil)
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
