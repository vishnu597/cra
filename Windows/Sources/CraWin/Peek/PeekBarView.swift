import CraCore
import Foundation
import UWP
import WinSDK
import WinUI

/// Arc's Peek card bar (the Mac's PeekBarView): the page card's own 32 DIP toolbar. Back, forward
/// and refresh from the card's edge, the address centred with its copy-link glyph, in the page's
/// colour (white until it reports one; PeekLayout.BarColors). HostWindow shows it in its strip
/// over the page.
@MainActor
final class PeekBarView {
    var onBack: () -> Void = {}
    var onForward: () -> Void = {}
    /// Refresh, or stop while the page loads.
    var onReload: () -> Void = {}
    /// The address: the command bar on it.
    var onEditURL: () -> Void = {}
    var onCopy: () -> Void = {}
    /// A key the bar doesn't use itself (it has the keyboard after a click): Cra's shortcuts.
    var onKey: (KeyPress) -> Bool = { _ in false }

    let root = Grid()
    private var back: Button!
    private var forward: Button!
    private var reload: Button!
    private let backGlyph = FontIcon(), forwardGlyph = FontIcon(), reloadGlyph = FontIcon()
    private var address: Button!
    private let host = TextBlock()
    private let path = TextBlock()
    private let copyGlyph = FontIcon()
    private var copy: Button!

    private struct Shown: Equatable {
        var url = "", themeColor: String?
        var canGoBack = false, canGoForward = false, isLoading = false
    }
    private var shown: Shown?

    init() {
        build()
        show(url: "", themeColor: nil, canGoBack: false, canGoForward: false, isLoading: false)
    }

    func show(url: String, themeColor: String?, canGoBack: Bool, canGoForward: Bool, isLoading: Bool) {
        let state = Shown(url: url, themeColor: themeColor, canGoBack: canGoBack, canGoForward: canGoForward, isLoading: isLoading)
        guard state != shown else { return }
        shown = state
        let colors = PeekLayout.BarColors(reported: themeColor)
        let fill = brush(colors.fill), ink = brush(colors.ink, alpha: colors.inkAlpha), dim = brush(colors.dimInk, alpha: colors.dimInkAlpha)
        let hover = UI.brush(255, 255, 255, alpha: UInt8((PeekLayout.BarColors.hoverAlpha * 255).rounded()))
        // On a white bar white at 10 % shows nothing: a dark wash instead (Arc's hover reads on both).
        let hot = colors.light ? UI.brush(0, 0, 0, alpha: 20) : hover
        root.background = fill
        root.requestedTheme = colors.light ? .light : .dark
        for (button, glyph) in [(back!, backGlyph), (forward!, forwardGlyph), (reload!, reloadGlyph), (copy!, copyGlyph)] {
            glyph.foreground = dim
            paintStates(button, hover: hot, ink: dim)
        }
        // Never disabled, which WinUI draws as a grey block: a dimmer glyph says there's no history.
        backGlyph.opacity = canGoBack ? 1 : 0.4
        forwardGlyph.opacity = canGoForward ? 1 : 0.4
        reloadGlyph.glyph = WinGlyph.code(isLoading ? "xmark" : "arrow.clockwise")
        try? ToolTipService.setToolTip(reload, isLoading ? "Stop" : "Refresh" + keyHint("reload"))
        try? AutomationProperties.setName(reload, isLoading ? "Stop" : "Refresh")
        let human = SuggestionEngine.humanURL(url)
        let site = AppSettings.siteKey(for: url) ?? human
        // Arc's Peek shows the path too ("example.com/peek"), dimmed after the host.
        host.text = site
        host.foreground = ink
        path.text = human.hasPrefix(site) ? String(human.dropFirst(site.count)) : ""
        path.foreground = dim
        address.visibility = url.isEmpty ? .collapsed : .visible
        paintStates(address, hover: colors.light ? UI.brush(0, 0, 0, alpha: 14) : UI.brush(255, 255, 255, alpha: 20), ink: ink)
        try? ToolTipService.setToolTip(address, url)
    }

    // MARK: Layout

    private func build() {
        root.height = Double(PeekLayout.barHeight)
        // 2.5 in, the three buttons, then the address centred on the bar, clear of them.
        root.columnDefinitions.append(UI.column(UI.star))
        let buttons = StackPanel()
        buttons.orientation = .horizontal
        buttons.horizontalAlignment = .left
        buttons.verticalAlignment = .center
        buttons.margin = Thickness(left: 2.5, top: 0, right: 0, bottom: 0)
        back = glyphButton(backGlyph, symbol: "arrow.left", name: "Go Back", tip: "Go Back" + keyHint("goBack")) { [weak self] in self?.onBack() }
        forward = glyphButton(forwardGlyph, symbol: "arrow.right", name: "Go Forward", tip: "Go Forward" + keyHint("goForward")) { [weak self] in
            self?.onForward()
        }
        reload = glyphButton(reloadGlyph, symbol: "arrow.clockwise", name: "Refresh", tip: "Refresh" + keyHint("reload")) { [weak self] in
            self?.onReload()
        }
        for b in [back!, forward!, reload!] { buttons.children.append(b) }
        root.children.append(buttons)

        let label = StackPanel()
        label.orientation = .horizontal
        label.verticalAlignment = .center
        host.fontSize = 13
        host.fontWeight = UWP.FontWeight(weight: 500)
        host.verticalAlignment = .center
        label.children.append(host)
        path.fontSize = 13
        path.verticalAlignment = .center
        path.textTrimming = .characterEllipsis
        label.children.append(path)
        address = UI.button(label, padding: Thickness(left: 8, top: 0, right: 8, bottom: 0)) { [weak self] in self?.onEditURL() }
        address.height = 28
        try? AutomationProperties.setName(address, "Address")

        copyGlyph.glyph = WinGlyph.code("link")
        copyGlyph.fontSize = 13
        copy = UI.button(copyGlyph, padding: Thickness(left: 0, top: 0, right: 0, bottom: 0)) { [weak self] in self?.onCopy() }
        copy.width = 26
        copy.height = 26
        try? ToolTipService.setToolTip(copy, "Copy URL" + keyHint("copyURL"))
        try? AutomationProperties.setName(copy, "Copy URL")

        let centre = StackPanel()
        centre.orientation = .horizontal
        centre.spacing = 2
        centre.horizontalAlignment = .center
        centre.verticalAlignment = .center
        // Clear of the three buttons on either side (3 × 37 + 2.5, and 14 more), as on the Mac.
        centre.margin = Thickness(left: 128, top: 0, right: 128, bottom: 0)
        centre.children.append(address)
        centre.children.append(copy)
        root.children.append(centre)

        // Cra's shortcuts while the bar has the keyboard (the page reports its own).
        root.keyDown.addHandler { [weak self] _, args in
            guard let self, let args, !args.handled else { return }
            let key = KeyPress(keyCode: Int32(truncatingIfNeeded: args.key.rawValue), control: GetKeyState(0x11) < 0,
                               shift: GetKeyState(0x10) < 0, alt: GetKeyState(0x12) < 0)
            if self.onKey(key) { args.handled = true }
        }
    }

    /// The keyboard in the bar (its address), for its key handler to hear: the card's page
    /// isn't made yet. Win32 focus must be in the strip's XAML first (HostWindow.focusTopBar).
    func takeKeyboard() {
        _ = try? address.focus(.programmatic)
    }

    private func glyphButton(_ glyph: FontIcon, symbol: String, name: String, tip: String, _ action: @escaping @MainActor () -> Void) -> Button {
        glyph.glyph = WinGlyph.code(symbol)
        glyph.fontSize = 15
        let b = UI.button(glyph, padding: Thickness(left: 0, top: 0, right: 0, bottom: 0), action)
        b.width = 37
        b.height = 26
        try? ToolTipService.setToolTip(b, tip)
        try? AutomationProperties.setName(b, name)
        return b
    }

    private func keyHint(_ action: String) -> String {
        WinKeyBindings.shared.action(action)?.primary.map { " (\($0.windowsDisplay))" } ?? ""
    }

    /// The hover and press fill, keeping the content's own colour (WinUI's default turns it white).
    private func paintStates(_ b: Button, hover: Brush, ink: Brush) {
        for key in ["ButtonBackgroundPointerOver", "ButtonBackgroundPressed"] { _ = b.resources.insert(key, hover) }
        for key in ["ButtonForegroundPointerOver", "ButtonForegroundPressed"] { _ = b.resources.insert(key, ink) }
    }

    private func brush(_ c: RGB, alpha: Double = 1) -> SolidColorBrush {
        UI.brush(UInt8((c.r * 255).rounded()), UInt8((c.g * 255).rounded()), UInt8((c.b * 255).rounded()),
                 alpha: UInt8((alpha * 255).rounded()))
    }
}
