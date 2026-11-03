import CraCore
import Foundation
import Observation
import UWP
import WinAppSDK
import WindowsFoundation
import WinSDK
import WinUI

extension DownloadHistory {
    /// downloads.json in the data folder, as on the Mac.
    static let shared = DownloadHistory(file: JSONStore("downloads.json", in: WinPaths.supportDir))
}

/// Arc's downloads list (DownloadsTrayView on the Mac): hovering the downloads button lists
/// the recent downloads over the bottom of the sidebar, newest at the bottom; it opens 0.2 s
/// into the hover and closes 0.07 s after the pointer leaves. Rows are 40 px with 16 between,
/// a tile, the file name and "54 seconds ago" or the progress under it. A click opens a
/// finished file; its menu shows it in its folder.
@MainActor
final class DownloadsTray {
    /// In the sidebar's footer: a download glyph, with the progress while a download runs.
    let button: Button
    /// Over the bottom of the tab list.
    let list = StackPanel()
    private let history: DownloadHistory
    private let dispatcher: WinAppSDK.DispatcherQueue
    private let glyph = FontIcon()
    private let progress = TextBlock()
    private var rows: [Row] = []
    private var isOpen = false
    private var buttonHovered = false
    private var listHovered = false
    private var hoverTimer: WinAppSDK.DispatcherQueueTimer?
    private var ticker: WinAppSDK.DispatcherQueueTimer?
    private var palette = SidebarPalette(SpaceTheme.presets[0])
    private var fill: Brush = UI.clear

    init(history: DownloadHistory, dispatcher: WinAppSDK.DispatcherQueue) {
        self.history = history
        self.dispatcher = dispatcher
        glyph.glyph = "\u{E896}"
        glyph.fontSize = 14
        progress.fontSize = 11
        progress.verticalAlignment = .center
        let content = StackPanel()
        content.orientation = .horizontal
        content.spacing = 6
        content.children.append(glyph)
        content.children.append(progress)
        button = UI.button(content, padding: Thickness(left: 6, top: 5, right: 6, bottom: 5)) {}
        button.verticalAlignment = .center
        try? ToolTipService.setToolTip(button, "Downloads")
        list.orientation = .vertical
        list.spacing = 16
        list.verticalAlignment = .bottom
        list.padding = Thickness(left: 0, top: 12, right: 0, bottom: 2)
        list.visibility = .collapsed
        // A click opens it too (touch, or a pointer that came in too fast for the hover).
        button.click.addHandler { [weak self] _, _ in self?.setOpen(true) }
        button.pointerEntered.addHandler { [weak self] _, _ in self?.hover(button: true) }
        button.pointerExited.addHandler { [weak self] _, _ in self?.hover(button: false) }
        list.pointerEntered.addHandler { [weak self] _, _ in self?.hover(list: true) }
        list.pointerExited.addHandler { [weak self] _, _ in self?.hover(list: false) }
        observe()
    }

    /// The sidebar's colours for the focused space.
    func apply(_ palette: SidebarPalette, fill: Brush) {
        self.palette = palette
        self.fill = fill
        list.background = fill
        glyph.foreground = palette.secondaryText
        progress.foreground = palette.secondaryText
        for row in rows { row.apply(palette) }
    }

    // MARK: The list

    private func observe() {
        let (recent, running) = withObservationTracking {
            (history.recent, history.live.filter(\.running))
        } onChange: { [weak self] in
            // Inside the change: draw once it is done.
            onMain { _ = try? self?.dispatcher.tryEnqueue { self?.observe() } }
        }
        while rows.count < recent.count {
            let row = Row()
            row.apply(palette)
            rows.append(row)
            list.children.append(row.root)
        }
        while rows.count > recent.count {
            rows.removeLast()
            list.children.removeAtEnd()
        }
        let now = Date()
        for (row, item) in zip(rows, recent) { row.show(item, now: now) }
        // The button says how far the running downloads are (Arc throws the file at its Library
        // button instead; the list has the detail).
        if running.isEmpty {
            progress.visibility = .collapsed
        } else {
            let received = running.reduce(Int64(0)) { $0 + $1.received }, total = running.reduce(Int64(0)) { $0 + max(0, $1.total) }
            progress.text = total > 0 ? "\(min(100, Int(received * 100 / total)))%" : DownloadRow.bytes(received)
            progress.visibility = .visible
        }
        if recent.isEmpty, isOpen { setOpen(false) }
    }

    private func refreshAges() {
        let now = Date()
        for (row, item) in zip(rows, history.recent) { row.show(item, now: now) }
    }

    private func hover(button: Bool? = nil, list: Bool? = nil) {
        if let button { buttonHovered = button }
        if let list { listHovered = list }
        let open = (buttonHovered || listHovered) && !history.recent.isEmpty
        try? hoverTimer?.stop()
        guard open != isOpen else { return }
        hoverTimer = try? dispatcher.createTimer()
        hoverTimer?.interval = TimeSpan(duration: open ? 200 * 10_000 : 70 * 10_000)
        hoverTimer?.isRepeating = false
        hoverTimer?.tick.addHandler { [weak self] _, _ in self?.setOpen(open) }
        try? hoverTimer?.start()
    }

    private func setOpen(_ open: Bool) {
        try? hoverTimer?.stop()
        let open = open && !history.recent.isEmpty
        guard open != isOpen else { return }
        isOpen = open
        list.visibility = open ? .visible : .collapsed
        // The ages tick while the list is up.
        if open {
            refreshAges()
            ticker = try? dispatcher.createTimer()
            ticker?.interval = TimeSpan(duration: 10_000_000)
            ticker?.isRepeating = true
            ticker?.tick.addHandler { [weak self] _, _ in self?.refreshAges() }
            try? ticker?.start()
        } else {
            try? ticker?.stop()
            ticker = nil
        }
    }

    /// One download: a tile, the name, and the line under it.
    @MainActor
    final class Row {
        let root = Grid()
        private let tile = Border()
        private let tileIcon = FontIcon()
        private let name = TextBlock()
        private let subtitle = TextBlock()
        private var path: String?

        init() {
            root.height = 40
            root.background = UI.clear
            for width in [UI.pixels(61), UI.star] { root.columnDefinitions.append(UI.column(width)) }
            tile.width = 40
            tile.height = 40
            tile.margin = Thickness(left: 8, top: 0, right: 0, bottom: 0)
            tile.horizontalAlignment = .left
            tile.cornerRadius = CornerRadius(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6)
            tile.background = UI.brush(255, 255, 255, alpha: 230)
            tileIcon.glyph = "\u{E8A5}"
            tileIcon.fontSize = 18
            tileIcon.foreground = UI.brush(90, 90, 96)
            tile.child = tileIcon
            name.fontSize = 14
            name.textTrimming = .characterEllipsis
            subtitle.fontSize = 12
            subtitle.textTrimming = .characterEllipsis
            let text = StackPanel()
            text.verticalAlignment = .center
            text.children.append(name)
            text.children.append(subtitle)
            root.children.append(tile)
            root.children.append(text)
            try? Grid.setColumn(text, 1)
            root.tapped.addHandler { [weak self] _, args in
                guard let self, let path = self.path else { return }
                args?.handled = true
                Shell.open(path)
            }
            let menu = MenuFlyout()
            menu.items.append(UI.menuItem("Open") { [weak self] in self?.path.map(Shell.open) })
            menu.items.append(UI.menuItem("Show in Folder") { [weak self] in self?.path.map(Shell.showInFolder) })
            menu.opening.addHandler { [weak self, weak menu] _, _ in
                // Running, failed and cancelled downloads have no file to open yet.
                if self?.path == nil { try? menu?.hide() }
            }
            root.contextFlyout = menu
        }

        func apply(_ palette: SidebarPalette) {
            name.foreground = palette.text
            subtitle.foreground = palette.secondaryText
        }

        func show(_ item: DownloadHistory.Listed, now: Date) {
            if name.text != item.name { name.text = item.name }
            let line = item.subtitle(now: now)
            if subtitle.text != line { subtitle.text = line }
            if case .finished(let entry) = item { path = entry.path } else { path = nil }
        }
    }
}

/// Opening files the way Explorer does.
enum Shell {
    static func open(_ path: String) { run("open", path, nil) }

    /// An Explorer window on the file's folder, the file selected.
    static func showInFolder(_ path: String) { run("open", "explorer.exe", "/select,\"\(path)\"") }

    private static func run(_ verb: String, _ file: String, _ parameters: String?) {
        verb.withCString(encodedAs: UTF16.self) { verb in
            file.withCString(encodedAs: UTF16.self) { file in
                if let parameters {
                    parameters.withCString(encodedAs: UTF16.self) { _ = ShellExecuteW(nil, verb, file, $0, nil, SW_SHOWNORMAL) }
                } else {
                    _ = ShellExecuteW(nil, verb, file, nil, nil, SW_SHOWNORMAL)
                }
            }
        }
    }
}
