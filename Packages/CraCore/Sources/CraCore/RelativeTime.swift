import Foundation

/// What RelativeDateTimeFormatter writes in English ("54 seconds ago", "in 5 min."), for where
/// Foundation has no such formatter (Windows, Linux). The largest whole unit, as it counts them.
public enum RelativeTime {
    public enum Style {
        /// "3 days ago", "1 hour ago".
        case full
        /// "3 days ago", "1 hr. ago".
        case short
    }

    /// `interval` from now: negative is in the past ("ago"), positive in the future ("in").
    public static func english(_ interval: TimeInterval, style: Style) -> String {
        let units: [(seconds: TimeInterval, full: String, short: String?)] = [
            (365 * 86400, "year", "yr."), (30 * 86400, "month", "mo."), (7 * 86400, "week", "wk."),
            (86400, "day", nil), (3600, "hour", "hr."), (60, "minute", "min."), (1, "second", "sec."),
        ]
        let a = abs(interval)
        let unit = units.first { a >= $0.seconds } ?? units[units.count - 1]
        let n = Int(a / unit.seconds)
        let name: String
        switch style {
        case .short where unit.short != nil: name = unit.short!
        default: name = n == 1 ? unit.full : unit.full + "s"
        }
        let text = "\(n) \(name)"
        return interval > 0 ? "in \(text)" : "\(text) ago"
    }
}
