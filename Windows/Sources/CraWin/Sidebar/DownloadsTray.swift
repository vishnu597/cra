import CraCEFWin
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
    private let thumbnails: DownloadThumbnails
    private let dispatcher: WinAppSDK.DispatcherQueue
    private let glyph = FontIcon()
    private let progress = TextBlock()
    private var rows: [Row] = []
    private var isOpen = false
    /// The pointer in the XAML's coordinates (DIPs from the sidebar's top left), nil when it
    /// can't be read. XAML's PointerEntered and PointerExited come and go as the rows redraw
    /// under a still pointer, so the list asks where the pointer is instead.
    var pointer: () -> (x: Double, y: Double)? = { nil }
    /// Waits out the hover (0.2 s to open, 0.07 s to close), then checks every 0.07 s while the
    /// list is up; the ages tick once a second.
    private var hoverTimer: WinAppSDK.DispatcherQueueTimer?
    private var hoverStarted: Date?
    private var awayChecks = 0
    private var lastAges = Date.distantPast
    private var palette = SidebarPalette(SpaceTheme.presets[0])
    private var fill: Brush = UI.clear

    init(history: DownloadHistory, dispatcher: WinAppSDK.DispatcherQueue) {
        self.history = history
        self.dispatcher = dispatcher
        thumbnails = DownloadThumbnails(dispatcher: dispatcher)
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
        button.horizontalAlignment = .left
        // No tooltip: it would cover the pointer and end the hover.
        list.orientation = .vertical
        list.spacing = 16
        list.verticalAlignment = .bottom
        list.padding = Thickness(left: 0, top: 12, right: 0, bottom: 2)
        list.visibility = .collapsed
        // A click opens it at once (touch, or a pointer quicker than the hover).
        button.click.addHandler { [weak self] _, _ in self?.setOpen(true) }
        button.pointerEntered.addHandler { [weak self] _, _ in self?.startWatching() }
        list.pointerEntered.addHandler { [weak self] _, _ in self?.startWatching() }
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
        let (recent, running, _) = withObservationTracking {
            // The thumbnails' revision too: a row redraws when its picture arrives.
            (history.recent, history.live.filter(\.running), thumbnails.revision)
        } onChange: { [weak self] in
            // Inside the change: draw once it is done.
            onMain { _ = try? self?.dispatcher.tryEnqueue { self?.observe() } }
        }
        show(recent)
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

    /// One row per listed download. Also on the ticks: a file deleted since drops out, which
    /// nothing observable reports.
    private func show(_ recent: [DownloadHistory.Listed]) {
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
        for (row, item) in zip(rows, recent) { row.show(item, now: now, thumbnails: thumbnails) }
    }

    // MARK: Hover

    private func startWatching() {
        if hoverStarted == nil { hoverStarted = Date() }
        guard hoverTimer == nil else { return }
        hoverTimer = try? dispatcher.createTimer()
        hoverTimer?.interval = TimeSpan(duration: 70 * 10_000)
        hoverTimer?.isRepeating = true
        hoverTimer?.tick.addHandler { [weak self] _, _ in self?.check() }
        try? hoverTimer?.start()
    }

    private func stopWatching() {
        try? hoverTimer?.stop()
        hoverTimer = nil
        hoverStarted = nil
    }

    private func check() {
        let over = isOver(button) || (isOpen && isOver(list))
        if over {
            awayChecks = 0
            if !isOpen, let started = hoverStarted, Date().timeIntervalSince(started) >= 0.2 { setOpen(true) }
        } else {
            hoverStarted = nil
            // Away for a whole check (0.07 s): closed.
            awayChecks += 1
            if awayChecks >= 1 {
                if isOpen { setOpen(false) }
                stopWatching()
                return
            }
        }
        if isOpen, Date().timeIntervalSince(lastAges) >= 1 {
            lastAges = Date()
            show(history.recent)
            if history.recent.isEmpty { setOpen(false) }
        }
    }

    private func isOver(_ element: FrameworkElement) -> Bool {
        guard element.visibility == .visible, let p = pointer(),
              let transform = try? element.transformToVisual(nil),
              let origin = try? transform.transformPoint(WindowsFoundation.Point(x: 0, y: 0)) else { return false }
        let x = p.x - Double(origin.x), y = p.y - Double(origin.y)
        return x >= 0 && y >= 0 && x < element.actualWidth && y < element.actualHeight
    }

    private func setOpen(_ open: Bool) {
        let open = open && !history.recent.isEmpty
        guard open != isOpen else { return }
        isOpen = open
        list.visibility = open ? .visible : .collapsed
        if open {
            lastAges = Date()
            show(history.recent)
            // Kept open while the pointer is over the button or the list.
            awayChecks = 0
            startWatching()
        }
    }

    /// One download: a tile, the name, and the line under it.
    @MainActor
    final class Row {
        let root = Grid()
        private let tile = Border()
        private let tileIcon = FontIcon()
        private let picture = WinUI.Image()
        private let name = TextBlock()
        private let subtitle = TextBlock()
        private var path: String?
        /// Kept here: a WinRT object built from Swift is only a wrapper, so a weak capture of it
        /// is nil once nothing in Swift holds it, however long XAML keeps the control.
        private let menu = MenuFlyout()

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
            picture.width = DownloadThumbnails.tile
            picture.height = DownloadThumbnails.tile
            picture.stretch = .uniform
            picture.margin = tile.margin
            picture.horizontalAlignment = .left
            picture.visibility = .collapsed
            name.fontSize = 14
            name.textTrimming = .characterEllipsis
            subtitle.fontSize = 12
            subtitle.textTrimming = .characterEllipsis
            let text = StackPanel()
            text.verticalAlignment = .center
            text.children.append(name)
            text.children.append(subtitle)
            root.children.append(tile)
            root.children.append(picture)
            root.children.append(text)
            try? Grid.setColumn(text, 1)
            root.tapped.addHandler { [weak self] _, args in
                guard let self, let path = self.path else { return }
                args?.handled = true
                Shell.open(path)
            }
            menu.items.append(UI.menuItem("Open") { [weak self] in self?.path.map(Shell.open) })
            menu.items.append(UI.menuItem("Show in Folder") { [weak self] in self?.path.map(Shell.showInFolder) })
            menu.opening.addHandler { [weak self] _, _ in
                // Running, failed and cancelled downloads have no file to open yet.
                guard let self, self.path == nil else { return }
                try? self.menu.hide()
            }
            root.contextFlyout = menu
        }

        func apply(_ palette: SidebarPalette) {
            name.foreground = palette.text
            subtitle.foreground = palette.secondaryText
        }

        func show(_ item: DownloadHistory.Listed, now: Date, thumbnails: DownloadThumbnails) {
            if name.text != item.name { name.text = item.name }
            // A finished file's preview or icon; a running one shows its type's icon, as on the Mac.
            let image: WriteableBitmap?
            switch item {
            case .finished(let entry): image = thumbnails.thumbnail(for: entry.path)
            case .live(let live): image = thumbnails.typeIcon(for: live.name)
            }
            if let image {
                picture.source = image
                picture.visibility = .visible
                tile.visibility = .collapsed
            } else {
                picture.visibility = .collapsed
                tile.visibility = .visible
            }
            let line = item.subtitle(now: now)
            if subtitle.text != line { subtitle.text = line }
            if case .finished(let entry) = item { path = entry.path } else { path = nil }
        }
    }
}

/// The downloads list's pictures (the Mac's DownloadThumbnails with Quick Look): Explorer's
/// preview of each file, else its icon, cropped to a square with 6 DIP corners, made off the UI
/// thread on first use.
@MainActor
@Observable
final class DownloadThumbnails {
    /// The tile's side in DIPs (DownloadsTrayMetrics.thumbnail).
    static let tile = 40.0
    /// Pixels asked for: the tile at up to 240 % scaling.
    private static let side = 96

    /// Bumped as pictures arrive.
    private(set) var revision = 0
    @ObservationIgnored private var images: [String: WriteableBitmap] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private let dispatcher: WinAppSDK.DispatcherQueue

    init(dispatcher: WinAppSDK.DispatcherQueue) {
        self.dispatcher = dispatcher
    }

    func thumbnail(for path: String) -> WriteableBitmap? { image(key: path, file: path) }

    /// The icon Explorer shows for files with this name's extension.
    func typeIcon(for name: String) -> WriteableBitmap? {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        // A path that doesn't exist: the bridge falls back to the type's icon.
        return image(key: "type:" + ext, file: "cra-download." + (ext.isEmpty ? "bin" : ext))
    }

    private func image(key: String, file: String) -> WriteableBitmap? {
        if let image = images[key] { return image }
        guard !file.isEmpty, loading.insert(key).inserted else { return nil }
        let side = Self.side, tile = Self.tile
        let queue = UncheckedSendable(value: dispatcher)
        let arrived: @MainActor (Pixels?) -> Void = { [weak self] pixels in
            guard let self else { return }
            if let image = pixels?.bitmap() {
                self.images[key] = image
                self.revision += 1
            }
            // A miss stays in `loading`: it isn't asked for again.
        }
        let done = UncheckedSendable(value: arrived)
        DispatchQueue.global(qos: .utility).async {
            let pixels = Pixels.file(file, side: side).map { picture in
                let square = picture.squareCrop()
                return square.rounded(radius: Double(square.width) * 6 / tile)
            }
            _ = try? queue.value.tryEnqueue { onMain { done.value(pixels) } }
        }
        return nil
    }
}

/// Opening files the way Explorer does.
enum Shell {
    static func open(_ path: String) { run("open", path, nil) }

    /// An Explorer window on the file's folder, the file selected (explorer /select didn't
    /// select it in a window already open on the folder).
    static func showInFolder(_ path: String) { cra_shell_show_in_folder(path) }

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
