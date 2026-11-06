#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Arc's Little Arc, Cra's Little Window: its size, where it opens, its strip's measurements and
/// colours. LittleWindowController draws it on the Mac, LittleWindow on Windows.
///
/// Measured from Arc 1.168's Little Arc on 24 Oct 2026 at 2x (docs/arc-reverse-engineering.md,
/// "Little Arc"): a 46 pt navy strip, one full-width search pill, and a split
/// "Open in <Space> ⌘O | ⌄" button; the page fills the rest. Arc draws it in the default profile's
/// dark palette whatever the focused space's theme is.
public enum LittleWindowLayout {
    public static let defaultSize = CGSize(width: 1400, height: 900)
    /// The old default, which every resize used to save (placement and the open animation
    /// included), so a stored copy of it was never the user's choice.
    public static let legacyDefaultSize = CGSize(width: 1000, height: 700)
    public static let minSize = CGSize(width: 480, height: 360)
    /// Each Little Window already open moves a new one this far right and down.
    public static let cascadeStep: CGFloat = 24
    /// A new window keeps at least this much of the screen clear around it, in all.
    public static let screenMargin: CGFloat = 40

    // The strip.
    public static let barHeight: CGFloat = 46
    /// The pill and the button: y 8…38.
    public static let controlHeight: CGFloat = 30
    public static let controlTop: CGFloat = 8
    public static let pillGap: CGFloat = 10
    public static let rightMargin: CGFloat = 7
    public static let chevronWidth: CGFloat = 29
    public static let pillCornerRadius: CGFloat = 8
    public static let buttonCornerRadius: CGFloat = 7
    /// The pill's icon buttons (copy link, extensions): 26 pt squares, 2 pt in from its end.
    public static let iconSize: CGFloat = 26
    public static let commandBarWidth: CGFloat = 500

    /// The size a new Little Window opens at: the one the user last dragged one to
    /// (`prefs.littleWindowSize`), no smaller than `minSize`; Arc's default without one.
    public static func size(saved: String?) -> CGSize {
        guard let s = saved.flatMap(parseSize), s != legacyDefaultSize, s.width > 0, s.height > 0 else { return defaultSize }
        return CGSize(width: max(minSize.width, s.width), height: max(minSize.height, s.height))
    }

    /// AppKit's NSStringFromSize format, "{1400, 900}", which `prefs.littleWindowSize` holds.
    public static func sizeString(_ size: CGSize) -> String {
        func number(_ v: CGFloat) -> String {
            let d = Double(v)
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        }
        return "{\(number(size.width)), \(number(size.height))}"
    }

    /// The other way (NSSizeFromString's "{w, h}"); nil for anything else.
    public static func parseSize(_ string: String) -> CGSize? {
        let inner = string.trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("{"), inner.hasSuffix("}") else { return nil }
        let parts = inner.dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w.isFinite, h.isFinite else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Where a new Little Window goes, y down (Windows' screen coordinates): no bigger than the
    /// work area allows, centred on it, `index` cascade steps right and down (one per Little
    /// Window already open), and kept on it.
    public static func frame(size: CGSize, in area: CGRect, index: Int) -> CGRect {
        let w = max(0, min(size.width, area.width - screenMargin))
        let h = max(0, min(size.height, area.height - screenMargin))
        let step = CGFloat(index) * cascadeStep
        var x = area.midX - w / 2 + step
        var y = area.midY - h / 2 + step
        x = min(max(area.minX, x), area.maxX - w)
        y = min(max(area.minY, y), area.maxY - h)
        return CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
    }

    /// The "Open in <Space>" name's colour: the space's light foreground (Arc:
    /// semanticColorPalette.dark.foregroundPrimary; Victor → #FCEDBC), its colour 72 % of the
    /// way to white.
    public static func spaceNameColor(_ theme: SpaceTheme) -> RGB {
        let c = HexColor.components(theme.accent ?? theme.colors.first ?? "#FFFFFF") ?? (1, 1, 1)
        return RGB(c.r, c.g, c.b).mixed(with: .white, 0.72)
    }

    /// Arc's Little Arc palette (sRGB bytes).
    public enum Palette {
        public static let bar: (UInt8, UInt8, UInt8) = (12, 9, 28)
        public static let pill: (UInt8, UInt8, UInt8) = (37, 34, 52)
        public static let pillHover: (UInt8, UInt8, UInt8) = (45, 46, 62)
        public static let iconHover: (UInt8, UInt8, UInt8) = (65, 57, 70)
        public static let icon: (UInt8, UInt8, UInt8) = (110, 111, 128)
        public static let iconHot: (UInt8, UInt8, UInt8) = (170, 168, 180)
        public static let text: (UInt8, UInt8, UInt8) = (163, 161, 169)
        public static let label: (UInt8, UInt8, UInt8) = (130, 131, 146)
        public static let button: (UInt8, UInt8, UInt8) = (5, 6, 37)
        public static let buttonBorder: (UInt8, UInt8, UInt8) = (29, 30, 55)
        public static let buttonHover: (UInt8, UInt8, UInt8) = (22, 23, 52)
        public static let badge: (UInt8, UInt8, UInt8) = (23, 24, 50)
        public static let badgeText: (UInt8, UInt8, UInt8) = (139, 140, 153)
    }
}

/// Which space and profile a Little Window's page goes with (LittleWindowController on the Mac).
extension SidebarStore {
    /// The space "Open in" names: the one a link asked for while it still exists, else the
    /// focused space of the normal window used last (Arc 1.171: it follows that window; #92).
    public func littleWindowTarget(requested: UUID?) -> UUID {
        if let requested, space(requested) != nil { return requested }
        return focusedSpaceID(window: lastNormalWindowID)
    }

    /// Where "Open in" puts the page: `wanted`, unless it is gone or a private window's space,
    /// then the focused space.
    public func littleWindowDestination(_ wanted: UUID) -> UUID {
        space(wanted) != nil && !isIncognito(space: wanted) ? wanted : focusedSpaceID
    }

    /// The profile a new Little Window's page loads in: its target space's (nil, Default, for a
    /// private window's space). Arc keeps it whichever space "Open in" names later (#172).
    public func littleWindowProfile(forSpace id: UUID) -> UUID? {
        isIncognito(space: id) ? nil : profile(space(id)?.profileID)?.id
    }
}
