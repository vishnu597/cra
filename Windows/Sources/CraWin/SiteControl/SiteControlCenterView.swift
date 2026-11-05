import CraCore
import Foundation
import UWP
import WinUI

/// Arc's Site Control Center (the Mac's SiteControlCenterView), in a window of its own under
/// the sliders button at the end of the address pill: the four action buttons, the Settings
/// switches Windows has (none yet: Developer Mode, ad blocking and Picture-in-Picture come
/// later), a divider, and the footer with the connection state and the More menu. Extensions
/// join it once Cra runs them on Windows. CraCore's SiteControlCenter decides what it shows.
@MainActor
final class SiteControlCenterView {
    private typealias M = SiteControlCenter.Metrics

    struct Actions {
        var perform: (SiteControlCenter.Action) -> Void = { _ in }
        var more: (SiteControlCenter.MoreItem) -> Void = { _ in }
        var toggle: (SiteControlCenter.Setting) -> Void = { _ in }
        /// The connection pill: the page's certificate. nil without one.
        var showCertificate: (() -> Void)?
    }

    let root = Grid()
    private(set) var height = Double(M.height(extensions: nil, settingRows: 0))
    var actions = Actions()
    /// The window that holds the view: the More menu's owner.
    var ownerWindow: () -> UInt = { 0 }
    /// Escape, as it closes Arc's popover.
    var onEscape: () -> Void = {}
    private var firstTile: Button?

    init() {
        root.previewKeyDown.addHandler { [weak self] _, args in
            guard let self, let args, Int32(truncatingIfNeeded: args.key.rawValue) == 0x1B else { return }
            args.handled = true
            self.onEscape()
        }
    }

    /// Puts the keyboard in the popover (on its first tile, without a focus ring) so Escape
    /// reaches it.
    func focus() {
        _ = try? firstTile?.focus(.pointer)
    }

    /// Builds the contents for the page at `url`. `dark` is Windows' own light or dark mode, as
    /// Arc's popover follows macOS rather than the space (#171).
    func build(url: String, secure: Bool, rows: [SiteControlCenter.SettingRow], dark: Bool) {
        let colors = Colors(dark: dark)
        root.children.clear()
        root.rowDefinitions.clear()
        root.requestedTheme = dark ? .dark : .light
        root.background = colors.background
        root.padding = Thickness(left: Double(M.inset), top: Double(M.top), right: Double(M.inset), bottom: Double(M.inset))
        var parts: [FrameworkElement] = [actionRow(colors)]
        if !rows.isEmpty { parts.append(settingsSection(rows, colors)) }
        parts.append(divider(colors))
        parts.append(footer(secure: secure, colors))
        for (i, part) in parts.enumerated() {
            root.rowDefinitions.append(UI.row(UI.auto))
            root.children.append(part)
            try? Grid.setRow(part, Int32(i))
        }
        height = Double(M.height(extensions: nil, settingRows: rows.count))
    }

    // MARK: Parts

    /// Share, Copy URL, Capture, Capture Full Page: 48 × 32 raised tiles, 8 apart.
    private func actionRow(_ colors: Colors) -> FrameworkElement {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = Double(M.gap)
        row.margin = Thickness(left: 0, top: 0, right: 0, bottom: Double(M.afterActions))
        firstTile = nil
        for action in SiteControlCenter.Action.allCases {
            let glyph = FontIcon()
            glyph.glyph = WinGlyph.code(action.symbol)
            glyph.fontSize = 15
            glyph.foreground = colors.text
            let b = UI.button(glyph, fill: colors.action, padding: Thickness(left: 0, top: 0, right: 0, bottom: 0)) { [weak self] in
                self?.actions.perform(action)
            }
            b.width = Double(M.tile.width)
            b.height = Double(M.tile.height)
            b.cornerRadius = CornerRadius(topLeft: 7, topRight: 7, bottomRight: 7, bottomLeft: 7)
            b.borderBrush = colors.actionOutline
            b.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
            Self.keepFill(b, colors.action, hover: colors.actionHover)
            try? ToolTipService.setToolTip(b, action.help)
            try? AutomationProperties.setName(b, action.help)
            if firstTile == nil { firstTile = b }
            row.children.append(b)
        }
        return row
    }

    /// "Settings" and a row a switch: a circle with the switch's glyph, its title and state.
    private func settingsSection(_ rows: [SiteControlCenter.SettingRow], _ colors: Colors) -> FrameworkElement {
        let section = StackPanel()
        section.spacing = Double(M.settingRowGap)
        section.margin = Thickness(left: 0, top: 0, right: 0, bottom: Double(M.afterSettings))
        let title = UI.text("Settings", size: 12, color: colors.header)
        title.fontWeight = UWP.FontWeight(weight: 600)
        title.height = Double(M.sectionHeader - M.settingRowGap)
        section.children.append(title)
        for r in rows {
            let circle = Border()
            circle.width = 26
            circle.height = 26
            circle.cornerRadius = CornerRadius(topLeft: 13, topRight: 13, bottomRight: 13, bottomLeft: 13)
            circle.background = r.isOn ? colors.accent : colors.inactive
            let glyph = FontIcon()
            glyph.glyph = WinGlyph.code(r.symbol)
            glyph.fontSize = 12
            glyph.foreground = r.isOn ? colors.glyphOnAccent : colors.glyphOnInactive
            circle.child = glyph
            let words = StackPanel()
            words.verticalAlignment = .center
            words.children.append(UI.text(r.title, size: 13, color: colors.text))
            words.children.append(UI.text(r.subtitle, size: 11, color: colors.secondary))
            let line = StackPanel()
            line.orientation = .horizontal
            line.spacing = 9
            line.children.append(circle)
            line.children.append(words)
            let setting = r.setting
            let b = UI.button(line, padding: Thickness(left: 0, top: 0, right: 0, bottom: 0)) { [weak self] in self?.actions.toggle(setting) }
            b.width = Double(M.settingRow.width)
            b.height = Double(M.settingRow.height)
            b.horizontalContentAlignment = .left
            section.children.append(b)
        }
        return section
    }

    private func divider(_ colors: Colors) -> FrameworkElement {
        let line = Border()
        line.height = 1
        line.background = colors.divider
        line.margin = Thickness(left: 0, top: 0, right: 0, bottom: Double(M.afterDivider))
        return line
    }

    /// The connection pill on the left, "…" on the right.
    private func footer(secure: Bool, _ colors: Colors) -> FrameworkElement {
        let footer = Grid()
        footer.height = Double(M.footer)
        footer.columnDefinitions.append(UI.column(UI.star))
        footer.columnDefinitions.append(UI.column(UI.auto))

        let label = SiteControlCenter.securityLabel(secure: secure)
        let lock = FontIcon()
        lock.glyph = WinGlyph.code(secure ? "lock.fill" : "lock.open.fill")
        lock.fontSize = 12
        lock.foreground = colors.text
        let words = UI.text(label.title, size: 14, color: colors.text, trimmed: false)
        words.fontWeight = UWP.FontWeight(weight: 600)
        let pillContent = StackPanel()
        pillContent.orientation = .horizontal
        pillContent.spacing = 6
        pillContent.children.append(lock)
        pillContent.children.append(words)
        let certificate = actions.showCertificate
        let pill = UI.button(pillContent, fill: colors.footerFill, padding: Thickness(left: 10, top: 0, right: 10, bottom: 0)) {
            certificate?()
        }
        pill.height = Double(M.footer)
        pill.horizontalAlignment = .left
        pill.cornerRadius = CornerRadius(topLeft: 8, topRight: 8, bottomRight: 8, bottomLeft: 8)
        pill.isHitTestVisible = certificate != nil
        Self.keepFill(pill, colors.footerFill, hover: certificate != nil ? colors.footerHover : colors.footerFill)
        try? ToolTipService.setToolTip(pill, label.help)
        try? AutomationProperties.setName(pill, label.title)
        footer.children.append(pill)
        try? Grid.setColumn(pill, 0)

        let dots = FontIcon()
        dots.glyph = WinGlyph.code("ellipsis")
        dots.fontSize = 13
        dots.foreground = colors.text
        let more = UI.button(dots, fill: colors.moreFill, padding: Thickness(left: 0, top: 0, right: 0, bottom: 0)) { [weak self] in
            self?.showMoreMenu()
        }
        more.width = Double(M.footer)
        more.height = Double(M.footer)
        more.cornerRadius = CornerRadius(topLeft: 16, topRight: 16, bottomRight: 16, bottomLeft: 16)
        Self.keepFill(more, colors.moreFill, hover: colors.moreHover)
        try? ToolTipService.setToolTip(more, "More")
        try? AutomationProperties.setName(more, "More")
        footer.children.append(more)
        try? Grid.setColumn(more, 1)
        return footer
    }

    /// Arc's "…": a native menu at the pointer, as the Mac's NSMenu (a XAML flyout would be
    /// cut off at the edges of this small window).
    private func showMoreMenu() {
        var items: [SiteControlCenter.MoreItem?] = []
        for (i, group) in SiteControlCenter.moreMenu(extensions: false).enumerated() {
            if i > 0 { items.append(nil) }
            items += group.map { $0 }
        }
        guard let chosen = WinShell.popupMenu(owner: ownerWindow(), items.map { $0?.title }), let item = items[chosen] else { return }
        actions.more(item)
    }

    /// A WinUI button paints its own hover and press fills over `background`; these keep the
    /// tile's own colours (as the Mac's tiles brighten a little on hover).
    private static func keepFill(_ b: Button, _ fill: Brush, hover: Brush) {
        _ = b.resources.insert("ButtonBackgroundPointerOver", hover)
        _ = b.resources.insert("ButtonBackgroundPressed", hover)
        _ = b.resources.insert("ButtonBorderBrushPointerOver", b.borderBrush ?? UI.clear)
        _ = b.resources.insert("ButtonBorderBrushPressed", b.borderBrush ?? UI.clear)
    }

    /// The Mac's SiteControlCenterColors (Arc 1.170's, sampled; light ones mirror them).
    @MainActor
    private struct Colors {
        let background, action, actionHover, actionOutline, text, header, secondary, divider: Brush
        let footerFill, footerHover, moreFill, moreHover, accent, inactive, glyphOnAccent, glyphOnInactive: Brush

        init(dark: Bool) {
            if dark {
                background = UI.brush("#272728")
                action = UI.brush("#2C2C2C")
                actionHover = UI.brush("#323232")
                actionOutline = UI.brush("#69696A", alpha: 90)
                text = UI.brush("#DCDCDC")
                header = UI.brush("#D4D4D5")
                secondary = UI.brush("#979798")
                divider = UI.brush(255, 255, 255, alpha: 26)
                footerFill = UI.brush("#363536")
                footerHover = UI.brush("#403F40")
                moreFill = UI.brush("#403F40")
                moreHover = UI.brush("#4A494A")
                accent = UI.brush("#F0F1FE")
                inactive = UI.brush("#6A6A6F")
                glyphOnAccent = UI.brush("#232325")
                glyphOnInactive = UI.brush("#232325")
            } else {
                background = UI.brush("#F4F4F5")
                action = UI.brush("#F5F5F5")
                actionHover = UI.brush("#F9F9F9")
                actionOutline = UI.brush(0, 0, 0, alpha: 20)
                text = UI.brush("#232325")
                header = UI.brush("#2A2A2C")
                secondary = UI.brush("#6E6E73")
                divider = UI.brush(0, 0, 0, alpha: 26)
                footerFill = UI.brush(0, 0, 0, alpha: 13)
                footerHover = UI.brush(0, 0, 0, alpha: 20)
                moreFill = UI.brush(0, 0, 0, alpha: 20)
                moreHover = UI.brush(0, 0, 0, alpha: 28)
                accent = UI.brush("#232325")
                inactive = UI.brush("#C7C7CC")
                glyphOnAccent = UI.brush(255, 255, 255)
                glyphOnInactive = UI.brush("#3A3A3C")
            }
        }
    }
}
