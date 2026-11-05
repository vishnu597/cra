import Foundation

/// A window's place on screen as windows.json keeps it (WindowSession.frame): AppKit's
/// NSStringFromRect format, "{{x, y}, {width, height}}". The Mac writes points from the bottom
/// left of the main screen; Windows writes physical pixels from the top left of the primary
/// monitor. Each app reads only its own, as each has its own data folder.
public struct WindowFrame: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// nil for anything that isn't four numbers in that shape, or a size that isn't positive.
    public init?(string: String) {
        let numbers = string.split(whereSeparator: { "{}, ".contains($0) }).compactMap { Double($0) }
        guard numbers.count == 4, numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0 else { return nil }
        self.init(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// NSStringFromRect's spelling: whole numbers without a fraction.
    public var string: String {
        func n(_ v: Double) -> String { v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v) }
        return "{{\(n(x)), \(n(y))}, {\(n(width)), \(n(height))}}"
    }

    /// Arc's New Window: `step` right of and below this one (down on screen is +y on Windows),
    /// or `step` in from the work area's top left when that would leave it. The size stays,
    /// shrunk to fit the work area.
    public func cascaded(step: Double, within area: WindowFrame) -> WindowFrame {
        var f = WindowFrame(x: x + step, y: y + step, width: min(width, area.width), height: min(height, area.height))
        if f.x + f.width > area.x + area.width || f.y + f.height > area.y + area.height {
            f.x = area.x + step
            f.y = area.y + step
            f.width = min(f.width, area.width - step)
            f.height = min(f.height, area.height - step)
        }
        return f
    }

    /// Whether at least `margin` of the window's top strip shows inside one of `areas` (the
    /// monitors' work areas), so its title bar can be grabbed. A frame saved on a monitor that's
    /// gone fails, and the window opens where Windows puts it.
    public func isReachable(in areas: [WindowFrame], margin: Double = 48) -> Bool {
        areas.contains { a in
            let left = max(x, a.x), right = min(x + width, a.x + a.width)
            return right - left >= margin && y >= a.y - margin && y < a.y + a.height - margin / 2
        }
    }
}
