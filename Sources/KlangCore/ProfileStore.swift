import Foundation

/// A named snapshot of the Headphone Lab AU state. The state itself lives in a
/// separate plist keyed by `id`; this struct is just the index entry.
public struct Profile: Codable, Equatable {
    public let id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Persists the profile index (`profiles.json`) and resolves per-profile state URLs.
/// The AU ClassInfo bytes are read/written by AudioChain via `stateURL(id:)`.
public struct ProfileStore {
    private let home: URL
    public init(home: URL) { self.home = home }

    public func list() -> [Profile] {
        guard let data = try? Data(contentsOf: AppPaths.profilesIndexURL(home: home)),
              let profiles = try? JSONDecoder().decode([Profile].self, from: data) else { return [] }
        return profiles
    }

    @discardableResult
    public func create(name: String) throws -> Profile {
        let profile = Profile(id: UUID().uuidString, name: name)
        var profiles = list()
        profiles.append(profile)
        try saveIndex(profiles)
        return profile
    }

    public func rename(id: String, to name: String) throws {
        var profiles = list()
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].name = name
        try saveIndex(profiles)
    }

    public func delete(id: String) throws {
        var profiles = list()
        profiles.removeAll { $0.id == id }
        try saveIndex(profiles)
        try? FileManager.default.removeItem(at: stateURL(id: id))
    }

    public func stateURL(id: String) -> URL {
        AppPaths.profileStateURL(home: home, id: id)
    }

    /// First launch after the update: if there is a legacy single-state plist and no
    /// profile index yet, adopt it as a "Default" profile. Non-destructive: the legacy
    /// file is copied, not moved. Returns the created profile, or nil if nothing to do.
    @discardableResult
    public func migrateLegacyFullStateIfNeeded() throws -> Profile? {
        let indexURL = AppPaths.profilesIndexURL(home: home)
        guard !FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        let legacy = AppPaths.fullStateURL(home: home)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return nil }
        let profile = Profile(id: UUID().uuidString, name: "Default")
        let dest = stateURL(id: profile.id)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: legacy, to: dest)
        try saveIndex([profile])
        return profile
    }

    private func saveIndex(_ profiles: [Profile]) throws {
        let url = AppPaths.profilesIndexURL(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: url, options: .atomic)
    }
}
