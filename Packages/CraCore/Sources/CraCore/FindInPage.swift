/// Find in page's "2/7" (FindBarView on the Mac, FindBar on Windows).
public enum FindInPage {
    /// What the bar shows after the field: the active match of all of them, "0/0" when the page
    /// has none, nothing before the page answers or with nothing typed.
    public static func countLabel(query: String, matches: Int?, active: Int) -> String? {
        guard let matches, !query.isEmpty else { return nil }
        return "\(matches == 0 ? 0 : active)/\(matches)"
    }
}
