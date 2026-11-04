import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Arc's toast (Toasts.ShinyToastView): every short confirmation, "Copied Current URL",
/// "Screenshot Copied to Clipboard" and the rest. Arc 1.171, measured 2 Nov 2026 at 1x: a 42 pt
/// pill 8 pt below the top of the page and 9 pt in from its right edge, 14 pt medium text with
/// 12 pt either side, a fill from the space's colours with a 1 pt darker outline, up 4.85 s
/// after the last message. Drawn by the Mac's ShinyToast and Windows' ToastView.
public enum ToastStyle {
    public static let height: CGFloat = 42
    public static let topInset: CGFloat = 8
    public static let trailingInset: CGFloat = 9
    public static let padding: CGFloat = 12
    public static let cornerRadius: CGFloat = 10
    public static let fontSize: CGFloat = 14
    /// How long the toast stays up after the last message.
    public static let visibleFor: TimeInterval = 4.85
    /// A button after the text ("Save"): a capsule of 13 pt semibold text.
    public static let buttonFontSize: CGFloat = 13
    public static let buttonHeight: CGFloat = 26
    public static let buttonPadding: CGFloat = 10
    public static let buttonGap: CGFloat = 10

    /// A vertical gradient, its outline and the text on it.
    public struct Colors: Equatable, Sendable {
        public var top, bottom, outline, text: RGB
    }

    /// The fill takes the hue of the space's colours' mean: deep and saturated on a dark space,
    /// pale on a light one. `theme` as it shows (light or dark already resolved).
    public static func colors(_ theme: SpaceTheme) -> Colors {
        let comps = theme.colors.compactMap(HexColor.components)
        let n = Double(max(comps.count, 1))
        let mean = SpaceTheme.hsb(comps.reduce(0) { $0 + $1.r } / n, comps.reduce(0) { $0 + $1.g } / n, comps.reduce(0) { $0 + $1.b } / n)
        let sat = comps.isEmpty ? 0 : mean.s
        func color(_ s: Double, _ v: Double) -> RGB {
            let c = SpaceTheme.rgb(h: mean.h, s: s, v: v)
            return RGB(c.0, c.1, c.2)
        }
        if theme.isDark {
            let s = min(0.76, sat * 1.9)
            return Colors(top: color(s, 0.40), bottom: color(s, 0.31), outline: color(s, 0.24), text: .white)
        }
        let s = min(0.19, sat * 0.3)
        return Colors(top: color(s, 0.89), bottom: color(min(0.25, s * 1.3), 0.85), outline: color(s, 0.61), text: .black)
    }
}
