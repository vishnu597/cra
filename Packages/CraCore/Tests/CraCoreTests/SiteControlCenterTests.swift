import CraCore
import Foundation
import Testing

/// The Site Control Center's contents and actions, shared by the Mac and Windows.
struct SiteControlCenterTests {
    @Test func actionsInArcsOrder() {
        #expect(SiteControlCenter.Action.allCases == [.share, .copyURL, .capture, .captureFullPage])
        #expect(SiteControlCenter.Action.allCases.map(\.help) == ["Share", "Copy URL", "Capture this page", "Capture the full page"])
        #expect(SiteControlCenter.Action.allCases.map(\.symbol) == ["square.and.arrow.up", "link", "camera", "text.viewfinder"])
    }

    @Test func settingRowsFollowTheSettings() {
        var s = AppSettings()
        s.blockAdsAndTrackers = true
        s.autoPictureInPicture = false
        let rows = SiteControlCenter.settingRows(s, url: "https://www.github.com/x")
        #expect(rows.map(\.title) == ["Developer Mode", "Block Ads & Trackers", "Automatic Picture-In-Picture"])
        #expect(rows.map(\.subtitle) == ["Off", "On", "Disabled"])
        #expect(rows.map(\.isOn) == [false, true, false])
        #expect(rows.map(\.symbol) == ["hammer.fill", "shield.fill", "gearshape.fill"])
    }

    @Test func togglingFlipsTheRow() {
        var s = AppSettings()
        let url = "https://github.com/"
        for setting in SiteControlCenter.Setting.allCases {
            let before = SiteControlCenter.settingRows(s, url: url, available: [setting])[0]
            SiteControlCenter.toggle(setting, in: &s, url: url)
            let after = SiteControlCenter.settingRows(s, url: url, available: [setting])[0]
            #expect(after.isOn == !before.isOn)
            #expect(after.subtitle != before.subtitle)
        }
        // Developer Mode is per site.
        #expect(s.isDeveloperMode(url: "https://www.github.com/other"))
        #expect(!s.isDeveloperMode(url: "https://example.com/"))
        #expect(SiteControlCenter.settingRows(s, url: url, available: [.autoPictureInPicture]).map(\.subtitle) == ["Disabled"])
    }

    /// A platform without the features shows no Settings section.
    @Test func onlyAvailableSettings() {
        #expect(SiteControlCenter.settingRows(AppSettings(), url: "https://a.com", available: []).isEmpty)
        #expect(SiteControlCenter.settingRows(AppSettings(), url: "https://a.com", available: [.autoPictureInPicture, .developerMode])
            .map(\.setting) == [.developerMode, .autoPictureInPicture])
    }

    @Test func moreMenu() {
        #expect(SiteControlCenter.moreMenu(extensions: true) == [[.clearCache, .clearCookies], [.manageExtensions, .addExtension], [.siteSettings]])
        #expect(SiteControlCenter.moreMenu(extensions: false) == [[.clearCache, .clearCookies], [.siteSettings]])
        #expect([SiteControlCenter.MoreItem.clearCache, .clearCookies, .manageExtensions, .addExtension, .siteSettings].map(\.title)
            == ["Clear Cache", "Clear Cookies", "Manage Extensions", "Add Extension", "All Site Settings"])
    }

    @Test func siteSettingsURL() {
        #expect(SiteControlCenter.siteSettingsURL(for: "https://mail.google.com/mail/u/0/")
            == "chrome://settings/content/siteDetails?site=https%3A%2F%2Fmail%2Egoogle%2Ecom")
        #expect(SiteControlCenter.siteSettingsURL(for: "http://localhost:3000/a") == "chrome://settings/content/siteDetails?site=http%3A%2F%2Flocalhost")
        #expect(SiteControlCenter.siteSettingsURL(for: "") == nil)
        #expect(SiteControlCenter.siteSettingsURL(for: "about:blank") == nil)
    }

    @Test func securityLabel() {
        #expect(SiteControlCenter.securityLabel(secure: true) == ("Secure", "Your connection to this site is secure"))
        #expect(SiteControlCenter.securityLabel(secure: false) == ("Not Secure", "Your connection to this site is not secure"))
    }

    @Test func clearingSiteData() {
        let cookies = SiteDataClearing.request(url: "https://app.example.com:8443/x?y", cookies: true)
        #expect(cookies?.method == "Storage.clearDataForOrigin")
        #expect(cookies?.params == #"{"origin":"https:\/\/app.example.com:8443","storageTypes":"cookies"}"#
            || cookies?.params == #"{"origin":"https://app.example.com:8443","storageTypes":"cookies"}"#)
        let cache = SiteDataClearing.request(url: "https://example.com/", cookies: false)
        #expect(cache?.method == "Network.clearBrowserCache")
        #expect(cache?.params == "{}")
        #expect(SiteDataClearing.request(url: "about:blank", cookies: true) == nil)
        #expect(SiteDataClearing.request(url: "", cookies: false) == nil)
    }

    @Test func captureFileName() {
        let date = Date(timeIntervalSince1970: 1_793_801_109)  // 2026-11-04 14:05:09 UTC
        #expect(PageCapture.fileName(at: date, timeZone: TimeZone(identifier: "UTC")!) == "Cra Capture 2026-11-04 at 14.05.09.png")
    }

    @Test func screenshotParams() {
        #expect(PageCapture.screenshotParams() == #"{"format":"png","captureBeyondViewport":false}"#)
        #expect(PageCapture.screenshotParams(fullPageWidth: 1200, height: 3000)
            == #"{"format":"png","captureBeyondViewport":true,"clip":{"x":0,"y":0,"width":1200.0,"height":3000.0,"scale":1}}"#)
        #expect(PageCapture.screenshotParams(fullPageWidth: 800, height: 50000).contains(#""height":16384.0"#))
    }

    @Test func layoutMetrics() {
        let css = PageCapture.contentSize(layoutMetrics: #"{"cssContentSize":{"x":0,"y":0,"width":1280,"height":4321.5},"contentSize":{"width":2560,"height":8643}}"#)
        #expect(css?.width == 1280)
        #expect(css?.height == 4321.5)
        let old = PageCapture.contentSize(layoutMetrics: #"{"contentSize":{"width":640.5,"height":900}}"#)
        #expect(old?.width == 640.5)
        #expect(old?.height == 900)
        #expect(PageCapture.contentSize(layoutMetrics: "{}") == nil)
        #expect(PageCapture.contentSize(layoutMetrics: "not json") == nil)
    }

    @Test func screenshotPNG() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        #expect(PageCapture.png(screenshot: #"{"data":"\#(bytes.base64EncodedString())"}"#) == bytes)
        #expect(PageCapture.png(screenshot: #"{"data":""}"#) == nil)
        #expect(PageCapture.png(screenshot: #"{"other":1}"#) == nil)
        #expect(PageCapture.png(screenshot: "") == nil)
    }

    /// The Mac popover's arithmetic (SiteControlCenterView.build).
    @Test func heights() {
        typealias M = SiteControlCenter.Metrics
        #expect(M.height(extensions: nil, settingRows: 0) == 107)
        // Three extensions and "+" fill one row of the grid; four need a second.
        #expect(M.extensionsHeight(extensions: 3) == 59)
        #expect(M.extensionsHeight(extensions: 4) == 99)
        #expect(M.extensionsHeight(extensions: 0) == 59)
        #expect(M.settingsHeight(rows: 3) == 146)
        #expect(M.settingsHeight(rows: 0) == 0)
        #expect(M.height(extensions: 3, settingRows: 3) == 340)
        // 107, the one-row section (60) and the space after it (13).
        #expect(M.height(extensions: nil, settingRows: 1) == 180)
    }

    @Test func metrics() {
        #expect(SiteControlCenter.Metrics.width == 236)
        // Four tiles and three gaps fill the column inside its insets.
        let row = 4 * SiteControlCenter.Metrics.tile.width + 3 * SiteControlCenter.Metrics.gap
        #expect(row + 2 * SiteControlCenter.Metrics.inset == SiteControlCenter.Metrics.width)
        #expect(SiteControlCenter.Metrics.settingRow.width < row)
    }
}
