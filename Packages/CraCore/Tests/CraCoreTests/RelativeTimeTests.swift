import CraCore
import Foundation
import Testing

/// RelativeDateTimeFormatter's English where Foundation lacks it (Windows, Linux).
struct RelativeTimeTests {
    private static let day: TimeInterval = 86400

    static let fullCases: [(TimeInterval, String)] = [
        (-54, "54 seconds ago"), (-1, "1 second ago"), (0, "0 seconds ago"), (-90, "1 minute ago"),
        (-7200, "2 hours ago"), (-day, "1 day ago"), (-3 * day, "3 days ago"), (-14 * day, "2 weeks ago"),
        (-60 * day, "2 months ago"), (-400 * day, "1 year ago"), (300, "in 5 minutes"),
    ]

    static let shortCases: [(TimeInterval, String)] = [
        (-30, "30 sec. ago"), (-7200, "2 hr. ago"), (-day, "1 day ago"), (-3 * day, "3 days ago"),
        (-14 * day, "2 wk. ago"), (-40 * day, "1 mo. ago"), (-400 * day, "1 yr. ago"), (300, "in 5 min."),
    ]

    @Test func full() {
        for (interval, text) in Self.fullCases {
            #expect(RelativeTime.english(interval, style: .full) == text, "\(interval)")
        }
    }

    @Test func short() {
        for (interval, text) in Self.shortCases {
            #expect(RelativeTime.english(interval, style: .short) == text, "\(interval)")
        }
    }
}
