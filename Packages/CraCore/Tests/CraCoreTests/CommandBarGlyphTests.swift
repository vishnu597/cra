import CraCore
import Testing

/// The command bar's leading glyph against what Arc 1.171 showed (GitHub #50).
struct CommandBarGlyphTests {
    private static let cached: Set<String> = ["github.com", "youtube.com", "x.com"]
    private static let recentTab: (String?, String?) = ("github.com", nil)

    private func glyph(editingURL: Bool = false, untouched: Bool = false, site: Bool = false, page: String? = nil,
                       row: (String?, String?)?) -> CommandBarGlyph {
        CommandBarGlyph.resolve(editingURL: editingURL, untouched: untouched, scoped: site, pageFaviconKey: page,
                                row: row.map { (faviconKey: $0.0, symbol: $0.1) }, hasFavicon: Self.cached.contains)
    }

    @Test func nothingTyped() {
        // ⌘L shows the page's favicon (a globe without one), ⌘T a magnifier.
        #expect(glyph(editingURL: true, untouched: true, page: "github.com", row: Self.recentTab) == .favicon("github.com"))
        #expect(glyph(editingURL: true, untouched: true, page: "example.com", row: Self.recentTab) == .symbol("globe"))
        #expect(glyph(untouched: true, row: Self.recentTab) == .symbol("magnifyingglass"))
    }

    @Test(arguments: [false, true])
    func typedShowsTheHighlightedRow(editingURL: Bool) {
        #expect(glyph(editingURL: editingURL, row: (nil, "magnifyingglass")) == .symbol("magnifyingglass"))
        #expect(glyph(editingURL: editingURL, row: ("example.org", "globe")) == .symbol("globe"))
        #expect(glyph(editingURL: editingURL, row: ("youtube.com", "globe")) == .favicon("youtube.com"))
        #expect(glyph(editingURL: editingURL, row: ("x.com", nil)) == .favicon("x.com"))
        #expect(glyph(editingURL: editingURL, row: ("jira.example", nil)) == .symbol("globe"))
    }

    @Test func scopedOrEmpty() {
        #expect(glyph(site: true, row: ("youtube.com", nil)) == .symbol("magnifyingglass"))
        #expect(glyph(row: nil) == .symbol("magnifyingglass"))
    }
}
