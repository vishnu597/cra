import Foundation

/// Chromium's profile folders in Cra's cache, and the crash-recovery state Cra clears in them.
///
/// When the previous run did not quit cleanly (killed, crashed), Chromium leaves
/// `profile.exit_type = "Crashed"` in the profile's Preferences and restores its last session
/// (the profile's Sessions folder) into a stock Chromium window as soon as the first page is
/// made. Cra restores its own tabs, so before Chromium starts the saved session is dropped and
/// the profile marked clean. (The Mac bridge does the same in CraCEF.mm.)
public enum ChromiumCrashState {
    /// Default plus the spaces' own profiles ("Profile <id>").
    public static func folders(in cache: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        return names.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
            .map { cache.appendingPathComponent($0, isDirectory: true) }
    }

    /// Drops the profile's saved session and marks its last exit clean. The rest of
    /// Preferences is kept; a missing or unreadable file is left alone.
    public static func markExitedCleanly(_ profile: URL) {
        try? FileManager.default.removeItem(at: profile.appendingPathComponent("Sessions", isDirectory: true))
        let prefs = profile.appendingPathComponent("Preferences")
        guard let data = try? Data(contentsOf: prefs),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var state = root["profile"] as? [String: Any] else { return }
        if state["exit_type"] as? String == "Normal" && isTrue(state["exited_cleanly"]) { return }
        state["exit_type"] = "Normal"
        state["exited_cleanly"] = true
        root["profile"] = state
        guard let out = try? JSONSerialization.data(withJSONObject: root) else { return }
        try? out.write(to: prefs, options: .atomic)
    }

    private static func isTrue(_ value: Any?) -> Bool {
        (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
    }
}
