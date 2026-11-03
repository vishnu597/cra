import Foundation

/// The search engine's own suggestions for what is typed. Arc takes them from Chromium's
/// omnibox ("Chromium: Search Suggestion" / "Navigate Suggest"); CEF has no omnibox, so Cra
/// asks the engine's suggest endpoint itself. They fill the command bar up to its five rows.
/// The request itself is the app's (`Loader`): CraCore holds what is kept and what is shown.
@MainActor
public final class SearchSuggestions {
    public struct Item: Equatable {
        public let text: String
        /// Set for a site suggestion (Google's NAVIGATION type), nil for a search.
        public let url: String?

        public init(text: String, url: String?) {
            self.text = text
            self.url = url
        }
    }

    /// Fetches a suggest URL: the body of a 200 answer, nil for anything else.
    public typealias Loader = @Sendable (URL) async -> Data?

    private var cache: [String: [Item]] = [:]
    /// The newest answer, kept on screen while the query's own answer loads (Chrome's omnibox
    /// does the same), so rows don't empty and refill on every keystroke.
    private var last: (query: String, items: [Item])?
    /// The query whose answer is loading.
    private var pending: String?
    private var task: Task<Void, Never>?
    private let load: Loader

    public init(load: @escaping Loader) { self.load = load }

    /// What the request's Accept-Language says: the user's languages, best first.
    public nonisolated static func acceptLanguage(_ languages: [String] = Locale.preferredLanguages) -> String {
        languages.prefix(4).enumerated().map { i, l in i == 0 ? l : "\(l);q=\(String(format: "%.1f", 1 - Double(i) * 0.2))" }
            .joined(separator: ",")
    }

    public func items(for query: String, engine: ChromiumSearchEngine) -> [Item] {
        let q = query.lowercased()
        if let hit = cache["\(engine.suggestURL)|\(q)"] { return hit }
        guard let last, pending == q else { return [] }
        // What still starts the typed text first; the rest only holds the bar's height, since
        // the engine often corrects the spelling ("ramayyana mov" → "ramayana movie").
        let rest = last.items.filter { $0.text.lowercased() != q }
        let narrowed = rest.filter { $0.url == nil && $0.text.lowercased().hasPrefix(q) }
        return narrowed + rest.filter { !narrowed.contains($0) }
    }

    public func fetch(_ query: String, engine: ChromiumSearchEngine, done: @escaping @MainActor () -> Void) {
        task?.cancel()
        pending = nil
        let q = query.lowercased()
        let key = "\(engine.suggestURL)|\(q)"
        guard cache[key] == nil, let url = engine.suggestURL(query) else { return }
        pending = q
        task = Task { [load, weak self] in
            let data = await load(url)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            guard let data else {
                // No answer: stop holding the previous one on screen.
                done()
                return
            }
            let items = Self.parse(data)
            self.cache[key] = items
            self.last = (q, items)
            done()
        }
    }

    /// The command bar opened or closed.
    public func reset() {
        task?.cancel()
        task = nil
        pending = nil
        cache = [:]
        last = nil
    }

    /// OpenSearch suggestions: `["query", ["one", "two", …], …]`. Google's chrome client adds
    /// a fifth element whose "google:suggesttype" marks each entry QUERY, NAVIGATION, …
    public nonisolated static func parse(_ data: Data) -> [Item] {
        let json = (try? JSONSerialization.jsonObject(with: data))
            ?? String(data: data, encoding: .isoLatin1).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        guard let a = json as? [Any], a.count > 1, let texts = a[1] as? [String] else { return [] }
        let types = (a.count > 4 ? a[4] as? [String: Any] : nil)?["google:suggesttype"] as? [String] ?? []
        return texts.enumerated().compactMap { i, text in
            switch i < types.count ? types[i] : "QUERY" {
            case "NAVIGATION": return Item(text: SuggestionEngine.humanURL(text), url: text)
            case "CALCULATOR": return nil
            default: return Item(text: text, url: nil)
            }
        }
    }
}
