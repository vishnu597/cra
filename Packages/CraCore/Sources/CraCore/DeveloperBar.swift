import Foundation

/// Björn Ottosson's OKLab, for colours that keep the same perceived lightness across hues.
public enum OKLab {
    public static func from(r: Double, g: Double, b: Double) -> (L: Double, a: Double, b: Double) {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (lr, lg, lb) = (lin(r), lin(g), lin(b))
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// Linear-light sRGB before clamping, so callers can tell whether it is in gamut.
    public static func toLinear(L: Double, a: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    public static func toRGB(L: Double, a: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        func enc(_ c: Double) -> Double {
            let x = max(0, min(1, c))
            return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        let v = toLinear(L: L, a: a, b: b)
        return (enc(v.r), enc(v.g), enc(v.b))
    }

    /// The largest chroma at this lightness and hue that sRGB can show.
    public static func maxChroma(L: Double, hue: Double) -> Double {
        var lo = 0.0, hi = 0.4
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            let v = toLinear(L: L, a: mid * cos(hue), b: mid * sin(hue))
            if [v.r, v.g, v.b].allSatisfy({ $0 >= 0 && $0 <= 1 }) { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// The colour of `hex`'s OKLab hue at lightness `L`, as saturated as sRGB allows there
    /// (`chromaScale` of that). Greys stay grey: below 0.03 of chroma the result fades to none.
    public static func edge(of hex: String, L: Double, chromaScale: Double = 1) -> RGB {
        let c = HexColor.components(hex) ?? (0.5, 0.5, 0.5)
        let lab = from(r: c.r, g: c.g, b: c.b)
        let chroma = (lab.a * lab.a + lab.b * lab.b).squareRoot()
        let hue = atan2(lab.b, lab.a)
        let target = maxChroma(L: L, hue: hue) * chromaScale * min(1, chroma / 0.03)
        let rgb = toRGB(L: L, a: target * cos(hue), b: target * sin(hue))
        return RGB(rgb.r, rgb.g, rgb.b)
    }
}

/// Arc's Developer Mode bar (GitHub #42, #88): its colours come from the space's, whatever the
/// page's theme-color. PaneToolbarView draws it on the Mac, DeveloperBarView on Windows.
extension SpaceTheme {
    /// The colour the developer bar is built from: the accent, else the first gradient stop.
    private var developerSource: String { accent ?? colors.first ?? "#808080" }

    /// The bar: Arc's semantic "focus" colour (dark) over black, opaque. Arc 1.170, JYSK, 1 Nov
    /// 2026: focus (0.294, 0.329, 1.021) at α 0.8075 → sRGB 61/67/210, the bar measured 61/67/210
    /// after undoing the display's P3. Focus sits a little darker than hover at the sRGB gamut edge
    /// in the theme's hue; fitted on JYSK as OKLab L 0.552 at full chroma. Arc's palette hue drifts
    /// ~5° from its base colour's, so JYSK lands at 44/72/206 (one space measured so far).
    public var developerBar: RGB {
        let edge = OKLab.edge(of: developerSource, L: 0.552)
        let k = 0.8075
        return RGB(edge.r * k, edge.g * k, edge.b * k)
    }

    /// Arc's foregroundSecondary (JYSK 131/137/255, OKLab L 0.68): the bar's dividers at 45 %,
    /// its selected text at 60 %.
    public var developerSecondary: RGB { OKLab.edge(of: developerSource, L: 0.68) }

    /// The bar's ink: near white (Arc's foregroundPrimary, JYSK 236/237/254), white with 7 % of
    /// the bar in it.
    public var developerInk: RGB { RGB.white.mixed(with: developerBar, 0.07) }
}

/// Arc's developer-bar stripes (GitHub #42), measured on Arc 1.170 at 2x: white 2 % bands at 45°
/// running down to the right, 21 pt wide along the bar every 45 pt, the first band starting
/// 14.5 pt from the bar's left edge at its top.
public enum DeveloperStripes {
    public static let pitch = 45.0, band = 21.0, phase = 14.5
    public static let whiteAlpha = 0.02

    /// Each band's corners, y down: top left, top right, bottom right, bottom left, for a bar of
    /// this size. The first starts far enough left (a band leans by the bar's height) that none
    /// that crosses the bar is left out.
    public static func bands(width: Double, height: Double) -> [[(x: Double, y: Double)]] {
        guard width > 0, height > 0 else { return [] }
        var out: [[(x: Double, y: Double)]] = []
        var x = phase - ((phase + height) / pitch).rounded(.down) * pitch - pitch
        while x < width {
            out.append([(x, 0), (x + band, 0), (x + band + height, height), (x + height, height)])
            x += pitch
        }
        return out
    }
}

/// Arc's ring round the open tab of a site in Developer Mode (TabHighlightView,
/// TabHighlightState.developerTab, GitHub #139): yellow under black dashes at 80 %, 2 pt wide,
/// a radius of 11, and dashes cut to the edge's length.
public enum DeveloperTabRing {
    public static let radius = 11.0, lineWidth = 2.0, dashAlpha = 0.8

    /// The corner radius for a ring of this size (its path, inset 1 pt from the row).
    public static func cornerRadius(width: Double, height: Double) -> Double { min(radius, width / 2, height / 2) }

    /// Each dash's length, and each gap's: 1/60, 1/80 or 1/100 of the path's length by the
    /// ring's width (under 210, under 346, wider).
    public static func dash(width: Double, height: Double) -> Double {
        guard width > 0, height > 0 else { return 0 }
        let r = cornerRadius(width: width, height: height)
        let edge = 2 * width + 2 * height - 8 * r + 2 * .pi * r
        return edge / (width < 210 ? 60 : width < 346 ? 80 : 100)
    }
}
