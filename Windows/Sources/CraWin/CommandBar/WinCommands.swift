import CraCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The commands the Windows command bar offers: the Mac's ids, names and triggers
/// (KeyBindingRegistry) for what the Windows app does so far, with its Ctrl shortcuts.
enum WinCommands {
    static let all: [CommandBarCommand] = [
        CommandBarCommand(id: "newTab", name: "New Tab…", triggers: ["new tab"], shortcut: "Ctrl+T"),
        CommandBarCommand(id: "reopenClosedTab", name: "Restore Last Closed Tab", triggers: ["reopen", "undo close", "restore"],
                          shortcut: "Ctrl+Shift+T"),
        CommandBarCommand(id: "closeTab", name: "Close Tab", triggers: ["close", "archive tab"], shortcut: "Ctrl+W"),
        CommandBarCommand(id: "reload", name: "Refresh the Page", triggers: ["refresh", "reload"], shortcut: "Ctrl+R"),
        CommandBarCommand(id: "hardReload", name: "Force Refresh the Page", shortcut: "Ctrl+Shift+R"),
        CommandBarCommand(id: "pinTab", name: "Pin/Unpin Tab", triggers: ["pin", "unpin"], shortcut: "Ctrl+D"),
    ]
}

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
