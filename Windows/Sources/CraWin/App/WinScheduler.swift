import CraCore
import Foundation
import WinAppSDK
import WindowsFoundation

/// The Windows app's clock (CraCore's `Scheduler`), the counterpart of the Mac's LiveScheduler:
/// DispatcherQueue timers on the UI thread. Foundation's Timer needs a RunLoop, and WinUI's
/// message loop doesn't run one.
@MainActor
final class WinScheduler: Scheduler {
    private let queue: WinAppSDK.DispatcherQueue
    /// Started timers, kept alive until they are cancelled or have fired for the last time.
    private var running: [ObjectIdentifier: DispatcherQueueTimer] = [:]

    init(queue: WinAppSDK.DispatcherQueue) { self.queue = queue }

    var now: Date { Date() }

    func after(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ScheduledWork {
        timer(delay, repeats: false, work)
    }

    func every(_ interval: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ScheduledWork {
        timer(interval, repeats: true, work)
    }

    private func timer(_ interval: TimeInterval, repeats: Bool, _ work: @escaping @MainActor () -> Void) -> ScheduledWork {
        guard let timer = try? queue.createTimer() else { return ScheduledWork {} }
        let key = ObjectIdentifier(timer)
        timer.interval = TimeSpan(duration: Int64(max(0, interval) * 10_000_000))
        timer.isRepeating = repeats
        let handle = ScheduledWork { [weak self] in
            try? timer.stop()
            self?.running[key] = nil
        }
        timer.tick.addHandler { [weak self, weak handle] _, _ in
            guard let handle, !handle.isCancelled else { return }
            if !repeats { self?.running[key] = nil }
            work()
        }
        running[key] = timer
        try? timer.start()
        return handle
    }
}
