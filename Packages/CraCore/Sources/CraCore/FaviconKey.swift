import Foundation

/// What favicons are cached under. A site's key is the page's host, lowercased: the icon a
/// suggestion or a not-yet-loaded tab borrows from the last page seen there. A tab's own icon
/// goes under its icon URL's key as well, so tabs on one host keep their own icons (GitHub #211;
/// Arc caches one favicon per sidebar item, SidebarItemsFaviconCache).
public enum FaviconKey {
    public static func key(for urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    /// The key of the icon at `iconURL` on the page at `pageURL`: "<host>#<hash of the icon URL>".
    /// AWS consoles and localhost apps have one host and many icons.
    public static func key(for pageURL: String, iconURL: String) -> String? {
        key(for: pageURL).map { key(site: $0, iconURL: iconURL) }
    }

    /// The same for a site key already known (a tab's).
    public static func key(site: String, iconURL: String) -> String {
        guard !iconURL.isEmpty else { return site }
        // FNV-1a: stable across launches (the key names a file on disk), unlike Hasher.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in iconURL.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return site + "#" + String(hash, radix: 16)
    }

    /// The site key an icon key falls back to.
    public static func siteKey(of key: String) -> String {
        key.firstIndex(of: "#").map { String(key[..<$0]) } ?? key
    }

    /// A tab's key after it goes to `url`. On the same host it keeps its own icon until the new
    /// page's arrives (Chromium sends none when the icon is the same); elsewhere it shows the
    /// site's last icon meanwhile.
    public static func key(after current: String?, goingTo url: String) -> String? {
        guard let site = key(for: url) else { return current }
        if let current, siteKey(of: current) == site { return current }
        return site
    }

    /// The icon's file in the data folder's Favicons folder: the key with anything but
    /// letters, digits, dots and dashes as "_", and ".png".
    public static func fileName(_ key: String) -> String {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }.joined()
        return safe + ".png"
    }
}

/// One-color gray glyphs on a transparent background (GitHub's octocat, black or white
/// depending on the page's color scheme) vanish on a tile of their own tone, so the sidebar
/// draws them in its text colour instead.
public enum FaviconTone {
    /// For the icon's pixels as premultiplied RGBA (4 bytes a pixel, drawn at about 32 × 32):
    /// true when it is such a glyph and dark, false when light, nil for any other icon.
    public static func glyphIsDark(rgba buf: [UInt8]) -> Bool? {
        let pixels = buf.count / 4
        var opaque = 0, dark = 0, light = 0
        for i in stride(from: 0, to: pixels * 4, by: 4) where buf[i + 3] > 128 {
            let a = Double(buf[i + 3])
            let r = Double(buf[i]) / a, g = Double(buf[i + 1]) / a, b = Double(buf[i + 2]) / a
            opaque += 1
            guard max(r, g, b) - min(r, g, b) < 0.15 else { continue }
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if l < 0.3 { dark += 1 } else if l > 0.75 { light += 1 }
        }
        // Mostly see-through and almost every visible pixel the same gray.
        guard opaque > 20, opaque < pixels * 85 / 100 else { return nil }
        if Double(dark) / Double(opaque) > 0.92 { return true }
        if Double(light) / Double(opaque) > 0.92 { return false }
        return nil
    }
}
