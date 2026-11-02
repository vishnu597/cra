import Foundation

extension SidebarStore {
    /// The store on Cra's data folder (CRA_DATA_DIR for a test instance), with Arc's toolbar
    /// setting for the settings migration and profile folders removed at the next launch.
    convenience init(clock: Scheduler? = nil) {
        self.init(directory: AppPaths.supportDir, chromiumCache: AppPaths.chromiumCache,
                  clock: clock ?? LiveScheduler.shared, arcShowsToolbar: { ArcImporter.showsToolbar },
                  onProfileDeleted: ProfileCleanup.schedule)
    }
}
