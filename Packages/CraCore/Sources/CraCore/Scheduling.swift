import Foundation

/// The clock behind every decision Cra makes from time: auto-archive, tab sleep, live folder
/// expiry, the command file poll. The app runs on its `LiveScheduler`; a test passes a manual
/// one and advances it, so a 30-minute timer runs in a millisecond (Tests/Support/ManualScheduler).
/// Animation and hover delays stay on Timer: they perform, they don't decide.
@MainActor
public protocol Scheduler: AnyObject {
    var now: Date { get }
    @discardableResult func after(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ScheduledWork
    @discardableResult func every(_ interval: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ScheduledWork
}

/// Cancels the work it came from; letting it go does not.
@MainActor
public final class ScheduledWork {
    private var onCancel: (() -> Void)?
    public private(set) var isCancelled = false
    public init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancel?()
        onCancel = nil
    }
}
