import Foundation

/// What favicons are cached under: the page's host, lowercased (Arc: SidebarItemsFaviconCache).
public enum FaviconKey {
    public static func key(for urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host, !host.isEmpty else { return nil }
        return host.lowercased()
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
