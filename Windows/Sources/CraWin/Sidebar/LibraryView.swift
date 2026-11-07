import CraCore
import Foundation
import UWP
import WinAppSDK
import WinSDK
import WinUI

/// What the Library asks of its window.
@MainActor
protocol LibraryActions: AnyObject {
    func showLibrary(_ page: LibraryPage)
    func closeLibrary()
    /// The tab back where it was closed from, selected, and the Library closes (the Mac's
    /// sidebarActions.restoreArchived).
    func restoreArchived(_ id: UUID)
}

/// Arc's Library as a mode of the sidebar (the Mac's LibraryView): the page rail on the left,
/// the page's search and its list by day on the right, the back arrow at the bottom of the rail.
/// The window widens the sidebar by LibraryLayout.extraWidth for it. Arc leaves it by the
/// shortcut, Escape or the arrow, and opens it again on the page last shown.
@MainActor
final class LibraryView {
    /// Windows has no Spaces page yet (the Mac's SpacesManagerView): its rail lists the others.
    static let pages: [LibraryPage] = LibraryPage.allCases.filter { $0 != .spaces }

    let root = Grid()
    private(set) var page: LibraryPage = .downloads
    private let store: SidebarStore
    private let history: DownloadHistory
    private let thumbnails: DownloadThumbnails
    private let favicons: Favicons
    private weak var actions: LibraryActions?

    private let rail = Border()
    private var railButtons: [(page: LibraryPage, button: Button, glyph: FontIcon, label: TextBlock)] = []
    private let backGlyph = FontIcon()
    private var back: Button!
    private let searchBox = Border()
    private let searchGlyph = FontIcon()
    private let search = TextBox()
    private let menuGlyph = FontIcon()
    private var menuButton: Button!
    /// The ⋯ button's menu, filled as it opens.
    private let pageMenu = MenuFlyout()
    private let rows = StackPanel()
    private let scroll = ScrollViewer()
    private let empty = StackPanel()
    private let emptyGlyph = FontIcon()
    private let emptyTitle = TextBlock()
    private let emptyDetail = TextBlock()
    private var palette = SidebarPalette(SpaceTheme.presets[0])
    private var query = ""
    /// What the rows were last built from: a store change that leaves it alone (a page's title)
    /// doesn't build them again.
    private var builtFrom: Int?

    init(store: SidebarStore, history: DownloadHistory, dispatcher: WinAppSDK.DispatcherQueue, favicons: Favicons = .shared,
         actions: LibraryActions) {
        self.store = store
        self.history = history
        self.favicons = favicons
        self.actions = actions
        thumbnails = DownloadThumbnails(dispatcher: dispatcher)
        root.columnDefinitions.append(UI.column(UI.pixels(LibraryLayout.rail)))
        root.columnDefinitions.append(UI.column(UI.star))
        makeRail()
        makeList()
        root.keyDown.addHandler { [weak self] _, args in
            guard let self, let args, !args.handled, Int32(truncatingIfNeeded: args.key.rawValue) == 0x1B else { return }
            args.handled = true
            self.actions?.closeLibrary()
        }
    }

    /// The page to show (its search starts empty).
    func show(_ page: LibraryPage) {
        guard page != self.page else { return }
        self.page = page
        query = ""
        search.text = ""
        search.placeholderText = page.searchPrompt
        builtFrom = nil
    }

    /// The search takes the keyboard (the window has moved Win32 focus into the XAML first).
    func focusSearch() {
        _ = try? search.focus(.programmatic)
    }

    /// Draws the page for the focused space's colours. Everything it reads from the store and
    /// the downloads is what a change redraws (BrowserWindow.refresh).
    func build(_ palette: SidebarPalette, dark: Bool) {
        let archive = store.archive
        let entries = history.entries
        let revision = thumbnails.revision
        var key = Hasher()
        key.combine(page)
        key.combine(query)
        key.combine(dark)
        key.combine(revision)
        key.combine(archive.map(\.id))
        key.combine(archive.map(\.item.displayTitle))
        key.combine(entries.map(\.id))
        key.combine(Calendar.current.startOfDay(for: Date()))
        let built = key.finalize()
        self.palette = palette
        root.requestedTheme = dark ? .dark : .light
        applyColors(dark: dark)
        guard built != builtFrom else { return }
        builtFrom = built
        rows.children.clear()
        switch page {
        case .downloads:
            let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
            let sections = LibraryList.downloads(entries, matching: query, exists: exists)
            for section in sections {
                addHeader(section.title)
                for entry in section.items { addDownload(entry) }
            }
            showEmpty(sections.isEmpty, LibraryList.empty(.downloads, hasAny: entries.contains { exists($0.path) }))
        case .archive:
            let sections = LibraryList.archive(archive, matching: query)
            for section in sections {
                addHeader(section.title)
                for item in section.items { addArchived(item) }
            }
            showEmpty(sections.isEmpty, LibraryList.empty(.archive, hasAny: !archive.isEmpty))
        case .spaces:
            showEmpty(true, LibraryList.Empty(symbol: page.symbol, title: "Not on Windows yet", detail: nil))
        }
    }

    // MARK: Rail

    private func makeRail() {
        let column = Grid()
        for height in [UI.star, UI.auto, UI.star, UI.auto] { column.rowDefinitions.append(UI.row(height)) }
        let group = StackPanel()
        group.spacing = 20
        group.horizontalAlignment = .center
        for page in Self.pages {
            let glyph = FontIcon()
            glyph.glyph = WinGlyph.code(page.symbol)
            glyph.fontSize = 17
            let label = UI.text(page.title, size: 12, trimmed: false)
            label.fontWeight = UWP.FontWeight(weight: 600)
            label.textAlignment = .center
            label.textWrapping = .wrap
            let stack = StackPanel()
            stack.spacing = 9
            stack.horizontalAlignment = .center
            stack.verticalAlignment = .center
            stack.children.append(glyph)
            stack.children.append(label)
            let button = UI.button(stack, padding: Thickness(left: 4, top: 4, right: 4, bottom: 4)) { [weak self] in
                self?.actions?.showLibrary(page)
            }
            button.width = 97
            button.height = 80
            button.cornerRadius = CornerRadius(topLeft: 12, topRight: 12, bottomRight: 12, bottomLeft: 12)
            try? AutomationProperties.setName(button, page.title)
            group.children.append(button)
            railButtons.append((page, button, glyph, label))
        }
        column.children.append(group)
        try? Grid.setRow(group, 1)

        backGlyph.glyph = WinGlyph.code("arrow.left")
        backGlyph.fontSize = 15
        back = UI.button(backGlyph, padding: Thickness(left: 8, top: 8, right: 8, bottom: 8)) { [weak self] in
            self?.actions?.closeLibrary()
        }
        back.horizontalAlignment = .left
        back.margin = Thickness(left: 8, top: 0, right: 0, bottom: 8)
        try? ToolTipService.setToolTip(back, "Exit the Library (Esc)")
        try? AutomationProperties.setName(back, "Exit the Library")
        column.children.append(back)
        try? Grid.setRow(back, 3)

        rail.child = column
        rail.borderThickness = Thickness(left: 0, top: 0, right: 1, bottom: 0)
        root.children.append(rail)
    }

    // MARK: List

    private func makeList() {
        let column = Grid()
        column.rowDefinitions.append(UI.row(UI.auto))
        column.rowDefinitions.append(UI.row(UI.star))

        // The search field and the ⋯ button, 10 DIPs down (Arc's HStack(spacing: 4)).
        let top = Grid()
        top.columnDefinitions.append(UI.column(UI.star))
        top.columnDefinitions.append(UI.column(UI.pixels(36)))
        top.columnSpacing = 4
        top.margin = Thickness(left: 7, top: 10, right: 8, bottom: 0)
        searchGlyph.glyph = WinGlyph.code("magnifyingglass")
        searchGlyph.fontSize = 13
        searchGlyph.margin = Thickness(left: 12, top: 0, right: 0, bottom: 0)
        searchGlyph.verticalAlignment = .center
        search.fontSize = 14
        search.placeholderText = page.searchPrompt
        search.verticalAlignment = .center
        search.minHeight = 0
        search.padding = Thickness(left: 6, top: 6, right: 8, bottom: 6)
        search.borderThickness = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        search.background = UI.clear
        search.isSpellCheckEnabled = false
        search.isTextPredictionEnabled = false
        for key in ["TextControlBackgroundFocused", "TextControlBackgroundPointerOver", "TextControlBorderBrushFocused",
                    "TextControlBorderBrushPointerOver", "TextControlBackground", "TextControlBorderBrush"] {
            _ = search.resources.insert(key, UI.clear)
        }
        search.textChanged.addHandler { [weak self] _, _ in
            guard let self, self.search.text != self.query else { return }
            self.query = self.search.text
            self.build(self.palette, dark: self.palette.isDark)
        }
        search.previewKeyDown.addHandler { [weak self] _, args in
            guard let self, let args, Int32(truncatingIfNeeded: args.key.rawValue) == 0x1B else { return }
            args.handled = true
            self.actions?.closeLibrary()
        }
        let field = Grid()
        field.columnDefinitions.append(UI.column(UI.auto))
        field.columnDefinitions.append(UI.column(UI.star))
        field.children.append(searchGlyph)
        field.children.append(search)
        try? Grid.setColumn(search, 1)
        searchBox.child = field
        searchBox.height = 36
        searchBox.cornerRadius = CornerRadius(topLeft: 12, topRight: 12, bottomRight: 12, bottomLeft: 12)
        top.children.append(searchBox)

        menuGlyph.glyph = WinGlyph.code("ellipsis")
        menuGlyph.fontSize = 14
        menuButton = UI.button(menuGlyph, padding: Thickness(left: 0, top: 0, right: 0, bottom: 0)) {}
        menuButton.flyout = pageMenu
        pageMenu.opening.addHandler { [weak self] _, _ in self?.fillMenu() }
        menuButton.width = 36
        menuButton.height = 36
        menuButton.cornerRadius = CornerRadius(topLeft: 12, topRight: 12, bottomRight: 12, bottomLeft: 12)
        try? AutomationProperties.setName(menuButton, "More")
        top.children.append(menuButton)
        try? Grid.setColumn(menuButton, 1)
        column.children.append(top)

        rows.orientation = .vertical
        rows.padding = Thickness(left: 0, top: 0, right: 0, bottom: 12)
        scroll.content = rows
        column.children.append(scroll)
        try? Grid.setRow(scroll, 1)

        // 260 DIPs down from the top (46 under the search row): the glyph, the title, the detail.
        emptyGlyph.fontSize = 30
        emptyTitle.fontSize = 17
        emptyTitle.fontWeight = UWP.FontWeight(weight: 600)
        emptyTitle.textAlignment = .center
        emptyDetail.fontSize = 14
        emptyDetail.textAlignment = .center
        emptyDetail.textWrapping = .wrap
        empty.spacing = 8
        empty.margin = Thickness(left: 16, top: 260 - 46 - 46, right: 16, bottom: 0)
        empty.children.append(emptyGlyph)
        empty.children.append(emptyTitle)
        empty.children.append(emptyDetail)
        column.children.append(empty)
        try? Grid.setRow(empty, 1)

        root.children.append(column)
        try? Grid.setColumn(column, 1)
    }

    private func showEmpty(_ isEmpty: Bool, _ state: LibraryList.Empty) {
        empty.visibility = isEmpty ? .visible : .collapsed
        scroll.visibility = isEmpty ? .collapsed : .visible
        emptyGlyph.glyph = WinGlyph.code(state.symbol)
        emptyTitle.text = state.title
        emptyDetail.text = state.detail ?? ""
        emptyDetail.visibility = state.detail == nil ? .collapsed : .visible
    }

    private func applyColors(dark: Bool) {
        let ink: UInt8 = dark ? 255 : 0
        rail.background = UI.brush(ink, ink, ink, alpha: 8)
        rail.borderBrush = UI.brush(ink, ink, ink, alpha: 23)
        for b in railButtons {
            let selected = b.page == page
            b.button.background = selected ? UI.brush(ink, ink, ink, alpha: 18) : UI.clear
            b.glyph.foreground = selected ? palette.text : palette.secondaryText
            b.label.foreground = UI.brush(ink, ink, ink, alpha: selected ? 209 : 153)
            b.glyph.glyph = WinGlyph.code(selected ? b.page.selectedSymbol : b.page.symbol)
        }
        backGlyph.foreground = palette.secondaryText
        searchBox.background = UI.brush(ink, ink, ink, alpha: 20)
        searchGlyph.foreground = UI.brush(ink, ink, ink, alpha: 128)
        search.foreground = palette.text
        menuButton.background = UI.brush(ink, ink, ink, alpha: 13)
        menuGlyph.foreground = UI.brush(ink, ink, ink, alpha: 179)
        emptyGlyph.foreground = UI.brush(ink, ink, ink, alpha: 115)
        emptyTitle.foreground = UI.brush(ink, ink, ink, alpha: 230)
        emptyDetail.foreground = UI.brush(ink, ink, ink, alpha: 179)
    }

    /// The ⋯ button's menu (Arc's Filter button; Cra's holds the page's actions).
    private func fillMenu() {
        pageMenu.items.clear()
        switch page {
        case .downloads:
            pageMenu.items.append(UI.menuItem("Open Downloads Folder") { Shell.openDownloadsFolder() })
        case .archive:
            let clear = UI.menuItem("Clear Archive") { [weak self] in self?.store.clearArchive() }
            clear.isEnabled = !store.archive.isEmpty
            pageMenu.items.append(clear)
        case .spaces:
            break
        }
    }

    // MARK: Rows

    private func addHeader(_ title: String) {
        let label = UI.text(title, size: 13, color: palette.secondaryText)
        label.fontWeight = UWP.FontWeight(weight: 600)
        // 11 DIPs in, 18 above, 6 below: a 40 DIP header.
        label.margin = Thickness(left: 11, top: 18, right: 8, bottom: 6)
        rows.children.append(label)
    }

    private func addArchived(_ entry: ArchivedItem) {
        let id = entry.id
        let url = entry.item.tab?.url ?? ""
        let tile = Border()
        tile.width = 24
        tile.height = 24
        tile.cornerRadius = CornerRadius(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6)
        tile.background = palette.tile
        if let bitmap = favicons.bitmap(forKey: entry.item.tab?.iconKey, onDark: palette.isDark) {
            let image = UI.image(bitmap, size: 16)
            image.horizontalAlignment = .center
            image.verticalAlignment = .center
            tile.child = image
        }
        let menu = MenuFlyout()
        menu.items.append(UI.menuItem("Restore") { [weak self] in self?.actions?.restoreArchived(id) })
        menu.items.append(UI.menuItem("Copy Link") { _ = WinShell.copy(url) })
        menu.items.append(MenuFlyoutSeparator())
        menu.items.append(UI.menuItem("Remove from Archive") { [weak self] in self?.store.removeFromArchive(id) })
        let row = addRow(tile: tile, tileInset: 9, title: entry.item.displayTitle,
                         detail: SuggestionEngine.humanURL(url), menu: menu) { [weak self] in
            self?.actions?.restoreArchived(id)
        }
        if !url.isEmpty { try? ToolTipService.setToolTip(row, url) }
    }

    private func addDownload(_ entry: DownloadHistory.Entry) {
        let path = entry.path
        let tile: FrameworkElement
        if let picture = thumbnails.thumbnail(for: path) {
            tile = UI.image(picture, size: 32)
        } else {
            let box = Border()
            box.width = 32
            box.height = 32
            box.cornerRadius = CornerRadius(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6)
            box.background = palette.tile
            tile = box
        }
        let menu = MenuFlyout()
        menu.items.append(UI.menuItem("Open") { Shell.open(path) })
        menu.items.append(UI.menuItem("Show in Folder") { Shell.showInFolder(path) })
        addRow(tile: tile, tileInset: 5, title: LibraryList.fileName(path),
               detail: DownloadHistory.Listed.finished(entry).subtitle(now: Date()), menu: menu) {
            Shell.open(path)
        }
    }

    /// A 52 DIP card inside 4 × 2 DIPs of padding: the tile, then the title over the detail; the
    /// space's hover fill under the pointer.
    @discardableResult
    private func addRow(tile: FrameworkElement, tileInset: Double, title: String, detail: String, menu: MenuFlyout, _ action: @escaping @MainActor () -> Void) -> Button {
        let content = Grid()
        content.columnDefinitions.append(UI.column(UI.auto))
        content.columnDefinitions.append(UI.column(UI.star))
        content.columnSpacing = 10
        tile.verticalAlignment = .center
        tile.margin = Thickness(left: tileInset, top: 0, right: 0, bottom: 0)
        content.children.append(tile)
        let text = StackPanel()
        text.spacing = 1
        text.verticalAlignment = .center
        text.margin = Thickness(left: 0, top: 0, right: 8, bottom: 0)
        text.children.append(UI.text(title.isEmpty ? "Untitled" : title, size: 14, color: palette.text))
        text.children.append(UI.text(detail, size: 12, color: palette.secondaryText))
        content.children.append(text)
        try? Grid.setColumn(text, 1)
        let row = UI.button(content, padding: Thickness(left: 0, top: 0, right: 0, bottom: 0), action)
        row.height = LibraryLayout.rowHeight - 4
        row.margin = Thickness(left: 4, top: 2, right: 4, bottom: 2)
        row.horizontalAlignment = .stretch
        row.horizontalContentAlignment = .stretch
        row.cornerRadius = CornerRadius(topLeft: 10, topRight: 10, bottomRight: 10, bottomLeft: 10)
        row.contextFlyout = menu
        try? AutomationProperties.setName(row, title)
        rows.children.append(row)
        return row
    }
}
