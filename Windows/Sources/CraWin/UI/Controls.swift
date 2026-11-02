import CraCore
import Foundation
import UWP
import WinUI

/// Small builders for the code-made XAML (there is no markup in the Windows shell).
@MainActor
enum UI {
    static func text(_ string: String, size: Double = 13, color: Brush? = nil, trimmed: Bool = true) -> TextBlock {
        let t = TextBlock()
        t.text = string
        t.fontSize = size
        if let color { t.foreground = color }
        if trimmed { t.textTrimming = .characterEllipsis }
        return t
    }

    /// A borderless button whose content is `content`, filled with `fill` (transparent by default).
    static func button(_ content: UIElement, fill: Brush? = nil, padding: Thickness = Thickness(left: 8, top: 5, right: 8, bottom: 5),
                       _ action: @escaping @MainActor () -> Void) -> Button {
        let b = Button()
        b.content = content
        b.background = fill ?? clear
        b.borderThickness = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        b.padding = padding
        b.cornerRadius = CornerRadius(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6)
        b.click.addHandler { _, _ in action() }
        return b
    }

    static func button(_ title: String, color: Brush? = nil, _ action: @escaping @MainActor () -> Void) -> Button {
        button(text(title, color: color, trimmed: false), action)
    }

    static func menuItem(_ title: String, _ action: @escaping @MainActor () -> Void) -> MenuFlyoutItem {
        let item = MenuFlyoutItem()
        item.text = title
        item.click.addHandler { _, _ in action() }
        return item
    }

    static func column(_ length: GridLength) -> ColumnDefinition {
        let c = ColumnDefinition()
        c.width = length
        return c
    }

    static func row(_ length: GridLength) -> RowDefinition {
        let r = RowDefinition()
        r.height = length
        return r
    }

    static let auto = GridLength(value: 0, gridUnitType: .auto)
    static let star = GridLength(value: 1, gridUnitType: .star)
    static func pixels(_ n: Double) -> GridLength { GridLength(value: n, gridUnitType: .pixel) }

    static func brush(_ hex: String, alpha: UInt8 = 255) -> SolidColorBrush {
        let c = HexColor.components(hex) ?? (r: 0.5, g: 0.5, b: 0.5)
        return brush(UInt8(c.r * 255), UInt8(c.g * 255), UInt8(c.b * 255), alpha: alpha)
    }

    static func brush(_ r: UInt8, _ g: UInt8, _ b: UInt8, alpha: UInt8 = 255) -> SolidColorBrush {
        SolidColorBrush(UWP.Color(a: alpha, r: r, g: g, b: b))
    }

    static let clear = brush(0, 0, 0, alpha: 0)
}

/// The sidebar's colours for a space, from its theme: its first colour as the fill, and text
/// and highlights that read on it.
@MainActor
struct SidebarPalette {
    let fill: Brush
    let text: Brush
    let secondaryText: Brush
    /// The open tab's row and a hovered row.
    let selected: Brush
    let tile: Brush

    init(_ theme: SpaceTheme) {
        fill = UI.brush(theme.colors.first ?? "#1C242B")
        if theme.isDark {
            text = UI.brush(255, 255, 255)
            secondaryText = UI.brush(255, 255, 255, alpha: 150)
            selected = UI.brush(255, 255, 255, alpha: 40)
            tile = UI.brush(255, 255, 255, alpha: 22)
        } else {
            text = UI.brush(20, 20, 24)
            secondaryText = UI.brush(20, 20, 24, alpha: 150)
            selected = UI.brush(0, 0, 0, alpha: 26)
            tile = UI.brush(0, 0, 0, alpha: 14)
        }
    }
}
