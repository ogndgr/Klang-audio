import Foundation

public enum AppPaths {
    public static func supportDir(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Klang")
    }
    public static func prefsURL(home: URL) -> URL {
        supportDir(home: home).appendingPathComponent("prefs.json")
    }
    public static func fullStateURL(home: URL) -> URL {
        supportDir(home: home).appendingPathComponent("headphonelab.fullstate.plist")
    }
}
