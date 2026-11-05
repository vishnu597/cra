import CraCore
import Foundation
import UWP
import WinAppSDK
import WindowsFoundation
import WinSDK
import WinUI

/// Arc's Developer Mode bar over the page (the Mac's PaneToolbarView with kind `.developer`,
/// GitHub #42, #88): the full URL in monospace, edited in place on a click, then Copy URL | Console,
/// Network, Inspect | Split View, on the space's colour under faint stripes. CraCore's
/// ToolbarComposition decides the buttons and SpaceTheme.developerBar the colours. HostWindow
/// shows it in its strip over the page area.
@MainActor
final class DeveloperBarView {
    /// Arc's developer bar is 40 pt (CraMetrics.developerToolbarHeight).
    static let height = 40.0

    /// An address typed into the field and committed with Return.
    var onCommit: (String) -> Void = { _ in }
    /// An action by its id, as the command bar runs them: "copyURL", "jsConsole", "networkPanel",
    /// "inspectElement", "addSplitView".
    var onAction: (String) -> Void = { _ in }
    /// The field gave up the keyboard (Return or Escape): it goes back to the page.
    var onEditEnded: () -> Void = {}
    /// A key the bar doesn't use itself: Cra's shortcuts.
    var onKey: (KeyPress) -> Bool = { _ in false }

    let root = Grid()
    private let stripes = Canvas()
    private let veil = Border()
    private let hairline = Border()
    private let content = Grid()
    private let lock = FontIcon()
    private let field = TextBox()
    private var buttons: [String: Button] = [:]
    private var icons: [FontIcon] = []
    private var dividers: [Border] = []
    private var url = ""
    private var theme: SpaceTheme?
    private var stripeSize = (width: 0.0, height: 0.0)
    private var editing = false

    init() {
        build()
    }

    var isEditing: Bool { editing }

    /// The tab's address and the space's colours.
    func show(url: String, theme: SpaceTheme) {
        if !editing, url != self.url || field.text != url {
            self.url = url
            setText(url)
        } else {
            self.url = url
        }
        lock.glyph = WinGlyph.code(url.hasPrefix("https://") ? "lock.fill" : "globe")
        try? ToolTipService.setToolTip(field, url)
        guard theme != self.theme else { return }
        self.theme = theme
        apply(theme)
    }

    /// The field takes the keyboard with the whole URL selected (Arc's ContentPanelTextField).
    func beginEditing() {
        _ = try? field.focus(.programmatic)
        try? field.selectAll()
    }

    // MARK: Build

    private func build() {
        root.height = Self.height
        stripes.isHitTestVisible = false
        veil.isHitTestVisible = false
        veil.visibility = .collapsed
        veil.background = UI.brush(255, 255, 255, alpha: 23)  // Arc lifts the bar ~9 % while editing
        hairline.isHitTestVisible = false
        hairline.height = 1
        hairline.verticalAlignment = .bottom
        hairline.background = UI.brush(255, 255, 255, alpha: 26)  // white 10 %
        root.sizeChanged.addHandler { [weak self] _, _ in self?.drawStripes() }

        // From the Mac's layout (Arc 1.170, #88): 8 pt, the address, 7 pt, Copy, 14, a rule, 13,
        // Console, Network, Inspect, 7, a rule, 8, Split View, 6 pt from the edge.
        let columns: [GridLength] = [UI.pixels(8), UI.star, UI.pixels(7), UI.auto, UI.pixels(14), UI.pixels(1), UI.pixels(13),
                                     UI.auto, UI.auto, UI.auto, UI.pixels(7), UI.pixels(1), UI.pixels(8), UI.auto, UI.pixels(6)]
        for width in columns { content.columnDefinitions.append(UI.column(width)) }

        let address = Grid()
        for width in [UI.pixels(6), UI.pixels(14), UI.pixels(12), UI.star, UI.pixels(6)] { address.columnDefinitions.append(UI.column(width)) }
        address.height = 28
        address.verticalAlignment = .center
        lock.fontSize = 11
        lock.verticalAlignment = .center
        lock.horizontalAlignment = .center
        address.children.append(lock)
        try? Grid.setColumn(lock, 1)
        field.fontFamily = FontFamily("Cascadia Mono, Consolas")
        field.fontSize = 12
        field.minHeight = 0
        field.padding = Thickness(left: 0, top: 4, right: 0, bottom: 4)
        field.verticalAlignment = .center
        field.borderThickness = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        field.background = UI.clear
        field.isSpellCheckEnabled = false
        field.isTextPredictionEnabled = false
        try? AutomationProperties.setName(field, "Address")
        for key in ["TextControlBackgroundFocused", "TextControlBackgroundPointerOver", "TextControlBorderBrushFocused",
                    "TextControlBorderBrushPointerOver", "TextControlBackground", "TextControlBorderBrush"] {
            _ = field.resources.insert(key, UI.clear)
        }
        field.gotFocus.addHandler { [weak self] _, _ in self?.editingChanged(true) }
        field.lostFocus.addHandler { [weak self] _, _ in self?.editingChanged(false) }
        field.previewKeyDown.addHandler { [weak self] _, args in
            guard let self, let args else { return }
            switch Int32(truncatingIfNeeded: args.key.rawValue) {
            case 0x0D:  // Return
                let typed = self.field.text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.endEditing()
                if !typed.isEmpty { self.onCommit(typed) }
            case 0x1B:  // Escape
                self.endEditing()
            default:
                return
            }
            args.handled = true
        }
        address.children.append(field)
        try? Grid.setColumn(field, 3)
        content.children.append(address)
        try? Grid.setColumn(address, 1)

        let bar = ToolbarComposition(kind: .developer, inSplit: false, sidebarVisible: true, focusedPane: true, canGoBack: false,
                                     canGoForward: false, isLoading: false, pinnedExtensions: [], hasExtensions: false)
        // copy · divider · Console, Network, Inspect, then the right end (Split View), each in
        // its column above; Arc's second rule only when something follows Inspect.
        for item in bar.right {
            let element: FrameworkElement, column: Int32
            switch item {
            case .copyURL: (element, column) = (glyph("link", "copyURL", tip: "Copy URL", width: 28), 3)
            case .divider: (element, column) = (divider(), 5)
            case .console: (element, column) = (glyph("terminal", "jsConsole", tip: "Toggle Console", width: 28), 7)
            case .network: (element, column) = (glyph("globe", "networkPanel", tip: "Toggle Network Panel", width: 28), 8)
            case .inspect: (element, column) = (glyph("scope", "inspectElement", tip: "Inspect Element", width: 28), 9)
            case .addSplit: (element, column) = (glyph("square.split.2x1", "addSplitView", tip: "Add Split View", width: 34, size: 16), 13)
            default: continue
            }
            content.children.append(element)
            try? Grid.setColumn(element, column)
        }
        if bar.right.last != .inspect {
            let rule = divider()
            content.children.append(rule)
            try? Grid.setColumn(rule, 11)
        }

        // Cra's shortcuts while the field has the keyboard (the page reports its own).
        root.keyDown.addHandler { [weak self] _, args in
            guard let self, let args, !args.handled else { return }
            let key = KeyPress(keyCode: Int32(truncatingIfNeeded: args.key.rawValue), control: GetKeyState(0x11) < 0,
                               shift: GetKeyState(0x10) < 0, alt: GetKeyState(0x12) < 0)
            if self.onKey(key) { args.handled = true }
        }

        for part in [stripes, veil, content, hairline] as [FrameworkElement] { root.children.append(part) }
    }

    /// A 28 pt box (34 for Split View) with its glyph, Arc's 6 pt corners, white 8 % on hover.
    private func glyph(_ symbol: String, _ action: String, tip: String, width: Double, size: Double = 13) -> Button {
        let icon = FontIcon()
        icon.glyph = WinGlyph.code(symbol)
        icon.fontSize = size
        icons.append(icon)
        let b = UI.button(icon, padding: Thickness(left: 0, top: 0, right: 0, bottom: 0)) { [weak self] in self?.onAction(action) }
        b.width = width
        b.height = 28
        b.verticalAlignment = .center
        b.cornerRadius = CornerRadius(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6)
        _ = b.resources.insert("ButtonBackgroundPointerOver", UI.brush(255, 255, 255, alpha: 20))
        _ = b.resources.insert("ButtonBackgroundPressed", UI.brush(255, 255, 255, alpha: 31))
        let keys = WinKeyBindings.shared.action(action)?.primary.map { " (\($0.windowsDisplay))" } ?? ""
        try? ToolTipService.setToolTip(b, tip + keys)
        try? AutomationProperties.setName(b, tip)
        buttons[action] = b
        return b
    }

    private func divider() -> Border {
        let d = Border()
        d.width = 1
        d.height = 14
        d.verticalAlignment = .center
        dividers.append(d)
        return d
    }

    // MARK: Colours

    private func apply(_ theme: SpaceTheme) {
        root.requestedTheme = .dark
        let fill = theme.developerBar, ink = theme.developerInk, secondary = theme.developerSecondary
        func brush(_ c: RGB, alpha: UInt8 = 255) -> SolidColorBrush {
            UI.brush(UInt8((c.r * 255).rounded()), UInt8((c.g * 255).rounded()), UInt8((c.b * 255).rounded()), alpha: alpha)
        }
        root.background = brush(fill)
        let inkBrush = brush(ink)
        lock.foreground = inkBrush
        for icon in icons { icon.foreground = inkBrush }
        for b in buttons.values {
            _ = b.resources.insert("ButtonForegroundPointerOver", inkBrush)
            _ = b.resources.insert("ButtonForegroundPressed", inkBrush)
        }
        field.foreground = inkBrush
        for key in ["TextControlForeground", "TextControlForegroundFocused", "TextControlForegroundPointerOver"] {
            _ = field.resources.insert(key, inkBrush)
        }
        field.selectionHighlightColor = brush(secondary, alpha: 153)  // 60 %
        for d in dividers { d.background = brush(secondary, alpha: 115) }  // 45 %
    }

    /// Arc's stripes (CraCore's DeveloperStripes) for the bar's size.
    private func drawStripes() {
        let size = (width: root.actualWidth, height: root.actualHeight)
        guard size != stripeSize else { return }
        stripeSize = size
        stripes.children.clear()
        let fill = UI.brush(255, 255, 255, alpha: UInt8((DeveloperStripes.whiteAlpha * 255).rounded()))
        for band in DeveloperStripes.bands(width: size.width, height: size.height) {
            let points = PointCollection()
            for p in band { points.append(WindowsFoundation.Point(x: Float(p.x), y: Float(p.y))) }
            let shape = Polygon()
            shape.points = points
            shape.fill = fill
            stripes.children.append(shape)
        }
    }

    // MARK: Editing

    private func editingChanged(_ focused: Bool) {
        editing = focused
        veil.visibility = focused ? .visible : .collapsed
        if focused {
            // After the click that focused it, which would put the caret where it landed.
            _ = try? WinAppSDK.DispatcherQueue.getForCurrentThread()?.tryEnqueue { [weak self] in
                guard let self, self.editing else { return }
                try? self.field.selectAll()
            }
        } else if field.text != url {
            // Clicked away: the address shows the page's again.
            setText(url)
        }
    }

    private func endEditing() {
        setText(url)
        onEditEnded()
    }

    private func setText(_ text: String) {
        field.text = text
    }
}
