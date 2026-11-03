import CraCore
import Foundation
import Observation
import UWP
import WinAppSDK
import WinSDK
import WindowsFoundation
import WinUI

/// Dia's Settings window (SettingsWindowController on the Mac): 778×509 DIPs, not resizable, a
/// 204 DIP sidebar listing the panes, and over the content a 52 DIP toolbar with the
/// back/forward pill and the pane's title. Ctrl+, opens it; closing hides it, keeping its pane
/// and history for the next time.
///
/// All XAML (no pages in it), so its island covers the whole window.
@MainActor
final class SettingsWindow {
    private let appWindow: AppWindow
    private let xaml = DesktopWindowXamlSource()
    private let store: SidebarStore
    private let nav = SettingsNavigation()
    private let palette = SettingsPalette()
    private let sidebarRows = StackPanel()
    private let titleText = UI.text("", size: 15, trimmed: false)
    private let backArrow = FontIcon()
    private let forwardArrow = FontIcon()
    private var backButton: Button!
    private var forwardButton: Button!
    private let scroll = ScrollViewer()
    private var shownPane: SettingsPane?
    /// Puts the shown pane's controls in step with the settings (changed elsewhere, or by them).
    private var syncPane: () -> Void = {}
    private var refreshQueued = false

    init(store: SidebarStore) throws {
        self.store = store
        guard let presenter = try OverlappedPresenter.create() else { throw FloatingWindowError.noPresenter }
        presenter.isResizable = false
        presenter.isMaximizable = false
        presenter.isMinimizable = false
        guard let window = try AppWindow.create(presenter) else { throw FloatingWindowError.noWindow }
        appWindow = window
        appWindow.title = "Settings"
        palette.style(appWindow.titleBar)
        try xaml.initialize(appWindow.id)
        xaml.content = makeLayout()
        appWindow.closing.addHandler { [weak self] _, args in
            args?.cancel = true
            self?.hide()
        }
        refresh()
    }

    /// Shows the window in front, centred on `owner` the first time.
    func show(over owner: HostWindow) {
        if !appWindow.isVisible {
            place(over: owner)
            nav.isOpen = true
            // What Windows changed while it was closed (Task Manager's startup apps).
            syncPane()
        }
        try? appWindow.show(true)
        if let bridge = xaml.siteBridge, let island = HWND(bitPattern: UInt(bridge.windowId.value)) {
            _ = SetFocus(island)
        }
    }

    func hide() {
        nav.isOpen = false
        try? appWindow.hide()
    }

    // MARK: Layout

    private var scale: Double {
        guard let window = HWND(bitPattern: UInt(appWindow.id.value)) else { return 1 }
        let dpi = GetDpiForWindow(window)
        return dpi > 0 ? Double(dpi) / 96 : 1
    }

    private func place(over owner: HostWindow) {
        let scale = self.scale
        let size = SettingsMetrics.windowSize
        try? appWindow.resizeClient(SizeInt32(width: Int32((Double(size.width) * scale).rounded()),
                                              height: Int32((Double(size.height) * scale).rounded())))
        let client = appWindow.clientSize
        try? xaml.siteBridge?.moveAndResize(RectInt32(x: 0, y: 0, width: client.width, height: client.height))
        let ownerAt = owner.appWindow.position, ownerSize = owner.appWindow.size, outer = appWindow.size
        try? appWindow.move(PointInt32(x: ownerAt.x + (ownerSize.width - outer.width) / 2,
                                       y: ownerAt.y + (ownerSize.height - outer.height) / 2))
    }

    private func makeLayout() -> UIElement {
        let root = Grid()
        root.requestedTheme = palette.isDark ? .dark : .light
        root.background = palette.window
        root.columnDefinitions.append(UI.column(UI.pixels(Double(SettingsMetrics.sidebarWidth))))
        root.columnDefinitions.append(UI.column(UI.pixels(1)))
        root.columnDefinitions.append(UI.column(UI.star))

        sidebarRows.orientation = .vertical
        sidebarRows.spacing = 0
        sidebarRows.padding = Thickness(left: 8, top: 10, right: 8, bottom: 8)
        sidebarRows.background = palette.sidebar
        root.children.append(sidebarRows)

        let divider = Border()
        divider.background = palette.hairline
        root.children.append(divider)
        try? Grid.setColumn(divider, 1)

        let main = Grid()
        main.rowDefinitions.append(UI.row(UI.pixels(Double(SettingsMetrics.toolbarHeight))))
        main.rowDefinitions.append(UI.row(UI.star))
        let toolbar = makeToolbar()
        main.children.append(toolbar)
        scroll.horizontalScrollBarVisibility = .disabled
        scroll.verticalScrollBarVisibility = .auto
        main.children.append(scroll)
        try? Grid.setRow(scroll, 1)
        root.children.append(main)
        try? Grid.setColumn(main, 2)
        return root
    }

    /// The pill 10 DIPs in from the split and the title 10 after it.
    private func makeToolbar() -> UIElement {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 10
        row.padding = Thickness(left: 10, top: 0, right: 10, bottom: 0)
        row.verticalAlignment = .center

        // A Border draws the capsule (a Grid's corner radius left its fill square, seen on a PC).
        let capsule = Border()
        let pill = Grid()
        let half = Double(SettingsMetrics.navPillSize.width) / 2, height = Double(SettingsMetrics.navPillSize.height)
        let r = height / 2
        capsule.width = Double(SettingsMetrics.navPillSize.width)
        capsule.height = height
        capsule.cornerRadius = CornerRadius(topLeft: r, topRight: r, bottomRight: r, bottomLeft: r)
        capsule.background = palette.pill
        capsule.child = pill
        pill.columnDefinitions.append(UI.column(UI.star))
        pill.columnDefinitions.append(UI.column(UI.star))
        for (arrow, glyph) in [(backArrow, "\u{E76B}"), (forwardArrow, "\u{E76C}")] {
            arrow.glyph = glyph
            arrow.fontSize = 13
            arrow.foreground = palette.text
        }
        backButton = UI.button(backArrow, padding: Thickness(left: 0, top: 0, right: 0, bottom: 0)) { [weak self] in self?.nav.goBack() }
        forwardButton = UI.button(forwardArrow, padding: Thickness(left: 0, top: 0, right: 0, bottom: 0)) { [weak self] in
            self?.nav.goForward()
        }
        for (i, button) in [backButton!, forwardButton!].enumerated() {
            button.width = half
            button.height = height
            // Rounded on the capsule's side only, so a hover fills its half.
            button.cornerRadius = i == 0 ? CornerRadius(topLeft: r, topRight: 0, bottomRight: 0, bottomLeft: r)
                : CornerRadius(topLeft: 0, topRight: r, bottomRight: r, bottomLeft: 0)
            try? ToolTipService.setToolTip(button, i == 0 ? "Back" : "Forward")
            pill.children.append(button)
            try? Grid.setColumn(button, Int32(i))
        }
        row.children.append(capsule)

        titleText.fontWeight = UWP.FontWeight(weight: 700)
        titleText.foreground = palette.text
        titleText.verticalAlignment = .center
        row.children.append(titleText)
        return row
    }

    // MARK: Navigation → window

    /// Draws the sidebar's selection, the pill and the pane, then waits for the next change to
    /// anything they read (the pane, the settings).
    private func refresh() {
        refreshQueued = false
        withObservationTracking {
            let pane = nav.pane
            buildSidebar(selected: pane)
            titleText.text = pane.title
            // Not disabled: a disabled Button draws WinUI's grey disabled fill over the capsule.
            // Going back or forward with no history does nothing anyway; the arrow dims.
            backArrow.opacity = nav.back.isEmpty ? 0.3 : 0.75
            forwardArrow.opacity = nav.forward.isEmpty ? 0.3 : 0.75
            if pane != shownPane { showPane(pane) }
            syncPane()
        } onChange: { [weak self] in
            onMain { self?.queueRefresh() }
        }
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        _ = try? WinAppSDK.DispatcherQueue.getForCurrentThread()?.tryEnqueue { [weak self] in self?.refresh() }
    }

    /// Dia's source list: 28 DIP rows, the glyph 20 DIPs in, the label at 49. The selected row
    /// is accent-filled with white text.
    private func buildSidebar(selected: SettingsPane) {
        sidebarRows.children.clear()
        for pane in SettingsPane.windowsPanes {
            let isSelected = pane == selected
            let ink = isSelected ? palette.onAccent : palette.text
            let icon = FontIcon()
            icon.glyph = Self.glyph(pane)
            icon.fontSize = 14
            icon.foreground = ink
            icon.width = 20
            let label = UI.text(pane.title, color: ink)
            label.margin = Thickness(left: 9, top: 0, right: 0, bottom: 0)
            label.verticalAlignment = .center
            let content = StackPanel()
            content.orientation = .horizontal
            content.children.append(icon)
            content.children.append(label)
            let row = UI.button(content, fill: isSelected ? palette.accent : nil,
                                padding: Thickness(left: 12, top: 0, right: 8, bottom: 0)) { [weak self] in self?.nav.show(pane) }
            row.height = 28
            row.horizontalAlignment = .stretch
            row.horizontalContentAlignment = .left
            sidebarRows.children.append(row)
        }
    }

    private func showPane(_ pane: SettingsPane) {
        shownPane = pane
        let built: SettingsPaneContent
        switch pane {
        case .tabs: built = SettingsPanes.tabs(store: store, palette: palette)
        case .shortcuts:
            let view = ShortcutsPaneView(bindings: WinKeyBindings.shared, palette: palette)
            built = SettingsPaneContent(element: view.root) { view.render() }
        default: built = SettingsPanes.general(palette: palette)
        }
        scroll.content = built.element
        syncPane = built.sync
        _ = try? scroll.changeView(nil, 0, nil, true)
    }

    /// The Mac's SF Symbols for the panes (SettingsPane.symbol) as Segoe Fluent Icons glyphs.
    private static func glyph(_ pane: SettingsPane) -> String {
        switch pane {
        case .general: return "\u{E713}"  // Settings
        case .tabs: return "\u{E8A9}"  // ViewAll
        case .privacy: return "\u{E72E}"  // Lock
        case .profiles: return "\u{E77B}"  // Contact
        case .extensions: return "\u{EA86}"  // Puzzle
        case .shortcuts: return "\u{E765}"  // Keyboard
        case .performance: return "\u{EC4A}"  // SpeedHigh
        case .advanced: return "\u{E90F}"  // Repair
        }
    }
}

/// The window's colours, after Windows' own Settings app in the system's light or dark mode,
/// with the system accent for the selected pane.
@MainActor
struct SettingsPalette {
    let isDark: Bool
    let window: Brush
    let sidebar: Brush
    let card: Brush
    let hairline: Brush
    let pill: Brush
    let text: Brush
    let secondaryText: Brush
    let error: Brush
    let accent: Brush
    let onAccent: Brush
    private let windowColor: UWP.Color
    private let textColor: UWP.Color

    init(isDark: Bool = WinAppearance.isDark) {
        self.isDark = isDark
        let a = WinAppearance.accent
        accent = UI.brush(a.r, a.g, a.b)
        onAccent = UI.brush(255, 255, 255)
        if isDark {
            windowColor = UWP.Color(a: 255, r: 32, g: 32, b: 32)
            textColor = UWP.Color(a: 255, r: 255, g: 255, b: 255)
            sidebar = UI.brush(28, 28, 28)
            card = UI.brush(255, 255, 255, alpha: 18)
            hairline = UI.brush(255, 255, 255, alpha: 26)
            pill = UI.brush(0, 0, 0, alpha: 64)
            secondaryText = UI.brush(255, 255, 255, alpha: 150)
            error = UI.brush(255, 153, 164)
        } else {
            windowColor = UWP.Color(a: 255, r: 243, g: 243, b: 243)
            textColor = UWP.Color(a: 255, r: 26, g: 26, b: 26)
            sidebar = UI.brush(235, 235, 235)
            card = UI.brush(255, 255, 255, alpha: 180)
            hairline = UI.brush(0, 0, 0, alpha: 20)
            pill = UI.brush(0, 0, 0, alpha: 15)
            secondaryText = UI.brush(26, 26, 26, alpha: 150)
            error = UI.brush(196, 43, 28)
        }
        window = SolidColorBrush(windowColor)
        text = SolidColorBrush(textColor)
    }

    /// The title bar in the window's colours, so a dark window has a dark one.
    func style(_ bar: AppWindowTitleBar?) {
        guard let bar else { return }
        bar.backgroundColor = windowColor
        bar.inactiveBackgroundColor = windowColor
        bar.buttonBackgroundColor = windowColor
        bar.buttonInactiveBackgroundColor = windowColor
        bar.foregroundColor = textColor
        bar.buttonForegroundColor = textColor
    }
}
