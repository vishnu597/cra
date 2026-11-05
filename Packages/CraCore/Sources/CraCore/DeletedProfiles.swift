import Foundation

/// Folders of deleted profiles, removed before Chromium starts: it keeps a loaded profile's files
/// open for the rest of the session, so SidebarStore.deleteProfile only schedules the folder
/// (its `onProfileDeleted`), and the next launch removes it. The list is deleted-profiles.json in
/// the data folder, the file the Mac app's ProfileCleanup keeps (Windows uses this type).
public struct DeletedProfiles {
    private let file: JSONStore<[String]>
    private let chromiumCache: URL

    public init(directory: URL, chromiumCache: URL) {
        file = JSONStore("deleted-profiles.json", in: directory)
        self.chromiumCache = chromiumCache
    }

    /// `directoryName` ("Profile <id>") goes at the next launch.
    public func schedule(_ directoryName: String) {
        file.saveNow(Array(Set(file.load(or: { [] }) + [directoryName])).sorted())
    }

    /// Removes the scheduled folders and empties the list; call before Chromium initializes.
    /// Only "Profile …" folders are ever removed, never Default. Returns the names removed.
    @discardableResult
    public func run() -> [String] {
        let names = file.load(or: { [] })
        guard !names.isEmpty else { return [] }
        let removed = names.filter { $0.hasPrefix("Profile ") && !$0.contains("/") && !$0.contains("\\") && !$0.contains("..") }
        for name in removed {
            try? FileManager.default.removeItem(at: chromiumCache.appendingPathComponent(name, isDirectory: true))
        }
        file.saveNow([])
        return removed
    }
}
