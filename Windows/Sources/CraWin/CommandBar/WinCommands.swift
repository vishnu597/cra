import CraCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SF Symbols names (what CraCore's rows carry) as Segoe Fluent Icons glyphs, the font
/// FontIcon draws with on Windows 11 (Segoe MDL2 Assets, with the same code points, on 10).
enum WinGlyph {
    static func code(_ symbol: String) -> String {
        switch symbol {
        case "globe": return "\u{E774}"
        case "clock": return "\u{E81C}"
        case "command": return "\u{E756}"
        case "folder": return "\u{E8B7}"
        case "arrow.right.square": return "\u{E8AB}"
        case "gear": return "\u{E713}"
        case "tab": return "\u{E7C3}"
        case "space": return "\u{E8A9}"
        // The site control center's (the Mac's SF Symbols, in Segoe Fluent Icons).
        case "square.and.arrow.up": return "\u{E72D}"
        case "link": return "\u{E71B}"
        case "camera": return "\u{E722}"
        case "text.viewfinder": return "\u{E9A6}"
        case "lock.fill": return "\u{E72E}"
        case "lock.open.fill": return "\u{E785}"
        case "ellipsis": return "\u{E712}"
        case "slider.horizontal.3": return "\u{E9E9}"
        case "hammer.fill": return "\u{E90F}"
        case "shield.fill": return "\u{EA18}"
        case "gearshape.fill": return "\u{E713}"
        case "trash": return "\u{E74D}"
        // The Developer Mode bar's.
        case "terminal": return "\u{E756}"  // CommandPrompt
        case "scope": return "\u{E8B0}"  // SelectAll: a dashed box, like Chrome's inspect icon
        case "square.split.2x1": return "\u{E89A}"  // TwoPage
        // The Peek's.
        case "xmark": return "\u{E711}"  // Cancel
        case "arrow.up.left.and.arrow.down.right": return "\u{E740}"  // FullScreen
        case "arrow.left": return "\u{E72B}"  // Back
        case "arrow.right": return "\u{E72A}"  // Forward
        case "arrow.clockwise": return "\u{E72C}"  // Refresh
        // The Library's rail (Fluent has no filled versions of these).
        case "arrow.down.circle", "arrow.down.circle.fill": return "\u{E896}"  // Download
        case "archivebox", "archivebox.fill": return "\u{E7B8}"  // Archive
        case "square.on.square", "square.on.square.fill": return "\u{E8A9}"  // ViewAll
        default: return "\u{E721}"  // magnifyingglass
        }
    }

    /// The glyph for a row: its symbol, else a page for tabs and a grid for spaces.
    static func symbol(for s: Suggestion) -> String {
        if let symbol = s.symbol { return symbol }
        switch s.kind {
        case .switchToTab, .archived: return "tab"
        case .switchSpace: return "space"
        default: return s.url == nil ? "magnifyingglass" : "globe"
        }
    }
}

/// The command bar's request to the search engine's suggest endpoint (SearchSuggestions decides
/// what is kept and shown): the Mac's SearchSuggestLoader on FoundationNetworking.
enum WinSuggestLoader {
    /// No cookies: the request says nothing about who is typing beyond the text itself.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.httpAdditionalHeaders = ["Accept-Language": SearchSuggestions.acceptLanguage()]
        return URLSession(configuration: c)
    }()

    /// The answer's body, nil unless the engine answered 200.
    @Sendable static func load(_ url: URL) async -> Data? {
        await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
            session.dataTask(with: url) { data, response, _ in
                done.resume(returning: (response as? HTTPURLResponse)?.statusCode == 200 ? data : nil)
            }.resume()
        }
    }
}
