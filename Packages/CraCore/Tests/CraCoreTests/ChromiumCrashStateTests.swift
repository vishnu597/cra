import CraCore
import Foundation
import Testing

struct ChromiumCrashStateTests {
    let cache: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ChromiumCrashStateTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func profile(_ name: String, preferences: [String: Any]?, session: Bool = true) -> URL {
        let dir = cache.appendingPathComponent(name, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir.appendingPathComponent("Sessions"), withIntermediateDirectories: true)
        if session { try! Data("x".utf8).write(to: dir.appendingPathComponent("Sessions/Session_1")) }
        if let preferences { try! JSONSerialization.data(withJSONObject: preferences).write(to: dir.appendingPathComponent("Preferences")) }
        return dir
    }

    func preferences(_ dir: URL) -> [String: Any] {
        let data = try! Data(contentsOf: dir.appendingPathComponent("Preferences"))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func listsDefaultAndSpaceProfilesOnly() {
        for name in ["Default", "Profile 1A2B", "System Profile", "Guest Profile", "Crashpad"] {
            _ = profile(name, preferences: nil)
        }
        #expect(ChromiumCrashState.folders(in: cache).map(\.lastPathComponent) == ["Default", "Profile 1A2B"])
    }

    @Test func aMissingCacheHasNoProfiles() {
        #expect(ChromiumCrashState.folders(in: cache.appendingPathComponent("none")).isEmpty)
    }

    /// After a crash Chromium would reopen the saved session in a stock window.
    @Test func aCrashedProfileIsMarkedCleanAndLosesItsSession() {
        let dir = profile("Default", preferences: [
            "profile": ["exit_type": "Crashed", "exited_cleanly": false, "name": "Cra"],
            "browser": ["window_placement": ["left": 10]],
        ])
        ChromiumCrashState.markExitedCleanly(dir)
        let prefs = preferences(dir)
        let state = prefs["profile"] as? [String: Any]
        #expect(state?["exit_type"] as? String == "Normal")
        #expect((state?["exited_cleanly"] as? NSNumber)?.boolValue == true)
        #expect(state?["name"] as? String == "Cra")
        #expect(prefs["browser"] != nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Sessions").path))
    }

    @Test func aCleanProfileIsLeftAsWritten() throws {
        let dir = profile("Default", preferences: ["profile": ["exit_type": "Normal", "exited_cleanly": true]])
        let file = dir.appendingPathComponent("Preferences")
        try Data("{\"profile\": {\"exit_type\": \"Normal\", \"exited_cleanly\": true}}".utf8).write(to: file)
        ChromiumCrashState.markExitedCleanly(dir)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\"profile\": {\"exit_type\": \"Normal\", \"exited_cleanly\": true}}")
    }

    @Test func missingOrUnreadablePreferencesAreLeftAlone() throws {
        let bare = profile("Default", preferences: nil)
        ChromiumCrashState.markExitedCleanly(bare)
        #expect(!FileManager.default.fileExists(atPath: bare.appendingPathComponent("Preferences").path))
        #expect(!FileManager.default.fileExists(atPath: bare.appendingPathComponent("Sessions").path))

        let broken = profile("Profile 1", preferences: nil)
        let file = broken.appendingPathComponent("Preferences")
        try Data("not json".utf8).write(to: file)
        ChromiumCrashState.markExitedCleanly(broken)
        #expect(try String(contentsOf: file, encoding: .utf8) == "not json")

        let noProfile = profile("Profile 2", preferences: ["browser": [:] as [String: Any]])
        ChromiumCrashState.markExitedCleanly(noProfile)
        #expect(preferences(noProfile)["profile"] == nil)
    }
}
