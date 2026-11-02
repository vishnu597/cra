import CraCore
import Foundation
import Testing

/// RelativeDateTimeFormatter's English where Foundation lacks it (Windows, Linux).
struct RelativeTimeTests {
    @Test(arguments: [
        (-54.0, "54 seconds ago"), (-1, "1 second ago"), (0, "0 seconds ago"), (-90, "1 minute ago"),
        (-2 * 3600, "2 hours ago"), (-86400, "1 day ago"), (-3 * 86400, "3 days ago"), (-14 * 86400, "2 weeks ago"),
        (-60 * 86400, "2 months ago"), (-400 * 86400, "1 year ago"), (300, "in 5 minutes"),
    ])
    func full(interval: Double, text: String) {
        #expect(RelativeTime.english(interval, style: .full) == text)
    }

    @Test(arguments: [
        (-30.0, "30 sec. ago"), (-2 * 3600, "2 hr. ago"), (-86400, "1 day ago"), (-3 * 86400, "3 days ago"),
        (-14 * 86400, "2 wk. ago"), (-40 * 86400, "1 mo. ago"), (-400 * 86400, "1 yr. ago"), (300, "in 5 min."),
    ])
    func short(interval: Double, text: String) {
        #expect(RelativeTime.english(interval, style: .short) == text)
    }
}
