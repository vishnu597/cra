import Foundation

/// The command bar's request to the search engine's suggest endpoint (SearchSuggestions, in
/// CraCore, decides what is kept and shown).
enum SearchSuggestLoader {
    /// No cookies: the request says nothing about who is typing beyond the text itself.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.httpAdditionalHeaders = ["Accept-Language": SearchSuggestions.acceptLanguage()]
        return URLSession(configuration: c)
    }()

    /// The answer's body, nil unless the engine answered 200.
    @Sendable static func load(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
