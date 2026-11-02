import CraCEFWin
import CraCore
import Foundation
import Observation
import UWP
import WinAppSDK
import WindowsFoundation
import WinSDK
import WinUI

// WinSDK has a UUID too (the Windows SDK's GUID).
private typealias UUID = Foundation.UUID

/// One browser window on the shared SidebarStore: the toolbar, address box and sidebar on
/// the left, the open tab's page on the right. The Windows counterpart of MainWindowController
/// and BrowserManager, smaller for now: one window, a page made when its tab is first shown and
/// closed when the tab leaves the sidebar or is unloaded.
@MainActor
final class BrowserWindow {
    let store: SidebarStore
    let window = Window()
    private var sidebar: SidebarView!
    private let sidebarPanel = Grid()
    private let content = Border()
    private let address = TextBox()
    private let status = TextBlock()
    private let permissionPanel = StackPanel()
    private let permissionText = TextBlock()
    private let dispatcher: WinAppSDK.DispatcherQueue
    /// The window's HWND: every page is a child window of it.
    private var hwnd: UInt = 0

    /// Pages by tab id.
    private var pages: [UUID: WebPage] = [:]
    private weak var shownPage: WebPage?
    private var shownTabID: UUID?
    /// The address box is taking a new tab's address (Ctrl+T, + New Tab).
    private var newTabPending = false
    private var refreshQueued = false
    /// The window is waiting for Chromium to close its pages; then it closes for good.
    private var closing = false
    private var readyToClose = false
    private var closeTimer: WinAppSDK.DispatcherQueueTimer?
    /// Permission requests waiting for the user, oldest first.
    private var permissionQueue: [(origin: String, kinds: PermissionKinds, answer: (Bool) -> Void)] = []

    private static let sidebarWidth = 280.0
    /// What a new window opens when the sidebar has nothing to show.
    static let startPage = "https://crabrowser.app"

    init(store: SidebarStore, dispatcher: WinAppSDK.DispatcherQueue) {
        self.store = store
        self.dispatcher = dispatcher
        sidebar = SidebarView(store: store, actions: self)
        window.title = "Cra"
        window.content = makeLayout()
        try? window.activate()
        // WinUI's window id is its HWND.
        hwnd = UInt(window.appWindow.id.value)
        content.sizeChanged.addHandler { [weak self] _, _ in self?.layoutPage() }
        // Chromium closes its pages before their parent window goes (CEF's DoClose order).
        window.appWindow.closing.addHandler { [weak self] _, args in
            guard let self, let args, !self.readyToClose, cra_cef_live_browser_count() > 0 else { return }
            args.cancel = true
            self.beginClosing()
        }
        if store.selectedTab == nil && store.visibleTabs(in: store.focusedSpaceID).isEmpty {
            store.createTab(url: Self.startPage)
        }
        refresh()
    }

    // MARK: Store → window

    /// Draws the sidebar and shows the open tab's page, then waits for the next change to
    /// anything they read (the store is Observable).
    private func refresh() {
        refreshQueued = false
        guard !closing else { return }
        withObservationTracking {
            sidebar.build()
            sidebarPanel.background = sidebar.fill
            syncPages()
        } onChange: { [weak self] in
            // Called inside the change, on the main thread: draw once it is done.
            onMain { self?.queueRefresh() }
        }
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        _ = try? dispatcher.tryEnqueue { [weak self] in self?.refresh() }
    }

    private func syncPages() {
        for (id, page) in pages where store.item(id)?.isTab != true {
            page.close()
            pages[id] = nil
        }
        let selected = store.selectedTab
        if let tab = selected?.tab, let id = selected?.id, !tab.url.isEmpty {
            let page = pages[id] ?? makePage(for: id, url: tab.url)
            show(page, tab: id)
        } else {
            show(nil, tab: selected?.id)
        }
        let title = selected?.displayTitle ?? ""
        window.title = title.isEmpty ? "Cra" : "\(title) - Cra"
    }

    private func makePage(for id: UUID, url: String) -> WebPage {
        let page = WebPage(parent: hwnd, frame: contentFrame(), url: url, delegate: self)
        page.userInfo = id
        page.isVisible = false
        pages[id] = page
        return page
    }

    private func show(_ page: WebPage?, tab id: UUID?) {
        let changed = id != shownTabID
        if shownPage !== page {
            shownPage?.isVisible = false
            shownPage = page
            if let page {
                page.frame = contentFrame()
                page.isVisible = true
                page.setFocused(true)
            }
        }
        shownTabID = id
        guard changed, !newTabPending else { return }
        address.text = page.map { _ in store.item(id ?? UUID())?.tab?.url ?? "" } ?? ""
        // An empty tab (a new pane) waits for an address.
        if id != nil && page == nil { focusAddress() }
    }

    /// Closes every page, then the window once Chromium is done with them (or after 3 s).
    private func beginClosing() {
        guard !closing else { return }
        closing = true
        let open = Array(pages.values)
        pages.removeAll()
        shownPage = nil
        for page in open { page.close() }
        closeTimer = try? dispatcher.createTimer()
        closeTimer?.interval = TimeSpan(duration: 3 * 10_000_000)
        closeTimer?.isRepeating = false
        closeTimer?.tick.addHandler { [weak self] _, _ in self?.finishClosing() }
        try? closeTimer?.start()
        if cra_cef_live_browser_count() == 0 { finishClosing() }
    }

    private func finishClosing() {
        guard !readyToClose else { return }
        readyToClose = true
        try? closeTimer?.stop()
        closeTimer = nil
        try? window.close()
    }

    private func tabID(of page: WebPage) -> UUID? { page.userInfo as? UUID }

    // MARK: Layout

    private func makeLayout() -> UIElement {
        let grid = Grid()
        grid.columnDefinitions.append(UI.column(UI.pixels(Self.sidebarWidth)))
        grid.columnDefinitions.append(UI.column(UI.star))

        sidebarPanel.padding = Thickness(left: 10, top: 10, right: 10, bottom: 10)
        for height in [UI.auto, UI.auto, UI.star, UI.auto, UI.auto] { sidebarPanel.rowDefinitions.append(UI.row(height)) }

        let toolbar = StackPanel()
        toolbar.orientation = .horizontal
        toolbar.spacing = 2
        toolbar.children.append(UI.button("\u{2190}") { [weak self] in self?.shownPage?.goBack() })
        toolbar.children.append(UI.button("\u{2192}") { [weak self] in self?.shownPage?.goForward() })
        toolbar.children.append(UI.button("\u{27F3}") { [weak self] in self?.shownPage?.reload() })

        address.placeholderText = "Search or enter address"
        address.margin = Thickness(left: 0, top: 8, right: 0, bottom: 8)
        address.keyDown.addHandler { [weak self] _, args in
            guard let self, let args else { return }
            if args.key == .enter {
                self.go(to: self.address.text)
                args.handled = true
            } else if args.key == .escape {
                self.cancelNewTab()
                args.handled = true
            }
        }
        address.lostFocus.addHandler { [weak self] _, _ in
            guard let self, self.newTabPending, self.address.text.isEmpty else { return }
            self.cancelNewTab()
        }

        permissionPanel.spacing = 4
        permissionPanel.visibility = .collapsed
        permissionText.textWrapping = .wrap
        let answers = StackPanel()
        answers.orientation = .horizontal
        answers.spacing = 4
        let allow = UI.button("Allow") { [weak self] in self?.answerPermission(true) }
        let block = UI.button("Block") { [weak self] in self?.answerPermission(false) }
        allow.background = UI.brush(255, 255, 255, alpha: 40)
        block.background = UI.brush(255, 255, 255, alpha: 40)
        answers.children.append(allow)
        answers.children.append(block)
        permissionPanel.children.append(permissionText)
        permissionPanel.children.append(answers)
        permissionPanel.margin = Thickness(left: 0, top: 8, right: 0, bottom: 0)

        status.textWrapping = .wrap
        status.fontSize = 12
        status.margin = Thickness(left: 0, top: 6, right: 0, bottom: 0)

        let parts: [FrameworkElement] = [toolbar, address, sidebar.root, permissionPanel, status]
        for (i, part) in parts.enumerated() {
            sidebarPanel.children.append(part)
            try? Grid.setRow(part, Int32(i))
        }

        grid.children.append(sidebarPanel)
        grid.children.append(content)
        try? Grid.setColumn(sidebarPanel, 0)
        try? Grid.setColumn(content, 1)
        // Shortcuts while the sidebar has the keyboard; the page reports its own (handleKey).
        grid.keyDown.addHandler { [weak self] _, args in
            guard let self, let args, !args.handled else { return }
            let key = KeyPress(keyCode: Int32(truncatingIfNeeded: args.key.rawValue), control: Self.isDown(0x11),
                               shift: Self.isDown(0x10), alt: Self.isDown(0x12))
            if self.handleShortcut(key) { args.handled = true }
        }
        return grid
    }

    private static func isDown(_ virtualKey: Int32) -> Bool { GetKeyState(virtualKey) < 0 }

    /// The content column in physical pixels, relative to the window's client area.
    private func contentFrame() -> PixelRect {
        let scale = content.xamlRoot?.rasterizationScale ?? 1
        let origin = (try? content.transformToVisual(nil)?.transformPoint(Point(x: 0, y: 0))) ?? Point(x: Float(Self.sidebarWidth), y: 0)
        return PixelRect(x: Int32((Double(origin.x) * scale).rounded()), y: Int32((Double(origin.y) * scale).rounded()),
                         width: Int32((content.actualWidth * scale).rounded()),
                         height: Int32((content.actualHeight * scale).rounded()))
    }

    private func layoutPage() {
        shownPage?.frame = contentFrame()
    }

    // MARK: Address box

    /// What the user typed, as CraCore turns it into a page: an address, or a search.
    private func go(to typed: String) {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let url = TypedURL.looksLikeURL(text) ? TypedURL.fromInput(text) : store.settings.searchEngine.searchURL(text)
        if newTabPending || store.selectedTab == nil {
            newTabPending = false
            store.createTab(url: url)
        } else if let id = store.selectedTabID, let page = pages[id] {
            page.loadURL(url)
            page.setFocused(true)
        } else if let id = store.selectedTabID {
            // An empty tab: its first page.
            store.updateTab(id, url: url)
        }
    }

    private func focusAddress() {
        _ = try? address.focus(.programmatic)
        try? address.selectAll()
    }

    private func cancelNewTab() {
        guard newTabPending else { return }
        newTabPending = false
        address.text = store.selectedTab?.tab?.url ?? ""
        shownPage?.setFocused(true)
    }

    // MARK: Commands

    private func closeCurrentTab() {
        if let id = store.selectedTabID { closeTab(id) }
    }

    /// Selects the tab `delta` rows away in the space's favorites, pinned and Today tabs.
    private func cycleTab(_ delta: Int) {
        let tabs = store.visibleTabs(in: store.focusedSpaceID)
        guard !tabs.isEmpty else { return }
        let idx = store.selectedTabID.flatMap { id in tabs.firstIndex { $0.id == id } } ?? -1
        let n = tabs.count
        store.selectTab(tabs[((idx + delta) % n + n) % n].id)
    }

    /// Ctrl+1…8 the nth tab, Ctrl+9 the last (Arc's "Go to Sidebar Item N").
    private func selectTab(number n: Int) {
        let tabs = store.visibleTabs(in: store.focusedSpaceID)
        guard !tabs.isEmpty else { return }
        store.selectTab((n == 9 ? tabs.last : tabs[min(n, tabs.count) - 1])?.id)
    }

    private func reopenClosedTab() {
        store.reopenLastArchived()
    }

    // MARK: Keys

    /// Shortcuts Cra keeps from the page (Arc's, with Ctrl in place of Cmd).
    private func handleShortcut(_ key: KeyPress) -> Bool {
        let vkTab: Int32 = 0x09, vkLeft: Int32 = 0x25, vkRight: Int32 = 0x27, vkF5: Int32 = 0x74
        let letter = { (c: Character) in Int32(c.asciiValue ?? 0) }
        if key.control && key.alt {
            switch key.keyCode {
            case vkLeft: store.focusSpace(offset: -1)
            case vkRight: store.focusSpace(offset: 1)
            default: return false
            }
            return true
        }
        if key.control {
            switch key.keyCode {
            case letter("T") where key.shift: reopenClosedTab()
            case letter("T"): beginNewTab()
            case letter("W"): closeCurrentTab()
            case letter("L"): focusAddress()
            case letter("R"): reload(ignoringCache: key.shift)
            case letter("D"): if let id = store.selectedTabID { store.togglePinned(id) }
            case vkTab: cycleTab(key.shift ? -1 : 1)
            case letter("1")...letter("9"): selectTab(number: Int(key.keyCode - letter("0")))
            default: return false
            }
            return true
        }
        if key.alt {
            switch key.keyCode {
            case vkLeft: shownPage?.goBack()
            case vkRight: shownPage?.goForward()
            default: return false
            }
            return true
        }
        if key.keyCode == vkF5 {
            reload(ignoringCache: key.control)
            return true
        }
        return false
    }

    private func reload(ignoringCache: Bool) {
        if ignoringCache { shownPage?.reloadIgnoringCache() } else { shownPage?.reload() }
    }

    // MARK: Permissions

    private func showNextPermission() {
        guard let request = permissionQueue.first else {
            permissionPanel.visibility = .collapsed
            return
        }
        var what: [String] = []
        if request.kinds.contains(.camera) { what.append("your camera") }
        if request.kinds.contains(.microphone) { what.append("your microphone") }
        if request.kinds.contains(.location) { what.append("your location") }
        if request.kinds.contains(.notifications) { what.append("notifications") }
        if what.isEmpty { what.append("a permission") }
        permissionText.text = "\(request.origin) wants \(what.joined(separator: " and "))."
        permissionText.foreground = sidebar.textColor
        permissionPanel.visibility = .visible
    }

    private func answerPermission(_ allowed: Bool) {
        guard !permissionQueue.isEmpty else { return }
        permissionQueue.removeFirst().answer(allowed)
        showNextPermission()
    }
}

// MARK: - Sidebar → window

extension BrowserWindow: SidebarActions {
    /// Today tabs are archived. Pinned tabs and favorites stay; they unload and return to
    /// their pinned page (Arc's close-on-pinned behaviour, MainWindowController.closeTab).
    func closeTab(_ id: UUID) {
        guard let item = store.item(id), item.isTab else { return }
        if store.isPinned(id) {
            let panes = store.paneTabIDs(for: id)
            let wasSelected = store.selectedTabID.map(panes.contains) ?? false
            for p in panes {
                _ = store.resetPinnedTab(p)
                pages[p]?.close()
                pages[p] = nil
            }
            if wasSelected {
                // Back to the tab used before, if it is still open; an unloaded pinned tab doesn't count.
                let back = store.recentTabs(in: store.focusedSpaceID, limit: .max)
                    .first { !panes.contains($0) && (!store.isPinned($0) || pages[$0] != nil) }
                store.selectTab(back)
            }
        } else {
            store.archiveTab(id, reason: .manual)
        }
    }

    func beginNewTab() {
        newTabPending = true
        address.text = ""
        focusAddress()
    }
}

// MARK: - Chromium → window

extension BrowserWindow: WebPageDelegate {
    func page(_ page: WebPage, didChangeTitle title: String) {
        if let id = tabID(of: page) { store.updateTab(id, title: title) }
    }

    func page(_ page: WebPage, didChangeURL url: String) {
        guard let id = tabID(of: page) else { return }
        store.updateTab(id, url: url)
        if page === shownPage && !newTabPending { address.text = url }
    }

    func page(_ page: WebPage, didFinishLoadingURL url: String, statusCode: Int) {
        guard let id = tabID(of: page), !store.isIncognito(item: id) else { return }
        store.recordVisit(url: url, title: page.currentTitle)
    }

    func page(_ page: WebPage, didReportThemeColor hex: String) {
        if let id = tabID(of: page) { store.setThemeColor(id, hex) }
    }

    func page(_ page: WebPage, requestsNewTabWithURL url: String, inBackground background: Bool) {
        let space = tabID(of: page).flatMap { store.spaceID(ofItem: $0) }
        store.createTab(url: url, in: space, select: !background)
    }

    func page(_ page: WebPage, popupHostForURL url: String, inBackground background: Bool) -> WebPage? {
        // The popup gets a tab of its own; its page is the host Chromium opens it in.
        let space = tabID(of: page).flatMap { store.spaceID(ofItem: $0) }
        let tab = store.createTab(url: url, in: space, select: false)
        let host = WebPage(popupHostIn: hwnd, frame: contentFrame(), delegate: self)
        host.userInfo = tab.id
        host.isVisible = false
        pages[tab.id] = host
        if !background { store.selectTab(tab.id) }
        return host
    }

    func page(_ page: WebPage, handleKey key: KeyPress) -> Bool {
        guard !key.isRepeat || key.keyCode == 0x09 else { return false }
        return handleShortcut(key)
    }

    func page(_ page: WebPage, didUpdateDownload download: DownloadInfo) {
        let name = URL(fileURLWithPath: download.fullPath.isEmpty ? download.suggestedName : download.fullPath).lastPathComponent
        status.foreground = sidebar.textColor
        switch download.state {
        case .inProgress: status.text = "Downloading \(name)" + (download.percent >= 0 ? " \(download.percent)%" : "")
        case .complete: status.text = "Downloaded \(name)"
        case .cancelled: status.text = "Cancelled \(name)"
        case .interrupted: status.text = "\(name) failed"
        }
    }

    func page(_ page: WebPage, requestsPermissionForOrigin origin: String, kinds: PermissionKinds,
              answer: @escaping (Bool) -> Void) {
        permissionQueue.append((origin, kinds, answer))
        if permissionQueue.count == 1 { showNextPermission() }
    }

    func pageDidClose(_ page: WebPage) {
        if closing {
            if cra_cef_live_browser_count() == 0 { finishClosing() }
            return
        }
        guard let id = tabID(of: page), pages[id] === page else { return }
        pages[id] = nil
        // window.close(): the page's tab goes as a closed tab would.
        if page.closedByPage { closeTab(id) }
    }
}
