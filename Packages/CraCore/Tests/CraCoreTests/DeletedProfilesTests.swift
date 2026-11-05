import CraCore
import Foundation
import Testing

/// A deleted profile's Chromium folder goes at the next launch, and nothing else does.
struct DeletedProfilesTests {
    private func folder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DeletedProfilesTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aScheduledProfileFolderGoesAtTheNextRun() throws {
        let data = folder(), cache = data.appendingPathComponent("Chromium", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: data) }
        let gone = BrowserProfile(id: UUID(), name: "Work"), kept = BrowserProfile(id: UUID(), name: "Home")
        for name in ["Default", gone.directoryName, kept.directoryName] {
            try FileManager.default.createDirectory(at: cache.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let cleanup = DeletedProfiles(directory: data, chromiumCache: cache)
        cleanup.schedule(gone.directoryName)
        cleanup.schedule(gone.directoryName)
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent(gone.directoryName).path), "kept until the next launch")

        #expect(DeletedProfiles(directory: data, chromiumCache: cache).run() == [gone.directoryName])
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent(gone.directoryName).path))
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent(kept.directoryName).path))
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("Default").path))
        #expect(cleanup.run().isEmpty, "the list is emptied")
    }

    @Test func onlyProfileFoldersAreEverRemoved() throws {
        let data = folder(), cache = data.appendingPathComponent("Chromium", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: data) }
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("Default"), withIntermediateDirectories: true)
        let cleanup = DeletedProfiles(directory: data, chromiumCache: cache)
        for name in ["Default", "Profile ../../x", ""] { cleanup.schedule(name) }
        #expect(cleanup.run().isEmpty)
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("Default").path))
    }
}
