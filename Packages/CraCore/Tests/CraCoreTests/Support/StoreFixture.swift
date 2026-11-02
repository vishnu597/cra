import CraCore
import Foundation

/// A SidebarStore on a data folder of its own and a manual clock: what the store tests build on.
@MainActor
struct StoreFixture {
    let directory: URL
    let clock: ManualScheduler
    let store: SidebarStore
    final class Deleted { var names: [String] = [] }
    let deletedProfiles: Deleted

    init(directory: URL? = nil, clock: ManualScheduler? = nil, arcShowsToolbar: Bool? = nil) {
        let clock = clock ?? ManualScheduler()
        let dir = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("cra-core-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
        self.clock = clock
        let deleted = Deleted()
        deletedProfiles = deleted
        store = SidebarStore(directory: dir, chromiumCache: dir.appendingPathComponent("Chromium", isDirectory: true), clock: clock,
                             arcShowsToolbar: { arcShowsToolbar }, onProfileDeleted: { deleted.names.append($0) })
    }

    /// The same data folder loaded again, as the next launch would.
    func reopened() -> StoreFixture {
        store.saveAll()
        return StoreFixture(directory: directory, clock: clock)
    }

    var space: Space { store.focusedSpace }
    func today(_ space: Space? = nil) -> [UUID] { store.item((space ?? self.space).todayContainerID)?.children ?? [] }
    func pinned(_ space: Space? = nil) -> [UUID] { store.item((space ?? self.space).pinnedContainerID)?.children ?? [] }
    func favorites(_ space: Space? = nil) -> [UUID] { store.item((space ?? self.space).favoritesContainerID)?.children ?? [] }
    var sound: Bool { store.integrityProblems().isEmpty }

    /// Writes `value` as the data folder's `name`, the way Cra writes it.
    func write<T: Codable>(_ value: T, as name: String) {
        JSONStore<T>(name, in: directory).saveNow(value)
    }
}
