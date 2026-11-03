import CraCore
import Foundation
import Observation
import WinUI

/// Favicons keyed by host (FaviconKey): the Mac's FaviconCache. Chromium hands over PNG bytes
/// (CraCEFWin.h's favicon_loaded); they are kept in memory and in the data folder's Favicons
/// folder under the Mac's file names, so the sidebar shows them on launch before any tab has
/// loaded (Arc: SidebarItemsFaviconCache).
@MainActor
@Observable
final class Favicons {
    static let shared = Favicons()

    /// Bumped when an icon arrives: whatever drew a key without its icon draws again.
    private(set) var revision = 0
    @ObservationIgnored private var icons: [String: Icon] = [:]
    /// Keys with no file on disk, so a miss doesn't read the disk on every redraw.
    @ObservationIgnored private var missing: Set<String> = []

    /// One icon and the bitmaps drawn from it.
    @MainActor
    private final class Icon {
        let pixels: Pixels
        /// A one-colour gray glyph (GitHub's octocat): true when dark, false when light.
        let glyphIsDark: Bool?
        var original: WriteableBitmap?
        /// The glyph in the sidebar's text colour, by whether the sidebar is dark.
        var tinted: [Bool: WriteableBitmap] = [:]

        init(pixels: Pixels, glyphIsDark: Bool?) {
            self.pixels = pixels
            self.glyphIsDark = glyphIsDark
        }
    }

    static let folder: URL = {
        let u = WinPaths.supportDir.appendingPathComponent("Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    func has(_ key: String?) -> Bool { icon(key) != nil }

    /// What to draw for `key` on a fill that is dark or light: the icon, or a one-colour glyph
    /// of the fill's own tone redrawn in white or black so it doesn't vanish (FaviconView).
    func bitmap(forKey key: String?, onDark dark: Bool) -> WriteableBitmap? {
        guard let icon = icon(key) else { return nil }
        if icon.glyphIsDark == dark {
            if let b = icon.tinted[dark] { return b }
            let ink: UInt8 = dark ? 255 : 0
            let b = icon.pixels.tinted(r: ink, g: ink, b: ink, opacity: dark ? 0.92 : 0.85).bitmap()
            icon.tinted[dark] = b
            return b
        }
        if icon.original == nil { icon.original = icon.pixels.bitmap() }
        return icon.original
    }

    /// `persist` false keeps the icon in memory only (incognito pages).
    func store(png: Data, forKey key: String, persist: Bool = true) {
        guard let icon = Self.makeIcon(png, key: key) else { return }
        icons[key] = icon
        missing.remove(key)
        revision += 1
        guard persist else { return }
        let file = Self.folder.appendingPathComponent(FaviconKey.fileName(key))
        DispatchQueue.global(qos: .utility).async { try? png.write(to: file, options: .atomic) }
    }

    private func icon(_ key: String?) -> Icon? {
        _ = revision
        guard let key else { return nil }
        if let icon = icons[key] { return icon }
        guard !missing.contains(key) else { return nil }
        let file = Self.folder.appendingPathComponent(FaviconKey.fileName(key))
        guard let png = try? Data(contentsOf: file), let icon = Self.makeIcon(png, key: key) else {
            missing.insert(key)
            return nil
        }
        icons[key] = icon
        return icon
    }

    private static func makeIcon(_ png: Data, key: String) -> Icon? {
        guard let pixels = Pixels.decode(png) else { return nil }
        // Custom icons (the Mac's "custom-…" keys) are drawn as picked.
        let tone = key.hasPrefix("custom-") ? nil : Pixels.decode(png, side: 32).flatMap { FaviconTone.glyphIsDark(rgba: $0.rgba) }
        return Icon(pixels: pixels, glyphIsDark: tone)
    }
}
