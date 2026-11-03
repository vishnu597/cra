import Foundation
import Observation

/// Finished downloads, newest last, for the list Arc shows when you hover the Library
/// button (its downloads tray). Kept in downloads.json; files deleted since drop out.
/// Downloads still running, and ones that failed or were cancelled, are listed too (`live`,
/// not saved): Arc shows progress and failures there, not in a toast.
///
/// The app keeps one (`DownloadHistory.shared` on the Mac) and draws the list; thumbnails are
/// the app's (Quick Look on the Mac).
@MainActor
@Observable
public final class DownloadHistory {
    public struct Entry: Codable, Identifiable, Equatable, Sendable {
        public let id: UUID
        public var path: String
        public var date: Date

        public init(id: UUID = UUID(), path: String, date: Date) {
            self.id = id
            self.path = path
            self.date = date
        }
    }

    /// Arc 1.170 listed every recent download it still had on disk (four, oldest at the
    /// top); how many it shows at most was not observed.
    public static let listLimit = 5
    /// How many finished downloads downloads.json keeps.
    public static let keep = 200

    public private(set) var entries: [Entry]
    @ObservationIgnored private let file: JSONStore<[Entry]>?
    @ObservationIgnored private let fileExists: (String) -> Bool

    /// `file` nil keeps nothing on disk (tests); `fileExists` decides which finished downloads
    /// are still listed.
    public init(file: JSONStore<[Entry]>?, fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.file = file
        self.fileExists = fileExists
        entries = file?.load(or: { [] }) ?? []
    }

    /// A download Chromium is still reporting on, or one that ended without a file.
    public struct Live: Identifiable, Equatable, Sendable {
        public let id: UInt32
        public var name: String
        public var path: String
        public var started: Date
        public var received: Int64
        public var total: Int64
        public var percent: Int
        public var bytesPerSecond: Double?
        /// The last point the speed was measured from.
        public var sampleBytes: Int64 = 0
        public var sampleAt = Date.distantPast
        public var failed = false
        public var cancelled = false
        /// When Chromium last reported on it (see MainWindowController.checkStalledDownloads).
        public var updated: Date

        public var running: Bool { !failed && !cancelled }
        public var row: DownloadRow.State {
            failed ? .failed : cancelled ? .cancelled : .downloading(received: received, total: total, bytesPerSecond: bytesPerSecond)
        }
    }

    public private(set) var live: [Live] = []

    /// A row in the hover list.
    public enum Listed: Identifiable, Equatable, Sendable {
        case finished(Entry)
        case live(Live)

        public var id: String {
            switch self {
            case .finished(let e): return e.id.uuidString
            case .live(let l): return "live-\(l.id)"
            }
        }
        public var date: Date {
            switch self {
            case .finished(let e): return e.date
            case .live(let l): return l.started
            }
        }
        /// The file's name as the list shows it.
        public var name: String {
            switch self {
            case .finished(let e): return URL(fileURLWithPath: e.path).lastPathComponent
            case .live(let l): return l.name
            }
        }
        /// The line under the name (DownloadRow.subtitle).
        public func subtitle(now: Date) -> String {
            switch self {
            case .finished(let e): return DownloadRow.subtitle(.finished(at: e.date), now: now)
            case .live(let l): return DownloadRow.subtitle(l.row, now: now)
            }
        }
    }

    /// The hover list: newest downloads, oldest first: files still on disk, and running, failed
    /// or cancelled ones.
    public var recent: [Listed] {
        let finished = entries.filter { fileExists($0.path) }.map(Listed.finished)
        return Array((finished + live.map(Listed.live)).sorted { $0.date < $1.date }.suffix(Self.listLimit))
    }

    public var hasRunningDownloads: Bool { live.contains(where: \.running) }

    /// Chromium's report on a download: running ones update their row, a finished one leaves for
    /// `add(path:)`, a failed or cancelled one stays listed for this session.
    public func report(id: UInt32, name: String, path: String, received: Int64, total: Int64, percent: Int,
                       complete: Bool, cancelled: Bool, failed: Bool, now: Date = Date()) {
        if complete {
            live.removeAll { $0.id == id }
            return
        }
        var l = live.first { $0.id == id } ?? Live(id: id, name: name, path: path, started: now, received: received, total: total,
                                                    percent: percent, updated: now)
        if l.sampleAt == .distantPast {
            (l.sampleBytes, l.sampleAt) = (received, now)
        } else if let speed = DownloadRow.speed(fromBytes: l.sampleBytes, at: l.sampleAt, toBytes: received, at: now) {
            l.bytesPerSecond = speed
            (l.sampleBytes, l.sampleAt) = (received, now)
        }
        l.updated = now
        l.name = name
        if !path.isEmpty { l.path = path }
        l.received = received
        l.total = total
        l.percent = percent
        l.failed = failed
        l.cancelled = cancelled
        if let i = live.firstIndex(where: { $0.id == id }) { live[i] = l } else { live.append(l) }
    }

    /// How a download Chromium went quiet about ended, read from the disk.
    public enum Settled: Equatable, Sendable {
        case complete(size: Int64)
        case cancelled
    }

    /// Chromium stops reporting a download once the tab that started it is gone (the download
    /// carries on, or ends, silently), which left its row "in progress" for good. A running row
    /// among `ids` that hasn't heard from Chromium for 5 s reads the file instead: gone means it
    /// ended, the full size with no .crdownload beside it means it's done. The app reports
    /// each one back as Chromium would have.
    public func settledStalled(among ids: Set<UInt32>, now: Date, fileSize: (String) -> Int64?,
                               partialExists: (String) -> Bool) -> [(live: Live, settled: Settled)] {
        live.compactMap { t in
            guard t.running, ids.contains(t.id), !t.path.isEmpty, now.timeIntervalSince(t.updated) > 5,
                  !partialExists(t.path) else { return nil }
            guard let size = fileSize(t.path) else { return (t, .cancelled) }
            return t.total > 0 && size >= t.total ? (t, .complete(size: size)) : nil
        }
    }

    /// Whether any of `ids` is still running (the app's stall check keeps going while one is).
    public func isRunning(anyOf ids: Set<UInt32>) -> Bool {
        live.contains { $0.running && ids.contains($0.id) }
    }

    @discardableResult
    public func add(path: String, now: Date = Date()) -> Entry {
        let entry = Entry(path: path, date: now)
        entries.append(entry)
        if entries.count > Self.keep { entries.removeFirst(entries.count - Self.keep) }
        file?.save(entries)
        return entry
    }

    /// A renamed (or reverted) file keeps its place in the list.
    public func move(from old: String, to new: String) {
        guard let i = entries.lastIndex(where: { $0.path == old }) else { return }
        entries[i].path = new
        file?.save(entries)
    }
}
