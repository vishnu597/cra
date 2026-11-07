import Foundation

/// The Library's pages Cra has, in the order of Arc's rail (which also lists Media, Easels and
/// Boosts). The Mac's LibraryView and Windows' Library column draw them.
public enum LibraryPage: String, CaseIterable, Sendable {
    case downloads, spaces, archive

    public var title: String {
        switch self {
        case .downloads: "Downloads"
        case .spaces: "Spaces"
        case .archive: "Archived Tabs"
        }
    }

    /// The rail's SF Symbol (WinGlyph maps it on Windows).
    public var symbol: String {
        switch self {
        case .downloads: "arrow.down.circle"
        case .spaces: "square.on.square"
        case .archive: "archivebox"
        }
    }

    public var selectedSymbol: String { symbol + ".fill" }
    public var searchPrompt: String { self == .downloads ? "Search Downloads…" : "Search Archive…" }
}

/// The Library's sizes, measured on Arc 1.170 (LibraryView on the Mac has the whole list).
public enum LibraryLayout {
    /// The page rail's width.
    public static let rail = 113.0
    /// Arc's Library sidebar was 70 pt wider than the 347 pt tab sidebar.
    public static let extraWidth = 70.0
    /// A day's header and an item's row.
    public static let headerHeight = 40.0
    public static let rowHeight = 56.0
}

/// What a Library page lists: its items that match the search, newest first, under a header per
/// day ("Today", "Yesterday", then the date), and what it says when there are none.
public enum LibraryList {
    public struct Section<Item> {
        public let title: String
        public let items: [Item]
    }

    /// The archived tabs whose title or address holds the search (archive is newest first).
    public static func archive(_ archive: [ArchivedItem], matching query: String, now: Date = Date(),
                               calendar: Calendar = .current, locale: Locale = .current) -> [Section<ArchivedItem>] {
        let needle = needle(query)
        let shown = needle.isEmpty ? archive : archive.filter {
            $0.item.displayTitle.lowercased().contains(needle) || ($0.item.tab?.url.lowercased().contains(needle) ?? false)
        }
        return grouped(shown, date: \.archivedAt, now: now, calendar: calendar, locale: locale)
    }

    /// The finished downloads still on disk whose file name holds the search, newest first
    /// (downloads.json keeps them oldest first).
    public static func downloads(_ entries: [DownloadHistory.Entry], matching query: String, exists: (String) -> Bool,
                                 now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current)
        -> [Section<DownloadHistory.Entry>] {
        let needle = needle(query)
        let all = entries.reversed().filter { exists($0.path) }
        let shown = needle.isEmpty ? all : all.filter { fileName($0.path).lowercased().contains(needle) }
        return grouped(shown, date: \.date, now: now, calendar: calendar, locale: locale)
    }

    /// A path's last component, for either platform's separators.
    public static func fileName(_ path: String) -> String {
        String(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? Substring(path))
    }

    /// "Today", "Yesterday", or the day in the locale's medium style.
    public static func dayTitle(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    /// The page's empty state: nothing at all yet, or nothing matching the search.
    public struct Empty: Equatable, Sendable {
        public let symbol: String
        public let title: String
        public let detail: String?

        public init(symbol: String, title: String, detail: String?) {
            self.symbol = symbol
            self.title = title
            self.detail = detail
        }
    }

    public static func empty(_ page: LibraryPage, hasAny: Bool) -> Empty {
        let detail = page == .downloads ? "Files you download show up here." : "Tabs you close end up here."
        return Empty(symbol: page.symbol, title: hasAny ? "No matches" : "Nothing here yet!", detail: hasAny ? nil : detail)
    }

    private static func needle(_ query: String) -> String {
        query.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// In the items' order, a section per day as each day first appears.
    private static func grouped<T>(_ items: [T], date: KeyPath<T, Date>, now: Date, calendar: Calendar, locale: Locale) -> [Section<T>] {
        var order: [String] = []
        var groups: [String: [T]] = [:]
        for item in items {
            let title = dayTitle(item[keyPath: date], now: now, calendar: calendar, locale: locale)
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(item)
        }
        return order.map { Section(title: $0, items: groups[$0] ?? []) }
    }
}
