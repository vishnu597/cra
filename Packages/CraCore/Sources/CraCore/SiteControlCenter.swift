import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Arc 1.170's Site Control Center: the sliders button at the end of the toolbar and of the
/// sidebar's URL pill (SiteControlCenterView in ARC_SiteControlCenter). What it shows and what
/// its buttons do, for the Mac's popover (Sources/Cra/UI/SiteControlCenter.swift) and Windows'.
///
/// Arc's layout, top to bottom: four raised action buttons, "Extensions" with a 4-column grid
/// of tiles, "Settings" with three switch rows, a divider, and a footer with the connection
/// state and a More menu.
public enum SiteControlCenter {
    /// Geometry read from Arc's accessibility tree and captures of the open popover
    /// (26 Oct 2026), in points (DIPs on Windows).
    public enum Metrics {
        public static let width: CGFloat = 236
        public static let inset: CGFloat = 10
        /// An action button or an extension tile.
        public static let tile = CGSize(width: 48, height: 32)
        public static let gap: CGFloat = 8
        /// A section's title row, above its tiles or rows.
        public static let sectionHeader: CGFloat = 27
        public static let settingRow = CGSize(width: 208, height: 33)
        public static let settingRowGap: CGFloat = 10
        /// The connection pill and the More button.
        public static let footer: CGFloat = 32
    }

    /// The raised buttons along the top, in Arc's order.
    public enum Action: String, CaseIterable, Sendable {
        case share, copyURL, capture, captureFullPage

        public var help: String {
            switch self {
            case .share: "Share"
            case .copyURL: "Copy URL"
            case .capture: "Capture this page"
            case .captureFullPage: "Capture the full page"
            }
        }

        /// The Mac's SF Symbol.
        public var symbol: String {
            switch self {
            case .share: "square.and.arrow.up"
            case .copyURL: "link"
            case .capture: "camera"
            case .captureFullPage: "text.viewfinder"
            }
        }
    }

    /// The Settings section's switches, in Arc's order.
    public enum Setting: String, CaseIterable, Sendable {
        case developerMode, blockAdsAndTrackers, autoPictureInPicture
    }

    public struct SettingRow: Equatable, Sendable {
        public let setting: Setting
        public let title: String
        /// "On" / "Off"; Picture-in-Picture says "Allowed" / "Disabled", as Arc does.
        public let subtitle: String
        public let isOn: Bool
        /// The Mac's SF Symbol.
        public let symbol: String
    }

    /// The switches for the page at `url`, of those the platform has (Windows has none of the
    /// three features yet, so its popover leaves the section out).
    public static func settingRows(_ settings: AppSettings, url: String,
                                   available: Set<Setting> = Set(Setting.allCases)) -> [SettingRow] {
        Setting.allCases.filter(available.contains).map { s in
            switch s {
            case .developerMode:
                let on = settings.isDeveloperMode(url: url)
                return SettingRow(setting: s, title: "Developer Mode", subtitle: on ? "On" : "Off", isOn: on, symbol: "hammer.fill")
            case .blockAdsAndTrackers:
                let on = settings.blockAdsAndTrackers
                return SettingRow(setting: s, title: "Block Ads & Trackers", subtitle: on ? "On" : "Off", isOn: on, symbol: "shield.fill")
            case .autoPictureInPicture:
                let on = settings.autoPictureInPicture
                return SettingRow(setting: s, title: "Automatic Picture-In-Picture", subtitle: on ? "Allowed" : "Disabled", isOn: on,
                                  symbol: "gearshape.fill")
            }
        }
    }

    /// A row's click. Developer Mode is per site; the other two are app-wide.
    public static func toggle(_ setting: Setting, in settings: inout AppSettings, url: String) {
        switch setting {
        case .developerMode: settings.toggleDeveloperMode(url: url)
        case .blockAdsAndTrackers: settings.blockAdsAndTrackers.toggle()
        case .autoPictureInPicture: settings.autoPictureInPicture.toggle()
        }
    }

    /// The footer's "…" menu entries.
    public enum MoreItem: String, Sendable {
        case clearCache, clearCookies, manageExtensions, addExtension, siteSettings

        public var title: String {
            switch self {
            case .clearCache: "Clear Cache"
            case .clearCookies: "Clear Cookies"
            case .manageExtensions: "Manage Extensions"
            case .addExtension: "Add Extension"
            case .siteSettings: "All Site Settings"
            }
        }
    }

    /// Arc's More menu, in groups a separator divides. The extension entries only where Cra
    /// runs extensions.
    public static func moreMenu(extensions: Bool) -> [[MoreItem]] {
        [[.clearCache, .clearCookies]] + (extensions ? [[.manageExtensions, .addExtension]] : []) + [[.siteSettings]]
    }

    public static let addExtensionURL = "https://chromewebstore.google.com/category/extensions"
    public static let manageExtensionsURL = "chrome://extensions"

    /// "All Site Settings": Chromium's page for the site (scheme and host, as Arc opens it).
    /// nil for a page with no host (a blank tab, a file).
    public static func siteSettingsURL(for url: String) -> String? {
        guard let u = URL(string: url), let host = u.host, !host.isEmpty else { return nil }
        let origin = "\(u.scheme ?? "https")://\(host)"
        return "chrome://settings/content/siteDetails?site=" + (origin.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? origin)
    }

    /// The footer's connection pill: its label and its tooltip.
    public static func securityLabel(secure: Bool) -> (title: String, help: String) {
        secure ? ("Secure", "Your connection to this site is secure") : ("Not Secure", "Your connection to this site is not secure")
    }
}

/// Arc's "Clear Cookies and Refresh" and "Clear Cache and Refresh": the DevTools call that
/// clears this site's cookies, or the HTTP cache. The page reloads once it answers.
public enum SiteDataClearing {
    /// nil for a page with no scheme or host: there is nothing of a site's to clear.
    public static func request(url: String, cookies: Bool) -> (method: String, params: String)? {
        guard let u = URL(string: url), let host = u.host, !host.isEmpty, let scheme = u.scheme else { return nil }
        guard cookies else { return ("Network.clearBrowserCache", "{}") }
        let params = ["origin": "\(scheme)://\(host)\(u.port.map { ":\($0)" } ?? "")", "storageTypes": "cookies"]
        let json = (try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return ("Storage.clearDataForOrigin", json)
    }
}

/// Arc's captures: where the image goes and what its file is called.
public enum PageCapture {
    /// "Cra Capture 2026-11-04 at 14.05.09.png", the Mac's name for a saved capture.
    public static func fileName(at date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Cra Capture \(f.string(from: date)).png"
    }

    /// DevTools' Page.captureScreenshot parameters: the viewport, or the whole document, which
    /// Page.getLayoutMetrics measured (Chromium caps a capture at 16384 px tall).
    public static func screenshotParams(fullPageWidth width: Double? = nil, height: Double? = nil) -> String {
        guard let width, let height else { return #"{"format":"png","captureBeyondViewport":false}"# }
        return #"{"format":"png","captureBeyondViewport":true,"clip":{"x":0,"y":0,"width":\#(width),"height":\#(min(height, 16384)),"scale":1}}"#
    }

    /// The document's size from Page.getLayoutMetrics' answer (CSS pixels).
    public static func contentSize(layoutMetrics json: String) -> (width: Double, height: Double)? {
        guard let m = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let size = (m["cssContentSize"] ?? m["contentSize"]) as? [String: Any],
              let w = number(size["width"]), let h = number(size["height"]) else { return nil }
        return (w, h)
    }

    /// The PNG in Page.captureScreenshot's answer.
    public static func png(screenshot json: String) -> Data? {
        guard let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let b64 = o["data"] as? String, let png = Data(base64Encoded: b64), !png.isEmpty else { return nil }
        return png
    }

    private static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return (v as? NSNumber)?.doubleValue
    }
}
