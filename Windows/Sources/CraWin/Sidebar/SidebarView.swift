import CraCore
import Foundation
import UWP
import WinUI

/// What the sidebar asks of its window: things that touch pages, not only the store.
@MainActor
protocol SidebarActions: AnyObject {
    /// ✕ on a row: Today tabs are archived, pinned tabs and favorites unload (MainWindowController.closeTab).
    func closeTab(_ id: UUID)
    /// "+ New Tab": the command bar, making a new tab.
    func beginNewTab()
    /// A split row's "Add Tab…": an empty pane after its panes, the command bar asking for its page.
    func addPane(toSplit id: UUID)
    /// A pane's "Close": the pane's tab goes and the split keeps the others.
    func closeSplitPane(_ id: UUID)
    /// Set Profile ▸ New Profile…: Create a new Profile, with this space ticked.
    func newProfile(forSpace id: UUID)
}

/// Arc's sidebar on the shared SidebarStore: favorites as tiles, the space's name, its pinned
/// tabs and folders, a New Tab row, its Today tabs, and the spaces along the bottom. Rebuilt
/// from the store on every change it read (BrowserWindow.refresh observes `build`).
@MainActor
final class SidebarView {
    let root = Grid()
    private let favorites = Grid()
    private let header = Grid()
    private let list = StackPanel()
    private let spacesBar = StackPanel()
    /// The downloads button on the left (Arc's Library button) over the same cell as the spaces,
    /// so they stay centred whatever the button shows.
    private let footer = Grid()
    private let store: SidebarStore
    /// The window it draws: its space, its selected tab (SidebarStore.WindowSession).
    private let windowID: UUID
    private let favicons: Favicons
    private weak var actions: SidebarActions?
    private var palette = SidebarPalette(SpaceTheme.presets[0])
    /// Controls a handler reaches weakly: a WinRT control made in Swift is only a wrapper, freed
    /// (and its weak references nil) once Swift lets go of it, however long XAML shows it.
    private var kept: [AnyObject] = []
    /// Arc badges the tab a Peek came from with the peeked page's favicon (modalIcon), at the
    /// row's end. Set by the browser window, which builds the sidebar again.
    var peekBadge: (tabID: UUID, iconKey: String?)?

    /// Emoji a new space picks from, in turn.
    private static let spaceEmoji = ["🌱", "💼", "🎮", "📚", "🎨", "🏠", "✈️", "🧪"]
    private static let favoritesPerRow = 4

    init(store: SidebarStore, windowID: UUID, actions: SidebarActions, favicons: Favicons = .shared) {
        self.store = store
        self.windowID = windowID
        self.favicons = favicons
        self.actions = actions
        for height in [UI.auto, UI.auto, UI.star, UI.auto] { root.rowDefinitions.append(UI.row(height)) }
        favorites.margin = Thickness(left: 0, top: 0, right: 0, bottom: 8)
        favorites.columnSpacing = 6
        favorites.rowSpacing = 6
        header.margin = Thickness(left: 0, top: 4, right: 0, bottom: 4)
        list.orientation = .vertical
        list.spacing = 1
        let scroll = ScrollViewer()
        scroll.content = list
        spacesBar.orientation = .horizontal
        spacesBar.spacing = 2
        spacesBar.horizontalAlignment = .center
        footer.margin = Thickness(left: 0, top: 8, right: 0, bottom: 0)
        footer.children.append(spacesBar)
        let parts: [FrameworkElement] = [favorites, header, scroll, footer]
        for (i, part) in parts.enumerated() {
            root.children.append(part)
            try? Grid.setRow(part, Int32(i))
        }
    }

    /// Draws the focused space. Everything it reads from the store is what a change redraws.
    func build() {
        let space = store.focusedSpace(window: windowID)
        palette = SidebarPalette(space.theme)
        kept = []
        buildFavorites(space)
        buildHeader(space)
        list.children.clear()
        for item in store.listedPinnedItems(in: space, window: windowID) { addRow(item, depth: 0) }
        addDivider()
        // Settings ▸ Tabs ▸ "Show the New Tab button above tabs": else it follows Today's last tab.
        let newTabAtTop = store.settings.newTabButtonAtTop
        if newTabAtTop { addNewTabRow(space) }
        for item in store.children(of: space.todayContainerID) { addRow(item, depth: 0) }
        if !newTabAtTop { addNewTabRow(space) }
        buildSpacesBar(space)
    }

    /// The downloads button goes in the footer, its list over the bottom of the tab list.
    func attachDownloads(button: FrameworkElement, list tray: FrameworkElement) {
        footer.children.append(button)
        root.children.append(tray)
        try? Grid.setRow(tray, 2)
    }

    var fill: Brush { palette.fill }
    var isDark: Bool { store.focusedSpace(window: windowID).theme.isDark }
    var textColor: Brush { palette.text }
    var secondaryTextColor: Brush { palette.secondaryText }

    // MARK: Favorites

    private func buildFavorites(_ space: Space) {
        favorites.children.clear()
        favorites.columnDefinitions.clear()
        favorites.rowDefinitions.clear()
        let items = store.children(of: space.favoritesContainerID).filter { $0.isTab || $0.isSplit }
        favorites.visibility = items.isEmpty ? .collapsed : .visible
        guard !items.isEmpty else { return }
        let perRow = Self.favoritesPerRow
        for _ in 0..<perRow { favorites.columnDefinitions.append(UI.column(UI.star)) }
        for _ in 0..<((items.count + perRow - 1) / perRow) { favorites.rowDefinitions.append(UI.row(UI.pixels(44))) }
        let open = store.selectedTabID(window: windowID).map { store.splitContaining($0)?.id ?? $0 }
        for (i, item) in items.enumerated() {
            let label = tileIcon(item)
            label.horizontalAlignment = .center
            let tile = UI.button(label, fill: item.id == open ? palette.selected : palette.tile) { [weak self] in
                self?.select(item.id)
            }
            tile.horizontalAlignment = .stretch
            tile.verticalAlignment = .stretch
            tile.contextFlyout = tabMenu(item)
            try? ToolTipService.setToolTip(tile, item.displayTitle)
            favorites.children.append(tile)
            try? Grid.setRow(tile, Int32(i / perRow))
            try? Grid.setColumn(tile, Int32(i % perRow))
        }
    }

    /// A tile's favicon at 20 DIPs (FavoriteTileView), or its site's first letter until the
    /// icon has loaded. A split's tile shows its first tab's.
    private func tileIcon(_ item: SidebarItem) -> FrameworkElement {
        let tab = item.isSplit ? store.children(of: item.id).first?.tab : item.tab
        if let bitmap = favicons.bitmap(forKey: tab?.iconKey, onDark: palette.isDark) {
            return UI.image(bitmap, size: 20)
        }
        return UI.text(Self.tileLabel(item), size: 15, color: palette.text, trimmed: false)
    }

    private static func tileLabel(_ item: SidebarItem) -> String {
        let name = item.tab.flatMap { URL(string: $0.url)?.host }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            ?? item.displayTitle
        return name.first.map { String($0).uppercased() } ?? "•"
    }

    // MARK: Header

    private func buildHeader(_ space: Space) {
        header.children.clear()
        // Arc's single-space mode (Settings ▸ Tabs ▸ Spaces, or the space's menu).
        header.visibility = store.hidesSpaceHeader(space.id) ? .collapsed : .visible
        let name = UI.text("\(space.emoji) \(space.title)".trimmingCharacters(in: .whitespaces), size: 14, color: palette.text)
        // Arc: clicking the space's name folds its pinned tabs away.
        let title = UI.button(name, padding: Thickness(left: 6, top: 4, right: 6, bottom: 4)) { [weak self] in
            guard let self else { return }
            self.store.togglePinnedCollapsed(self.store.focusedSpaceID(window: self.windowID))
        }
        title.horizontalAlignment = .stretch
        title.horizontalContentAlignment = .left
        title.contextFlyout = spaceMenu(space)
        header.children.append(title)
    }

    // MARK: Rows

    private func addRow(_ item: SidebarItem, depth: Int) {
        if item.isFolder {
            addFolderRow(item, depth: depth)
        } else if item.isSplit {
            let titles = store.children(of: item.id).map(\.displayTitle).joined(separator: " | ")
            let selected = store.selectedTabID(window: windowID).map { store.splitContaining($0)?.id == item.id } ?? false
            // A click opens the split on the pane last focused in it (Arc: focusItemID).
            let panes = store.paneTabIDs(for: item.children.first ?? item.id)
            let focus = item.split?.focusTabID.flatMap { panes.contains($0) ? $0 : nil } ?? panes.first
            appendRow(icon: .text("⧉"), title: titles, depth: depth, selected: selected, unread: false, closable: nil,
                      menu: splitMenu(item, open: selected)) { [weak self] in
                if let focus { self?.select(focus) }
            }
        } else if item.isTab {
            let closable = item.id
            let selected = store.isSelected(item.id, window: windowID)
            // A site in Developer Mode: its host and port under the title, a ring round the open tab.
            let developer = item.tab.map { store.settings.isDeveloperMode(url: $0.url) } ?? false
            appendRow(icon: .favicon(item.tab?.iconKey), title: item.displayTitle, subtitle: item.tab?.sidebarSubtitle(developerMode: developer),
                      depth: depth, selected: selected, ring: developer && selected, unread: item.isUnread, closable: closable,
                      peek: peekBadge?.tabID == item.id ? .favicon(peekBadge?.iconKey) : nil, menu: tabMenu(item)) { [weak self] in
                self?.select(item.id)
            }
        }
    }

    private func addFolderRow(_ folder: SidebarItem, depth: Int) {
        let open = store.isExpanded(folder.id)
        let menu = MenuFlyout()
        menu.items.append(UI.menuItem(open ? "Collapse" : "Expand") { [weak self] in self?.store.setExpanded(folder.id, !open) })
        if !folder.isLiveFolder {
            menu.items.append(UI.menuItem("New Folder Inside") { [weak self] in
                guard let self else { return }
                self.store.createFolder(named: "New Folder", in: folder.id)
            })
        }
        menu.items.append(MenuFlyoutSeparator())
        menu.items.append(UI.menuItem("Delete Folder") { [weak self] in self?.store.deleteFolder(folder.id) })
        appendRow(icon: .text(open ? "▾" : "▸"), title: folder.displayTitle, depth: depth, selected: false, unread: false, closable: nil,
                  menu: menu) { [weak self] in
            self?.store.setExpanded(folder.id, !open)
        }
        guard open else { return }
        let children = store.children(of: folder.id)
        if children.isEmpty {
            let empty = UI.text("Empty", size: 12, color: palette.secondaryText)
            empty.margin = Thickness(left: Double(depth + 1) * 16 + 10, top: 2, right: 0, bottom: 4)
            list.children.append(empty)
        }
        for child in children { addRow(child, depth: depth + 1) }
    }

    /// What leads a row: a tab's favicon (a globe until it loads), or a mark for folders and splits.
    private enum RowIcon {
        case favicon(String?)
        case text(String)
    }

    private func rowIcon(_ icon: RowIcon) -> FrameworkElement {
        switch icon {
        case .text(let mark):
            return UI.text(mark, color: palette.secondaryText, trimmed: false)
        case .favicon(let key):
            if let bitmap = favicons.bitmap(forKey: key, onDark: palette.isDark) { return UI.image(bitmap, size: 16) }
            // FaviconView's fallback: a globe in the tertiary text colour.
            let globe = FontIcon()
            globe.glyph = WinGlyph.code("globe")
            globe.fontSize = 13
            globe.width = 16
            globe.foreground = palette.secondaryText
            return globe
        }
    }

    private func appendRow(icon: RowIcon, title: String, subtitle: String? = nil, depth: Int, selected: Bool, ring: Bool = false,
                           unread: Bool, closable: UUID?, peek: RowIcon? = nil, menu: MenuFlyout?,
                           _ action: @escaping @MainActor () -> Void) {
        let row = Grid()
        row.columnDefinitions.append(UI.column(UI.star))
        row.columnDefinitions.append(UI.column(UI.auto))
        row.margin = Thickness(left: Double(depth) * 16, top: 0, right: 0, bottom: 0)

        let label = StackPanel()
        label.orientation = .horizontal
        label.spacing = 8
        let lead = rowIcon(icon)
        lead.verticalAlignment = .center
        label.children.append(lead)
        let name = UI.text(title.isEmpty ? "New Tab" : title, color: palette.text)
        if unread { name.fontWeight = UWP.FontWeight(weight: 600) }
        if let subtitle {
            let lines = StackPanel()
            lines.orientation = .vertical
            lines.verticalAlignment = .center
            lines.children.append(name)
            lines.children.append(UI.text(subtitle, size: 11, color: palette.secondaryText))
            label.children.append(lines)
        } else {
            label.children.append(name)
        }

        // The Peek's badge sits at the end of the row's own pill (Arc's modalIcon).
        var content: FrameworkElement = label
        if let peek {
            let inside = Grid()
            inside.columnDefinitions.append(UI.column(UI.star))
            inside.columnDefinitions.append(UI.column(UI.auto))
            inside.children.append(label)
            let badge = rowIcon(peek)
            badge.verticalAlignment = .center
            badge.margin = Thickness(left: 6, top: 0, right: 0, bottom: 0)
            try? AutomationProperties.setName(badge, "Peek")
            inside.children.append(badge)
            try? Grid.setColumn(badge, 1)
            content = inside
        }
        let pick = UI.button(content, fill: selected ? palette.selected : nil, action)
        pick.horizontalAlignment = .stretch
        pick.horizontalContentAlignment = peek == nil ? .left : .stretch
        if let menu { pick.contextFlyout = menu }
        row.children.append(pick)
        try? Grid.setColumn(pick, 0)

        if let id = closable {
            let close = UI.button("✕", color: palette.secondaryText) { [weak self] in self?.actions?.closeTab(id) }
            row.children.append(close)
            try? Grid.setColumn(close, 1)
        }
        if ring { addDeveloperRing(to: row) }
        list.children.append(row)
    }

    /// Arc's ring round a Developer Mode site's open tab (CraCore's DeveloperTabRing): yellow
    /// under black dashes at 80 %, the dashes cut to the row's size.
    private func addDeveloperRing(to row: Grid) {
        let yellow = WinUI.Rectangle(), dashes = WinUI.Rectangle()  // not GDI's Rectangle
        yellow.stroke = UI.brush(255, 204, 0)
        dashes.stroke = UI.brush(0, 0, 0, alpha: UInt8((DeveloperTabRing.dashAlpha * 255).rounded()))
        kept += [yellow, dashes]
        for ring in [yellow, dashes] {
            ring.strokeThickness = DeveloperTabRing.lineWidth
            ring.isHitTestVisible = false
            row.children.append(ring)
            try? Grid.setColumnSpan(ring, 2)
        }
        dashes.sizeChanged.addHandler { [weak yellow, weak dashes] _, _ in
            guard let yellow, let dashes else { return }
            // The stroke sits inside the shape, so its middle runs 1 DIP in, as the Mac's path does.
            let w = dashes.actualWidth - DeveloperTabRing.lineWidth, h = dashes.actualHeight - DeveloperTabRing.lineWidth
            let r = DeveloperTabRing.cornerRadius(width: w, height: h)
            for ring in [yellow, dashes] {
                ring.radiusX = r
                ring.radiusY = r
            }
            // XAML counts dashes in stroke widths.
            let d = DeveloperTabRing.dash(width: w, height: h) / DeveloperTabRing.lineWidth
            let pattern = DoubleCollection()
            pattern.append(d)
            pattern.append(d)
            dashes.strokeDashArray = pattern
        }
    }

    /// The line between the pinned tabs and Today.
    private func addDivider() {
        let line = Border()
        line.height = 1
        line.background = palette.tile
        line.margin = Thickness(left: 4, top: 6, right: 4, bottom: 6)
        list.children.append(line)
    }

    private func addNewTabRow(_ space: Space) {
        let row = Grid()
        row.columnDefinitions.append(UI.column(UI.star))
        row.columnDefinitions.append(UI.column(UI.auto))
        let add = UI.button(UI.text("+  New Tab", color: palette.secondaryText)) { [weak self] in self?.actions?.beginNewTab() }
        add.horizontalAlignment = .stretch
        add.horizontalContentAlignment = .left
        row.children.append(add)
        try? Grid.setColumn(add, 0)
        if !store.children(of: space.todayContainerID).isEmpty {
            // Arc's "Clear": every Today tab goes to the archive.
            let clear = UI.button("Clear", color: palette.secondaryText) { [weak self] in self?.store.clearToday() }
            row.children.append(clear)
            try? Grid.setColumn(clear, 1)
        }
        list.children.append(row)
    }

    private func select(_ id: UUID) {
        store.selectTab(id, window: windowID)
    }

    // MARK: Menus

    private func tabMenu(_ item: SidebarItem) -> MenuFlyout {
        let id = item.id
        let menu = MenuFlyout()
        let favorite = store.isFavorite(id), pinned = store.isPinned(id)
        if favorite {
            menu.items.append(UI.menuItem("Remove from Favorites") { [weak self] in self?.store.removeFromFavorites(id) })
        } else {
            menu.items.append(UI.menuItem("Add to Favorites") { [weak self] in self?.store.addToFavorites(id) })
            menu.items.append(UI.menuItem(pinned ? "Unpin" : "Pin") { [weak self] in self?.store.togglePinned(id) })
        }
        if item.isTab {
            menu.items.append(UI.menuItem("Duplicate") { [weak self] in _ = self?.store.duplicateTab(id) })
        }
        // An incognito window's tabs stay in it.
        let others = store.isIncognito(item: id) ? [] : store.orderedSpaces.filter { $0.id != store.spaceID(ofItem: id) }
        if !others.isEmpty {
            let move = MenuFlyoutSubItem()
            move.text = "Move to Space"
            for space in others {
                move.items.append(UI.menuItem("\(space.emoji) \(space.title)") { [weak self] in self?.store.moveTab(id, toSpace: space.id) })
            }
            menu.items.append(move)
        }
        menu.items.append(MenuFlyoutSeparator())
        menu.items.append(UI.menuItem(pinned ? "Close (Unload)" : "Close Tab") { [weak self] in self?.actions?.closeTab(id) })
        return menu
    }

    /// Arc 1.171's split menu where the Windows app has the feature (SidebarMenus.split on the Mac).
    private func splitMenu(_ split: SidebarItem, open: Bool) -> MenuFlyout {
        let id = split.id
        let menu = MenuFlyout()
        let panes = store.children(of: id).filter(\.isTab)
        menu.items.append(UI.menuItem("Separate All Tabs") { [weak self] in self?.store.separateAll(id) })
        // Arc greys it out while the split is closed (no pane to add next to).
        let add = UI.menuItem("Add Tab…") { [weak self] in self?.actions?.addPane(toSplit: id) }
        add.isEnabled = open && panes.count < SplitPaneLayout.Constants.maximumPanes
        menu.items.append(add)
        let vertical = split.split?.orientation == .vertical
        menu.items.append(UI.menuItem(vertical ? "Convert to Horizontal Split View" : "Convert to Vertical Split View") { [weak self] in
            self?.store.flipSplitOrientation(id)
        })
        menu.items.append(MenuFlyoutSeparator())
        for pane in panes {
            let options = MenuFlyoutSubItem()
            options.text = pane.displayTitle
            let paneID = pane.id
            options.items.append(UI.menuItem("Separate from Split View") { [weak self] in self?.store.separateFromSplit(paneID) })
            options.items.append(UI.menuItem("Close") { [weak self] in self?.actions?.closeSplitPane(paneID) })
            menu.items.append(options)
        }
        menu.items.append(MenuFlyoutSeparator())
        menu.items.append(UI.menuItem("Archive Item") { [weak self] in
            guard let self else { return }
            for pane in panes { self.store.archiveTab(pane.id, reason: .manual) }
        })
        return menu
    }

    private func spaceMenu(_ space: Space) -> MenuFlyout {
        let menu = MenuFlyout()
        menu.items.append(UI.menuItem("New Folder") { [weak self] in
            guard let self else { return }
            self.store.createFolder(named: "New Folder", in: space.pinnedContainerID)
        })
        if !store.isIncognito(space: space.id) {
            menu.items.append(UI.menuItem("New Space") { [weak self] in self?.newSpace() })
        }
        menu.items.append(UI.menuItem("Clear Today") { [weak self] in self?.store.clearToday(space.id) })
        if !store.isIncognito(space: space.id) { menu.items.append(profileMenu(space)) }
        if store.spaceOrder.count == 1 && !store.isIncognito(space: space.id) {
            menu.items.append(UI.menuItem("Hide Space Header") { [weak self] in self?.store.settings.showSpaceHeaderOnSingleSpace = false })
        }
        if store.spaceOrder.count > 1 {
            menu.items.append(MenuFlyoutSeparator())
            menu.items.append(UI.menuItem("Delete Space") { [weak self] in self?.store.deleteSpace(space.id) })
        }
        return menu
    }

    /// Arc's Set Profile: Default, the profiles (the space's ticked), New Profile….
    private func profileMenu(_ space: Space) -> MenuFlyoutSubItem {
        let sub = MenuFlyoutSubItem()
        sub.text = "Set Profile"
        func choice(_ title: String, _ id: UUID?) -> ToggleMenuFlyoutItem {
            let item = ToggleMenuFlyoutItem()
            item.text = title
            item.isChecked = space.profileID == id
            item.click.addHandler { [weak self] _, _ in self?.store.setProfile(id, forSpace: space.id) }
            return item
        }
        sub.items.append(choice("Default", nil))
        for p in store.profiles { sub.items.append(choice(p.name, p.id)) }
        sub.items.append(MenuFlyoutSeparator())
        sub.items.append(UI.menuItem("New Profile…") { [weak self] in self?.actions?.newProfile(forSpace: space.id) })
        return sub
    }

    // MARK: Spaces

    private func buildSpacesBar(_ focused: Space) {
        spacesBar.children.clear()
        // An incognito window pages only its own space (SidebarStore.pagedSpaces).
        for space in store.pagedSpaces(window: windowID) where !store.hidesSpaceHeader(space.id) {
            let mark = UI.text(space.emoji.isEmpty ? String(space.title.prefix(1)) : space.emoji, size: 15, color: palette.text, trimmed: false)
            let dot = UI.button(mark, fill: space.id == focused.id ? palette.selected : nil,
                                padding: Thickness(left: 6, top: 3, right: 6, bottom: 3)) { [weak self] in
                self?.store.focusSpace(space.id, window: self?.windowID)
            }
            try? ToolTipService.setToolTip(dot, space.title)
            dot.contextFlyout = spaceMenu(space)
            spacesBar.children.append(dot)
        }
        guard !store.isIncognito(space: focused.id) else { return }
        let add = UI.button("+", color: palette.secondaryText) { [weak self] in self?.newSpace() }
        try? ToolTipService.setToolTip(add, "New Space")
        spacesBar.children.append(add)
    }

    private func newSpace() {
        let n = store.spaceOrder.count
        // Arc's New Space starts on the profile of the space it was opened from.
        let profile = SpaceProfiles.forNewSpace(from: store.focusedSpace(window: windowID), profiles: store.profiles)
        let space = store.createSpace(title: "Space \(n + 1)", emoji: Self.spaceEmoji[n % Self.spaceEmoji.count])
        if profile != nil { store.setProfile(profile, forSpace: space.id) }
    }
}
