import Foundation

/// Folders of deleted profiles, removed before Chromium starts (it keeps a loaded
/// profile's files open for the rest of the session).
enum ProfileCleanup {
    private static var file: JSONStore<[String]> { JSONStore("deleted-profiles.json") }

    static func schedule(_ directoryName: String) {
        file.saveNow(Array(Set(file.load(or: { [] }) + [directoryName])))
    }

    /// Call before Chromium initializes.
    static func run() {
        let names = file.load(or: { [] })
        guard !names.isEmpty else { return }
        for name in names where name.hasPrefix("Profile ") {
            try? FileManager.default.removeItem(at: AppPaths.chromiumCache.appendingPathComponent(name, isDirectory: true))
        }
        file.saveNow([])
    }
}

enum AppPaths {
    static let supportDir: URL = {
        // CRA_DATA_DIR runs a second, independent Cra (testing next to the installed one).
        // Finder launches have no shell environment. The dev bundle must still stay
        // out of the signed application's profile when opened directly.
        let folder = Bundle.main.bundleIdentifier == "dk.kildahl.cra.dev" ? "CraDev" : "Cra"
        let base = ProcessInfo.processInfo.environment["CRA_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static var chromiumCache: URL { supportDir.appendingPathComponent("Chromium", isDirectory: true) }
    static var favicons: URL {
        let u = supportDir.appendingPathComponent("Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var log: URL { supportDir.appendingPathComponent("chromium.log") }
    static func file(_ name: String) -> URL { supportDir.appendingPathComponent(name) }
}

extension JSONStore {
    /// `name` in Cra's data folder.
    convenience init(_ name: String) { self.init(name, in: AppPaths.supportDir) }
}
