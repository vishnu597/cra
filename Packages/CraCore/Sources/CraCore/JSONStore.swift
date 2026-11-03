import Foundation

/// Where CraCore reports what went wrong without stopping: a file it could not read or write.
/// The app points it at its own log (AppComposition); a test can collect the lines.
public enum CoreLog {
    nonisolated(unsafe) public static var fault: (String) -> Void = { print("Cra fault: \($0)") }
    /// Something worth a line in the log that went as it should (history cleared).
    nonisolated(unsafe) public static var note: (String) -> Void = { print("Cra: \($0)") }
    /// How long a file took to decode or write, in ms; the Mac app hands it to its performance
    /// recorder (Perf, wired in main.swift). Called off the main thread for writes.
    nonisolated(unsafe) public static var time: (PerfMetric, Double) -> Void = { _, _ in }

    static func ms(since start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e6 }
}

/// Where every JSONStore encodes and writes, one file at a time and in call order. Off the
/// main thread, which is also Chromium's UI thread: encoding a 2000-entry archive.json
/// took ~30 ms there, two to four dropped frames after every tab switch.
private let persistenceQueue = DispatchQueue(label: "dk.kildahl.cra.persistence", qos: .utility)

/// One JSON file, loaded once, saved with a short debounce. Writes are atomic
/// and the previous version is kept as `<name>.bak`, which is what Arc does
/// with its timestamped Storable*.json copies, minus the pile-up.
public final class JSONStore<T: Codable> {
    public let url: URL
    private var pending: DispatchWorkItem?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// `name` in the data folder `directory`.
    public init(_ name: String, in directory: URL) { url = directory.appendingPathComponent(name) }

    public func load(or fallback: () -> T) -> T {
        guard let data = try? Data(contentsOf: url) else { return fallback() }
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            defer { CoreLog.time(.jsonLoad, CoreLog.ms(since: started)) }
            return try decoder.decode(T.self, from: data)
        } catch {
            // Corrupt file: keep it aside for forensics and start fresh.
            CoreLog.fault("\(url.lastPathComponent) unreadable, set aside as .corrupt: \(error)")
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
            return fallback()
        }
    }

    public func save(_ value: T, delay: TimeInterval = 0.4) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.write(value) }
        pending = item
        persistenceQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Writes before returning (quit, launch-time bookkeeping), after any write in flight.
    public func saveNow(_ value: T) {
        pending?.cancel()
        pending = nil
        persistenceQueue.sync { write(value) }
    }

    private func write(_ value: T) {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { CoreLog.time(.jsonSave, CoreLog.ms(since: started)) }
        let data: Data
        do { data = try encoder.encode(value) } catch {
            CoreLog.fault("\(url.lastPathComponent) not saved, encoding failed: \(error)")
            return
        }
        let fm = FileManager.default
        let bak = url.appendingPathExtension("bak")
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: url, to: bak)
        }
        do { try data.write(to: url, options: .atomic) } catch {
            CoreLog.fault("\(url.lastPathComponent) not saved: \(error.localizedDescription)")
        }
    }
}
