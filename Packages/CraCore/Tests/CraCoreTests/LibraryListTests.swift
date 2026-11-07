import CraCore
import Foundation
import Testing

/// The Library's lists (LibraryView on the Mac, Windows' Library column): search, newest first,
/// a header per day.
struct LibraryListTests {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    static let locale = Locale(identifier: "en_US")
    /// 7 Nov 2026, 15:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_794_063_600)
    static let hour: TimeInterval = 3600

    static func archived(_ url: String, title: String, hoursAgo: Double) -> ArchivedItem {
        ArchivedItem(archivedAt: now.addingTimeInterval(-hoursAgo * hour), reason: .manual, sourceSpaceID: nil, wasPinned: false,
                     item: .tab(url, title: title, parent: nil))
    }

    static let archive = [
        archived("https://example.com/", title: "Example Domain", hoursAgo: 1),
        archived("https://www.iana.org/help/example-domains", title: "Example Domains", hoursAgo: 2),
        archived("https://permission.site/", title: "permission.site", hoursAgo: 20),
        archived("https://github.com/", title: "GitHub", hoursAgo: 60),
    ]

    @Test func archivedTabsGroupByDayNewestFirst() {
        let sections = LibraryList.archive(Self.archive, matching: "", now: Self.now, calendar: Self.calendar, locale: Self.locale)
        #expect(sections.map(\.title) == ["Today", "Yesterday", "Nov 5, 2026"])
        #expect(sections.map { $0.items.map(\.item.displayTitle) } == [["Example Domain", "Example Domains"], ["permission.site"], ["GitHub"]])
    }

    @Test func searchMatchesTitleOrAddressIgnoringCase() {
        let byTitle = LibraryList.archive(Self.archive, matching: "  GITHUB ", now: Self.now, calendar: Self.calendar, locale: Self.locale)
        #expect(byTitle.flatMap(\.items).map(\.item.displayTitle) == ["GitHub"])
        let byURL = LibraryList.archive(Self.archive, matching: "iana.org", now: Self.now, calendar: Self.calendar, locale: Self.locale)
        #expect(byURL.flatMap(\.items).map(\.item.displayTitle) == ["Example Domains"])
        #expect(LibraryList.archive(Self.archive, matching: "nothing", now: Self.now).isEmpty)
    }

    @Test func downloadsListFilesStillOnDiskNewestFirstByName() {
        let entries = [
            DownloadHistory.Entry(path: "C:\\Users\\me\\Downloads\\report.pdf", date: Self.now.addingTimeInterval(-30 * Self.hour)),
            DownloadHistory.Entry(path: "/Users/me/Downloads/gone.zip", date: Self.now.addingTimeInterval(-3 * Self.hour)),
            DownloadHistory.Entry(path: "/Users/me/Downloads/Photo.PNG", date: Self.now.addingTimeInterval(-1 * Self.hour)),
        ]
        let exists: (String) -> Bool = { !$0.hasSuffix("gone.zip") }
        let all = LibraryList.downloads(entries, matching: "", exists: exists, now: Self.now, calendar: Self.calendar, locale: Self.locale)
        #expect(all.map(\.title) == ["Today", "Yesterday"])
        #expect(all.flatMap(\.items).map { LibraryList.fileName($0.path) } == ["Photo.PNG", "report.pdf"])
        let photo = LibraryList.downloads(entries, matching: "photo", exists: exists, now: Self.now, calendar: Self.calendar)
        #expect(photo.flatMap(\.items).map(\.path) == ["/Users/me/Downloads/Photo.PNG"])
        // The search is on the file name, not the folders.
        #expect(LibraryList.downloads(entries, matching: "users", exists: exists, now: Self.now).isEmpty)
    }

    @Test func emptyPagesSayWhyTheyAreEmpty() {
        #expect(LibraryList.empty(.archive, hasAny: false)
            == LibraryList.Empty(symbol: "archivebox", title: "Nothing here yet!", detail: "Tabs you close end up here."))
        #expect(LibraryList.empty(.downloads, hasAny: false).detail == "Files you download show up here.")
        #expect(LibraryList.empty(.downloads, hasAny: true) == LibraryList.Empty(symbol: "arrow.down.circle", title: "No matches", detail: nil))
    }

    @Test func pagesKeepArcsRailOrderAndNames() {
        #expect(LibraryPage.allCases.map(\.title) == ["Downloads", "Spaces", "Archived Tabs"])
        #expect(LibraryPage.archive.searchPrompt == "Search Archive…")
        #expect(LibraryPage.downloads.selectedSymbol == "arrow.down.circle.fill")
    }
}
