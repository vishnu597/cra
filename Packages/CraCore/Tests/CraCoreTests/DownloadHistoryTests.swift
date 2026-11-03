import CraCore
import Foundation
import Testing

/// The downloads list: finished files still on disk and live downloads, newest five, oldest first.
@MainActor
struct DownloadHistoryTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func history(onDisk: Set<String>? = nil) -> DownloadHistory {
        DownloadHistory(file: nil, fileExists: { onDisk?.contains($0) ?? true })
    }

    @Test func liveDownloadsMeasureTheirSpeed() throws {
        let h = history()
        h.report(id: 1, name: "a.zip", path: "", received: 0, total: 10_000_000, percent: 0, complete: false, cancelled: false, failed: false, now: t0)
        #expect(h.live.first?.bytesPerSecond == nil)
        h.report(id: 1, name: "a.zip", path: "/d/a.zip", received: 2_000_000, total: 10_000_000, percent: 20,
                 complete: false, cancelled: false, failed: false, now: t0.addingTimeInterval(2))
        let l = try #require(h.live.first)
        #expect(l.bytesPerSecond == 1_000_000)
        #expect(l.path == "/d/a.zip")
        #expect(h.hasRunningDownloads)
        #expect(h.recent.first?.subtitle(now: t0) == "2 MB of 10 MB — 1 MB/s")
    }

    @Test func aFinishedDownloadLeavesLiveForTheList() {
        let h = history()
        h.report(id: 1, name: "a.zip", path: "/d/a.zip", received: 5, total: 10, percent: 50, complete: false, cancelled: false, failed: false, now: t0)
        h.report(id: 1, name: "a.zip", path: "/d/a.zip", received: 10, total: 10, percent: 100, complete: true, cancelled: false, failed: false, now: t0)
        h.add(path: "/d/a.zip", now: t0)
        #expect(h.live.isEmpty)
        #expect(!h.hasRunningDownloads)
        #expect(h.recent.map(\.name) == ["a.zip"])
        #expect(h.recent.first?.subtitle(now: t0.addingTimeInterval(54)) == "54 seconds ago")
    }

    @Test func failuresStayListedButDontCountAsRunning() {
        let h = history()
        h.report(id: 2, name: "b.iso", path: "", received: 1, total: 9, percent: 10, complete: false, cancelled: false, failed: true, now: t0)
        h.report(id: 3, name: "c.iso", path: "", received: 1, total: 9, percent: 10, complete: false, cancelled: true, failed: false, now: t0)
        #expect(!h.hasRunningDownloads)
        #expect(h.recent.map { $0.subtitle(now: t0) } == ["Failed to Download", "Cancelled"])
    }

    @Test func listsTheNewestFiveStillOnDiskOldestFirst() {
        let h = history(onDisk: ["/d/1", "/d/3", "/d/4", "/d/5", "/d/6", "/d/7"])
        for i in 1...7 { h.add(path: "/d/\(i)", now: t0.addingTimeInterval(Double(i))) }
        // /d/2 is gone; seven left on disk but the list shows five.
        #expect(h.recent.map(\.name) == ["3", "4", "5", "6", "7"])
        h.report(id: 9, name: "new.bin", path: "", received: 0, total: 0, percent: -1, complete: false, cancelled: false, failed: false,
                 now: t0.addingTimeInterval(8))
        #expect(h.recent.map(\.name) == ["4", "5", "6", "7", "new.bin"])
    }

    @Test func quietDownloadsAreSettledFromTheDisk() {
        let h = history()
        func start(_ id: UInt32, _ path: String, total: Int64, at: Date) {
            h.report(id: id, name: path, path: path, received: 1, total: total, percent: 1, complete: false, cancelled: false, failed: false, now: at)
        }
        start(1, "/d/done", total: 100, at: t0)      // the full size on disk
        start(2, "/d/gone", total: 100, at: t0)      // no file: ended
        start(3, "/d/partial", total: 100, at: t0)   // .crdownload still there
        start(4, "/d/short", total: 100, at: t0)     // smaller than expected: still going
        start(5, "/d/recent", total: 100, at: t0.addingTimeInterval(4))  // heard from 2 s ago
        start(6, "/d/other", total: 100, at: t0)     // another window's
        let sizes: [String: Int64] = ["/d/done": 100, "/d/partial": 40, "/d/short": 40, "/d/recent": 100, "/d/other": 100]
        let settled = h.settledStalled(among: [1, 2, 3, 4, 5], now: t0.addingTimeInterval(6), fileSize: { sizes[$0] },
                                       partialExists: { $0 == "/d/partial" })
        #expect(settled.map { $0.live.id } == [1, 2])
        #expect(settled.map { $0.settled } == [.complete(size: 100), .cancelled])
        #expect(h.isRunning(anyOf: [4]))
        #expect(!h.isRunning(anyOf: [7]))
    }

    @Test func aPathIsListedOnceWithItsNewestDownload() {
        let h = history()
        h.add(path: "/d/a.dat", now: t0)
        h.add(path: "/d/b.dat", now: t0.addingTimeInterval(1))
        // a.dat was deleted, and a new download got its name.
        h.add(path: "/d/a.dat", now: t0.addingTimeInterval(2))
        #expect(h.entries.map(\.path) == ["/d/b.dat", "/d/a.dat"])
        #expect(h.recent.map(\.name) == ["b.dat", "a.dat"])
        #expect(h.recent.last?.date == t0.addingTimeInterval(2))
    }

    @Test func olderFilesWithAPathTwiceListItOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cra-downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"[{"date":"2027-01-15T08:00:00Z","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","path":"\/d\/a.dat"},"#
            + #"{"date":"2027-01-15T09:00:00Z","id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","path":"\/d\/a.dat"}]"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("downloads.json"))
        let h = DownloadHistory(file: JSONStore("downloads.json", in: dir), fileExists: { _ in true })
        #expect(h.recent.count == 1)
        #expect(h.recent.first?.date == ISO8601DateFormatter().date(from: "2027-01-15T09:00:00Z"))
    }

    @Test func keepsTwoHundred() {
        let h = history()
        for i in 0..<205 { h.add(path: "/d/\(i)", now: t0) }
        #expect(h.entries.count == DownloadHistory.keep)
        #expect(h.entries.first?.path == "/d/5")
    }

    @Test func aRenamedFileKeepsItsPlace() {
        let h = history()
        h.add(path: "/d/a", now: t0)
        h.add(path: "/d/b", now: t0.addingTimeInterval(1))
        h.move(from: "/d/a", to: "/d/a2")
        #expect(h.entries.map(\.path) == ["/d/a2", "/d/b"])
    }

    @Test func savesAndLoadsDownloadsJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cra-downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The file as the Mac app has always written it.
        let json = #"[{"date":"2027-01-15T08:00:00Z","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","path":"\/d\/a.zip"}]"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("downloads.json"))
        let h = DownloadHistory(file: JSONStore("downloads.json", in: dir), fileExists: { _ in true })
        #expect(h.entries.map(\.path) == ["/d/a.zip"])
        #expect(h.entries.first?.date == ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let store = JSONStore<[DownloadHistory.Entry]>("downloads.json", in: dir)
        h.add(path: "/d/b.zip", now: t0)
        store.saveNow(h.entries)
        let again = DownloadHistory(file: JSONStore("downloads.json", in: dir), fileExists: { _ in true })
        #expect(again.entries.map(\.path) == ["/d/a.zip", "/d/b.zip"])
    }
}
