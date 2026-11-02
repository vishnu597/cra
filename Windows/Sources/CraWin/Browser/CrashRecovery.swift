import CraCore
import Foundation

/// Run before Chromium starts: Cra restores its own tabs, so Chromium's own crash recovery
/// (a stock Chromium window with the last session, after a run that didn't quit cleanly) is
/// turned off by clearing it from the profiles (ChromiumProfile).
enum CrashRecovery {
    static func prepare(cache: URL) {
        // A running Cra keeps Chromium's lockfile open, so it can't be deleted: leave that
        // Cra's profiles alone (this launch is handed to it). A stale one is deleted here and
        // Chromium makes a new one.
        let lock = cache.appendingPathComponent("lockfile")
        if FileManager.default.fileExists(atPath: lock.path) {
            guard (try? FileManager.default.removeItem(at: lock)) != nil else { return }
        }
        for profile in ChromiumProfile.folders(in: cache) {
            ChromiumProfile.markExitedCleanly(profile)
        }
    }
}
