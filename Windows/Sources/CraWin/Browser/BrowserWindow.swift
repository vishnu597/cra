import CraCEFWin
import CraCore
import Foundation
import Observation
import UWP
import WinAppSDK
import WindowsFoundation
import WinSDK
import WinUI

/// One browser window on the shared SidebarStore: the toolbar, address box and sidebar on
/// the left, the open tab's page on the right (or its split's panes, side by side or stacked).
/// The Windows counterpart of MainWindowController and BrowserManager, smaller for now: one
/// window, a page made when its tab is first shown and closed when the tab leaves the sidebar
/// or is unloaded.
@MainActor
final class BrowserWindow {
    let store: SidebarStore
    /// XAML in the sidebar column only, so the page gets real clicks (HostWindow).
    private(set) var window: HostWindow!
    private var sidebar: SidebarView!
    private let sidebarPanel = Grid()
    /// The open tab's address; a click opens the command bar on it (Arc's URL bar in the sidebar).
    private let address = TextBlock()
    private var addressButton: Button!
    /// Arc's downloads list over the bottom of the sidebar, and its button in the footer.
    private var downloads: DownloadsTray!
    /// Downloads this window's pages started (the stall check), and the ones it has recorded.
    private var windowDownloads: Set<UInt32> = []
    private var finishedDownloads: Set<UInt32> = []
    private var downloadWatchdog: WinAppSDK.DispatcherQueueTimer?
    private let permissionPanel = StackPanel()
    private let permissionText = TextBlock()
    private let dispatcher: WinAppSDK.DispatcherQueue
    /// The window's HWND: every page is a child window of it.
    private var hwnd: UInt = 0

    /// Pages by tab id.
    private var pages: [UUID: WebPage] = [:]
    /// The selected tab's page: the focused pane, which takes the keyboard and the commands.
    private weak var shownPage: WebPage?
    private var shownTabID: UUID?
    /// The panes on screen, in order: the selected tab, or every pane of its split. Their frames
    /// and the gaps between them, in physical pixels relative to the client area.
    private var paneIDs: [UUID] = []
    private var paneFrames: [UUID: PixelRect] = [:]
    private var paneGaps: [PixelRect] = []
    /// The same layout in DIPs from the page area's top left, for hit-testing the dividers.
    private var paneLayoutResult = SplitPaneLayout.Result()
    private var paneOrientation: SplitOrientation = .horizontal
    /// A divider being dragged: the one after pane `divider`, where it was pressed, and the
    /// factors then. `factors` follows the pointer and is saved to the split on release.
    private var paneDrag: (divider: Int, x: Int32, y: Int32, start: [UUID: CGFloat], factors: [UUID: CGFloat])?
    /// Ctrl+T, Ctrl+L: ranked by CraCore's SuggestionEngine, drawn in a window of its own over the page.
    private var engine: SuggestionEngine!
    private var commandBar: CommandBarView!
    private var commandWindow: FloatingWindow?
    private var commandBarHeight = CommandBarView.height(forRows: 0)
    /// The bar closed because another window came to the front: that window keeps the keyboard.
    private var commandBarDeactivated = false
    /// Ctrl+F: find in the shown page, in a window of its own at the page's top right.
    private let findBar = FindBarView()
    private var findWindow: FloatingWindow?
    private var findVisible = false
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

    init(store: SidebarStore, dispatcher: WinAppSDK.DispatcherQueue) throws {
        self.store = store
        self.dispatcher = dispatcher
        engine = SuggestionEngine(store: store, commands: { WinCommands.all }, load: WinSuggestLoader.load)
        commandBar = CommandBarView(engine: engine, store: store)
        sidebar = SidebarView(store: store, actions: self)
        downloads = DownloadsTray(history: .shared, dispatcher: dispatcher)
        sidebar.attachDownloads(button: downloads.button, list: downloads.list)
        downloads.pointer = { [weak self] in
            guard let self, let window = self.window, let host = HWND(bitPattern: self.hwnd) else { return nil }
            var p = POINT(x: Int32.min, y: Int32.min)
            _ = GetCursorPos(&p)
            guard p.x != Int32.min else { return nil }
            _ = ScreenToClient(host, &p)
            // The XAML island starts at the client area's top left.
            return (Double(p.x) / window.scale, Double(p.y) / window.scale)
        }
        window = try HostWindow(content: makeLayout(), sidebarWidth: Self.sidebarWidth)
        window.title = "Cra"
        hwnd = window.hwnd
        window.onLayout = { [weak self] _ in
            self?.layoutPanes()
            self?.placeCommandBar()
            self?.placeFindBar()
        }
        window.onMove = { [weak self] in self?.placeFindBar() }
        window.onMouse = { [weak self] event in self?.handlePaneMouse(event) }
        window.cursor = { [weak self] x, y in self?.paneCursor(x: x, y: y) }
        window.onFocus = { [weak self] in
            guard let self, !self.closing, !self.commandBar.isOpen else { return }
            self.focusContent()
        }
        makeCommandBar()
        makeFindBar()
        // Chromium closes its pages before their parent window goes (CEF's DoClose order).
        window.shouldClose = { [weak self] in
            guard let self, !self.readyToClose, cra_cef_live_browser_count() > 0 else { return true }
            self.beginClosing()
            return false
        }
        // One window for now: closing it quits (there's no WinUI Window to make WinUI quit).
        window.onClose = { PostQuitMessage(0) }
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
            applyPaneColors(store.focusedSpace.theme)
            downloads.apply(SidebarPalette(store.focusedSpace.theme), fill: sidebar.fill)
            syncPages()
            showAddress(store.selectedTab?.tab?.url ?? "")
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
        // Split view: the selected tab's split decides which panes are on screen. An empty pane
        // (Arc's "Search or Enter URL…") has no page yet.
        let selected = store.selectedTab
        let panes = selected.map { store.paneTabIDs(for: $0.id) } ?? []
        var shown: [UUID: WebPage] = [:]
        for id in panes {
            guard let tab = store.item(id)?.tab, !tab.url.isEmpty else { continue }
            shown[id] = pages[id] ?? makePage(for: id, url: tab.url)
        }
        paneIDs = panes
        layoutPanes()
        for (id, page) in pages where shown[id] == nil { page.isVisible = false }
        for page in shown.values { page.isVisible = true }
        show(selected.flatMap { shown[$0.id] }, tab: selected?.id)
        let title = selected?.displayTitle ?? ""
        window.title = title.isEmpty ? "Cra" : "\(title) - Cra"
    }

    private func makePage(for id: UUID, url: String) -> WebPage {
        let page = WebPage(parent: hwnd, frame: paneFrames[id] ?? contentFrame(), url: url, delegate: self)
        page.userInfo = id
        page.isVisible = false
        pages[id] = page
        return page
    }

    /// Focuses the selected tab's page (the panes are already on screen, syncPages).
    private func show(_ page: WebPage?, tab id: UUID?) {
        let changed = id != shownTabID
        if shownPage !== page {
            shownPage = page
            if let page {
                page.setFocused(true)
            } else {
                // Nothing to show (an empty space): keys would stay with the hidden page.
                focusSidebar()
            }
        }
        shownTabID = id
        guard changed else { return }
        showAddress(page.map { _ in store.item(id ?? UUID())?.tab?.url ?? "" } ?? "")
        // An empty tab (a new pane) waits for an address.
        if id != nil && page == nil { openCommandBar(.editURL) }
    }

    /// Closes every page, then the window once Chromium is done with them (or after 3 s).
    private func beginClosing() {
        guard !closing else { return }
        closing = true
        commandBar.close()
        hideFindBar()
        let open = Array(pages.values)
        pages.removeAll()
        shownPage = nil
        paneIDs = []
        paneDrag = nil
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
        window.close()
    }

    private func tabID(of page: WebPage) -> UUID? { page.userInfo as? UUID }

    // MARK: Layout

    private func makeLayout() -> UIElement {
        sidebarPanel.padding = Thickness(left: 10, top: 10, right: 10, bottom: 10)
        for height in [UI.auto, UI.auto, UI.star, UI.auto] { sidebarPanel.rowDefinitions.append(UI.row(height)) }

        let toolbar = StackPanel()
        toolbar.orientation = .horizontal
        toolbar.spacing = 2
        toolbar.children.append(UI.button("\u{2190}") { [weak self] in self?.shownPage?.goBack() })
        toolbar.children.append(UI.button("\u{2192}") { [weak self] in self?.shownPage?.goForward() })
        toolbar.children.append(UI.button("\u{27F3}") { [weak self] in self?.shownPage?.reload() })

        address.fontSize = 13
        address.textTrimming = .characterEllipsis
        address.text = "Search or enter address"
        addressButton = UI.button(address) { [weak self] in self?.openCommandBar(.editURL) }
        addressButton.horizontalAlignment = .stretch
        addressButton.horizontalContentAlignment = .left
        addressButton.margin = Thickness(left: 0, top: 8, right: 0, bottom: 8)

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

        let parts: [FrameworkElement] = [toolbar, addressButton, sidebar.root, permissionPanel]
        for (i, part) in parts.enumerated() {
            sidebarPanel.children.append(part)
            try? Grid.setRow(part, Int32(i))
        }

        // Shortcuts while the sidebar has the keyboard; the page reports its own (handleKey).
        sidebarPanel.keyDown.addHandler { [weak self] _, args in
            guard let self, let args, !args.handled else { return }
            let key = KeyPress(keyCode: Int32(truncatingIfNeeded: args.key.rawValue), control: Self.isDown(0x11),
                               shift: Self.isDown(0x10), alt: Self.isDown(0x12))
            if self.handleShortcut(key) { args.handled = true }
        }
        return sidebarPanel
    }

    private static func isDown(_ virtualKey: Int32) -> Bool { GetKeyState(virtualKey) < 0 }

    /// The page area in physical pixels, relative to the window's client area.
    private func contentFrame() -> PixelRect {
        window?.contentFrame ?? PixelRect(x: Int32(Self.sidebarWidth), y: 0, width: 800, height: 600)
    }

    // MARK: Address and command bar

    private func showAddress(_ url: String) {
        address.text = url.isEmpty ? "Search or enter address" : SuggestionEngine.humanURL(url)
        address.foreground = url.isEmpty ? sidebar.secondaryTextColor : sidebar.textColor
    }

    /// Keys to the page shown, else the sidebar.
    private func focusContent() {
        if let page = shownPage { page.setFocused(true) } else { focusSidebar() }
    }

    /// Keys to the sidebar's XAML, so its shortcuts work with no page to take them.
    private func focusSidebar() {
        window.focusXAML()
        _ = try? addressButton.focus(.programmatic)
    }

    private func makeCommandBar() {
        commandBar.onCommit = { [weak self] row, typed, mode in self?.handleCommit(row, typed: typed, mode: mode) }
        commandBar.onOpenInBackground = { [weak self] row, typed in self?.openInBackground(row, typed: typed) ?? false }
        commandBar.onResize = { [weak self] height in
            self?.commandBarHeight = height
            self?.placeCommandBar()
        }
        commandBar.onClose = { [weak self] in
            guard let self else { return }
            self.commandWindow?.hide()
            // Back to the page, unless another window took the front. Hiding the bar doesn't
            // always hand the front back to this window by itself.
            guard !self.commandBarDeactivated else { return }
            if let window = HWND(bitPattern: self.hwnd) { _ = SetForegroundWindow(window) }
            self.focusContent()
        }
        do {
            commandWindow = try FloatingWindow(owner: window, content: commandBar.root)
            commandWindow?.onDeactivate = { [weak self] in
                guard let self, self.commandBar.isOpen else { return }
                self.commandBarDeactivated = true
                self.commandBar.close()
            }
        } catch {
            print("The command bar's window could not be made: \(error)")
        }
    }

    /// Ctrl+T (`newTab`) or Ctrl+L (`editURL`): the bar over the page, as MainWindowController opens it.
    /// After the event that asks for it: its window taking the front inside a click handler (a
    /// press-mode button) or a page's key callback would take the rest of that input with it.
    func openCommandBar(_ mode: CommandBarMode) {
        _ = try? dispatcher.tryEnqueue { [weak self] in self?.presentCommandBar(mode) }
    }

    private func presentCommandBar(_ mode: CommandBarMode) {
        guard !closing, let commandWindow else { return }
        // An empty pane gets Arc's "Search or Enter URL…" bar; the result fills the pane.
        let fillingEmptyPane = store.selectedTab?.isEmptyTab == true
        let prefill = mode == .editURL && !fillingEmptyPane ? store.selectedTab?.tab?.url : nil
        let effective: CommandBarMode = mode == .editURL && (store.selectedTab == nil || fillingEmptyPane) ? .newTab : mode
        commandBarDeactivated = false
        commandBar.open(mode: effective, prefill: prefill, theme: store.focusedSpace.theme)
        placeCommandBar()
        commandWindow.show { [weak self] in self?.commandBar.focusField() }
    }

    /// Centred on the window, the field where a full bar would put it, so rows coming and going
    /// don't move what you type into (MainWindowController.positionCommandPanel).
    private func placeCommandBar() {
        guard let commandWindow, commandBar.isOpen, let window else { return }
        let scale = window.scale
        let position = window.appWindow.position, size = window.appWindow.size
        let width = min(CommandBarView.width, Double(size.width) / scale - 80) * scale
        let fullHeight = CommandBarView.height(forRows: SuggestionEngine.maxRows) * scale
        let top = Double(position.y) + Double(size.height) / 2 - fullHeight / 2 - 40 * scale
        let left = Double(position.x) + (Double(size.width) - width) / 2
        commandWindow.place(origin: PointInt32(x: Int32(left.rounded()), y: Int32(top.rounded())),
                            size: SizeInt32(width: Int32(width.rounded()), height: Int32((commandBarHeight * scale).rounded())))
    }

    /// What Return in the bar does (MainWindowController.handleCommit).
    private func handleCommit(_ s: Suggestion?, typed: String, mode: CommandBarMode) {
        let query = commandBar.query
        func open(_ url: String) {
            store.recordQuerySelection(query: query, url: url)
            let fillsEmptyPane = store.selectedTab?.isEmptyTab == true
            if mode == .editURL || fillsEmptyPane, store.selectedTabID != nil {
                loadInSelectedTab(url)
            } else {
                store.createTab(url: url)
            }
        }
        guard let s else {
            if typed.isEmpty { return }
            open(SuggestionEngine.looksLikeURL(typed) ? SuggestionEngine.urlFromInput(typed) : engine.searchURL(typed))
            return
        }
        switch s.kind {
        case .switchToTab(let id):
            store.recordQuerySelection(query: query, url: s.url ?? "")
            store.selectTab(id)
        case .archived(let id):
            _ = store.restoreArchived(id)
        case .navigate:
            open(typed == query ? (s.url ?? SuggestionEngine.urlFromInput(typed)) : SuggestionEngine.urlFromInput(typed))
        case .search:
            open(s.url ?? engine.searchURL(typed))
        case .history, .topDomain:
            open(s.url ?? "")
        case .command(let id):
            perform(id)
        case .switchSpace(let id):
            store.focusSpace(id)
        case .moveToSpace(let id):
            if let t = store.selectedTabID { _ = store.moveTabAndFollow(t, toSpace: id) }
        case .moveToFolder(let id):
            if let t = store.selectedTabID { store.moveItem(t, to: id, index: nil) }
        }
    }

    /// Ctrl+Return in the bar (Arc's ⌘Return): the row's page in a new background tab, the bar
    /// staying open; an open tab's row opens its address again rather than switching.
    private func openInBackground(_ s: Suggestion?, typed: String) -> Bool {
        let query = commandBar.query
        let url: String?
        switch s?.kind {
        case nil:
            url = typed.isEmpty ? nil : SuggestionEngine.looksLikeURL(typed) ? SuggestionEngine.urlFromInput(typed) : engine.searchURL(typed)
        case .navigate?:
            url = typed == query ? (s?.url ?? SuggestionEngine.urlFromInput(typed)) : SuggestionEngine.urlFromInput(typed)
        case .search?:
            url = s?.url ?? engine.searchURL(typed)
        case .switchToTab?, .archived?, .history?, .topDomain?:
            url = s?.url
        default:
            url = nil
        }
        guard let url, !url.isEmpty else { return false }
        store.recordQuerySelection(query: query, url: url)
        let tab = store.createTab(url: url, select: false)
        store.markUnread(tab.id, false)  // Arc saves these read, unlike a link opened in the background
        return true
    }

    private func loadInSelectedTab(_ url: String) {
        guard let id = store.selectedTabID else { return }
        if let page = pages[id] {
            page.loadURL(url)
            page.setFocused(true)
        } else {
            // An empty tab: its first page.
            store.updateTab(id, url: url)
        }
    }

    /// A command row (WinCommands).
    private func perform(_ id: String) {
        switch id {
        case "find": showFindBar()
        case "newTab": beginNewTab()
        case "reopenClosedTab": reopenClosedTab()
        case "closeTab": closeCurrentTab()
        case "reload": reload(ignoringCache: false)
        case "hardReload": reload(ignoringCache: true)
        case "pinTab": if let t = store.selectedTabID { store.togglePinned(t) }
        case "addSplitView": addSplitPane()
        case "closeSplitPane": if let t = store.selectedTabID { closeSplitPane(t) }
        case "separateFromSplit": if let t = store.selectedTabID { separatePane(t) }
        case "flipSplitOrientation": if let t = store.selectedTabID, let split = store.splitContaining(t) { store.flipSplitOrientation(split.id) }
        case "nextSplitPane": cycleSplitPane(1)
        case "previousSplitPane": cycleSplitPane(-1)
        default: break
        }
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

    // MARK: Find in page

    private func makeFindBar() {
        findBar.onFind = { [weak self] query, forward in self?.find(query, forward: forward) }
        findBar.onClose = { [weak self] in self?.hideFindBar() }
        do {
            findWindow = try FloatingWindow(owner: window, content: findBar.root)
            findWindow?.onClose = { [weak self] in self?.hideFindBar() }
        } catch {
            print("The find bar's window could not be made: \(error)")
        }
    }

    /// Ctrl+F (MainWindowController.showFindBar): the bar, its field focused.
    private func showFindBar() {
        guard !closing, let findWindow else { return }
        findBar.apply(dark: store.focusedSpace.theme.isDark)
        findVisible = true
        placeFindBar()
        // After the key event that asked, as with the command bar.
        _ = try? dispatcher.tryEnqueue { [weak self] in
            guard let self, self.findVisible else { return }
            findWindow.show { [weak self] in self?.findBar.focusField() }
        }
    }

    private func hideFindBar() {
        guard findVisible else { return }
        findVisible = false
        findBar.reset()
        shownPage?.stopFinding(clearSelection: true)
        let front = UInt(bitPattern: GetForegroundWindow())
        let ours = front == findWindow?.hwnd || front == hwnd
        findWindow?.hide()
        guard !closing, ours else { return }
        // Typing goes back to the page, unless another app came to the front meanwhile. Again
        // once the click on ✕ is done with: XAML handing the press back to its button left the
        // hidden bar's window in front, with the keyboard.
        let restore = { [weak self] in
            guard let self, !self.findVisible, let window = HWND(bitPattern: self.hwnd) else { return }
            _ = SetForegroundWindow(window)
            self.focusContent()
        }
        restore()
        _ = try? dispatcher.tryEnqueue(restore)
    }

    /// Ctrl+G, Ctrl+Shift+G, F3: the next or previous match; opens the bar first.
    private func findNext(forward: Bool) {
        guard findVisible else { return showFindBar() }
        find(findBar.query, forward: forward)
    }

    /// Always a follow-up find: CEF restarts the search when the text changes, and unlike a first
    /// request that selects a match, so the bar shows "1/3" rather than "0/3" (as on the Mac).
    private func find(_ query: String, forward: Bool) {
        guard let page = shownPage else { return }
        if query.isEmpty {
            findBar.reset()
            page.stopFinding(clearSelection: true)
            return
        }
        page.find(query, forward: forward, matchCase: false, findNext: true)
    }

    /// The top right of the page area, 10 DIPs in.
    private func placeFindBar() {
        guard findVisible, let findWindow, let window, let host = HWND(bitPattern: hwnd) else { return }
        let scale = window.scale, frame = shownTabID.flatMap { paneFrames[$0] } ?? window.contentFrame
        let width = (FindBarView.width * scale).rounded(), height = (FindBarView.height * scale).rounded()
        let inset = (FindBarView.inset * scale).rounded()
        var corner = POINT(x: frame.x + frame.width, y: frame.y)
        _ = ClientToScreen(host, &corner)
        findWindow.place(origin: PointInt32(x: corner.x - Int32(width + inset), y: corner.y + Int32(inset)),
                         size: SizeInt32(width: Int32(width), height: Int32(height)))
    }

    // MARK: Keys

    /// Shortcuts Cra keeps from the page (Arc's, with Ctrl in place of Cmd).
    private func handleShortcut(_ key: KeyPress) -> Bool {
        let vkTab: Int32 = 0x09, vkLeft: Int32 = 0x25, vkRight: Int32 = 0x27, vkF3: Int32 = 0x72, vkF5: Int32 = 0x74
        let vkPlus: Int32 = 0xBB, vkMinus: Int32 = 0xBD  // the = and - keys
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
            case letter("L"): openCommandBar(.editURL)
            case letter("F"): showFindBar()
            case letter("G"): findNext(forward: !key.shift)
            case letter("R"): reload(ignoringCache: key.shift)
            case letter("D"): if let id = store.selectedTabID { store.togglePinned(id) }
            // Arc's View ▸ Add Split View ⌃⇧= and Close this Split Pane ⌃⇧-; without Shift they
            // stay the page's zoom.
            case vkPlus where key.shift: addSplitPane()
            case vkMinus where key.shift: if let id = store.selectedTabID { closeSplitPane(id) }
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
        if key.keyCode == vkF3 {
            findNext(forward: !key.shift)
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

    // MARK: Split view

    /// Arc's "Add Split View" (Ctrl+Shift+=): an empty pane next to the focused one, the command
    /// bar asking what it shows (MainWindowController.addSplitPane). Arc stops at four panes.
    private func addSplitPane() {
        guard let current = store.selectedTabID else { return beginNewTab() }
        guard store.paneTabIDs(for: current).count < SplitPaneLayout.Constants.maximumPanes else { return }
        guard store.addEmptyPane(nextTo: current) != nil else { return }
        // syncPages sees the empty pane selected and opens the bar.
    }

    /// Arc's "Close this Split Pane" (Ctrl+Shift+-): the pane's tab closes like any tab and the
    /// split keeps the other panes. A pinned split's pane leaves it (closing it would only
    /// unload the whole split).
    func closeSplitPane(_ id: UUID) {
        guard store.splitContaining(id) != nil else { return closeTab(id) }
        if store.item(id)?.isEmptyTab == true || store.isPinned(id) {
            store.archiveTab(id, reason: .manual)
        } else {
            closeTab(id)
        }
    }

    /// Arc's "Separate Page from Split View": the pane becomes a normal tab again.
    func separatePane(_ id: UUID) {
        guard store.splitContaining(id) != nil else { return }
        store.separateFromSplit(id)
        store.selectTab(id)
    }

    /// Switch to Next / Previous Split View.
    private func cycleSplitPane(_ delta: Int) {
        guard let current = store.selectedTabID,
              let next = SplitPaneLayout.pane(delta, from: current, in: store.paneTabIDs(for: current)) else { return }
        store.selectTab(next)
    }

    /// Lays the panes out in the page area with CraCore's SplitPaneLayout (in DIPs, y down) and
    /// moves their pages there.
    private func layoutPanes() {
        guard let window, !closing else { return }
        let area = window.contentFrame, scale = window.scale
        let split = paneIDs.first.flatMap { store.splitContaining($0) }
        paneOrientation = split?.split?.orientation ?? .horizontal
        let factors = paneDrag?.factors ?? SplitPaneLayout.normalizedFactors(ids: paneIDs, stored: split?.split?.widthFactors ?? [:])
        let result = paneLayout(factors: factors).compute()
        paneLayoutResult = result
        func pixels(_ r: CGRect) -> PixelRect {
            func px(_ v: CGFloat) -> Int32 { Int32((Double(v) * scale).rounded()) }
            let x0 = px(r.minX), x1 = px(r.maxX), y0 = px(r.minY), y1 = px(r.maxY)
            return PixelRect(x: area.x + x0, y: area.y + y0, width: x1 - x0, height: y1 - y0)
        }
        paneFrames = result.frames.mapValues(pixels)
        paneGaps = result.gaps.map(pixels)
        for (id, frame) in paneFrames { pages[id]?.frame = frame }
        window.pill = paneDrag.flatMap { paneGaps.indices.contains($0.divider) ? pill(in: paneGaps[$0.divider]) : nil }
        placeFindBar()
    }

    private func paneLayout(factors: [UUID: CGFloat]) -> SplitPaneLayout {
        let area = window.contentFrame, scale = window.scale
        let panes = paneIDs.map { SplitPaneLayout.Pane(id: $0, factor: factors[$0] ?? 1 / CGFloat(max(1, paneIDs.count))) }
        return SplitPaneLayout(panes: panes, orientation: paneOrientation,
                               containerSize: CGSize(width: Double(area.width) / scale, height: Double(area.height) / scale),
                               backingScaleFactor: CGFloat(scale), flipped: true)
    }

    /// The divider's pill while it is dragged (SplitDraggerHandleView.Style): 4 × 36 DIPs, centred.
    private func pill(in gap: PixelRect) -> PixelRect {
        let thick = Int32((4 * window.scale).rounded()), long = Int32((36 * window.scale).rounded())
        return paneOrientation == .horizontal
            ? PixelRect(x: gap.x + (gap.width - thick) / 2, y: gap.y + (gap.height - long) / 2, width: thick, height: long)
            : PixelRect(x: gap.x + (gap.width - long) / 2, y: gap.y + (gap.height - thick) / 2, width: long, height: thick)
    }

    /// The divider under a client point, in pixels, with Arc's hit outset.
    private func divider(x: Int32, y: Int32) -> Int? {
        let scale = window.scale, area = window.contentFrame
        return paneLayoutResult.divider(at: CGPoint(x: Double(x - area.x) / scale, y: Double(y - area.y) / scale))
    }

    private func paneCursor(x: Int32, y: Int32) -> HostCursor? {
        if paneDrag != nil || divider(x: x, y: y) != nil {
            return paneOrientation == .horizontal ? .resizeLeftRight : .resizeUpDown
        }
        return nil
    }

    /// Presses on the page area that no page covers: a divider drags (a double-click makes the
    /// panes equal again), an empty pane asks for its address.
    private func handlePaneMouse(_ event: HostMouseEvent) {
        switch event {
        case .down(let x, let y, let clicks):
            if let index = divider(x: x, y: y), let split = paneIDs.first.flatMap({ store.splitContaining($0) }) {
                if clicks == 2 {
                    paneDrag = nil
                    store.setSplitWidthFactors(split.id, [:])
                    return
                }
                let factors = SplitPaneLayout.normalizedFactors(ids: paneIDs, stored: split.split?.widthFactors ?? [:])
                paneDrag = (divider: index, x: x, y: y, start: factors, factors: factors)
                layoutPanes()
            } else if let id = paneIDs.first(where: { paneFrames[$0].map { Self.contains($0, x: x, y: y) } == true }), pages[id] == nil {
                if store.selectedTabID == id { openCommandBar(.editURL) } else { store.selectTab(id) }
            }
        case .move(let x, let y):
            guard let drag = paneDrag else { return }
            let delta = paneOrientation == .horizontal ? Double(x - drag.x) : Double(y - drag.y)
            paneDrag?.factors = paneLayout(factors: drag.start).dragging(dividerAfter: drag.divider, by: CGFloat(delta / window.scale)).factors
            layoutPanes()
        case .up, .cancelled:
            guard let drag = paneDrag else { return }
            paneDrag = nil
            if let split = paneIDs.first.flatMap({ store.splitContaining($0) }) {
                store.setSplitWidthFactors(split.id, drag.factors.mapValues { Double($0) })
            }
            layoutPanes()
        }
    }

    private static func contains(_ r: PixelRect, x: Int32, y: Int32) -> Bool {
        x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
    }

    /// The page area's own colour (between panes, in an empty pane) is the sidebar's.
    private func applyPaneColors(_ theme: SpaceTheme) {
        let c = HexColor.components(theme.colors.first ?? "#1C242B") ?? (r: 0.11, g: 0.14, b: 0.17)
        let fill = HostColor(r: UInt8(c.r * 255), g: UInt8(c.g * 255), b: UInt8(c.b * 255))
        window.background = fill
        window.pillColor = fill.blended(with: theme.isDark ? HostColor(r: 255, g: 255, b: 255) : HostColor(r: 0, g: 0, b: 0), alpha: 0.45)
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

    /// "+ New Tab", Ctrl+T: the command bar, making a new tab.
    func beginNewTab() {
        openCommandBar(.newTab)
    }

    func addPane(toSplit id: UUID) {
        guard let last = store.children(of: id).last(where: \.isTab) else { return }
        store.selectTab(last.id)
        addSplitPane()
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
        if page === shownPage { showAddress(url) }
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

    func page(_ page: WebPage, didFindMatches count: Int, activeMatch: Int) {
        guard findVisible, page === shownPage else { return }
        findBar.report(matches: count, active: activeMatch)
    }

    func page(_ page: WebPage, didUpdateDownload download: DownloadInfo) {
        windowDownloads.insert(download.identifier)
        record(download)
    }

    /// Progress and failures show in the downloads list, as in Arc (it has no download toast);
    /// a finished file joins downloads.json (MainWindowController.browserManager(download:)).
    private func record(_ download: DownloadInfo) {
        let path = download.fullPath
        let name = path.isEmpty ? download.suggestedName : URL(fileURLWithPath: path).lastPathComponent
        let history = DownloadHistory.shared
        history.report(id: download.identifier, name: name, path: path, received: download.receivedBytes,
                       total: download.totalBytes, percent: download.percent, complete: download.state == .complete,
                       cancelled: download.state == .cancelled, failed: download.state == .interrupted)
        if download.state == .complete, !path.isEmpty, finishedDownloads.insert(download.identifier).inserted {
            history.add(path: path)
        }
        if download.state == .inProgress, downloadWatchdog == nil {
            downloadWatchdog = try? dispatcher.createTimer()
            downloadWatchdog?.interval = TimeSpan(duration: 2 * 10_000_000)
            downloadWatchdog?.isRepeating = true
            downloadWatchdog?.tick.addHandler { [weak self] _, _ in self?.checkStalledDownloads() }
            try? downloadWatchdog?.start()
        }
    }

    /// Chromium goes quiet about a download whose tab closed; the disk says how it ended
    /// (DownloadHistory.settledStalled).
    private func checkStalledDownloads() {
        let history = DownloadHistory.shared
        guard history.isRunning(anyOf: windowDownloads) else {
            try? downloadWatchdog?.stop()
            downloadWatchdog = nil
            return
        }
        let fm = FileManager.default
        func size(_ path: String) -> Int64? {
            guard let value = (try? fm.attributesOfItem(atPath: path))?[.size] else { return nil }
            if let n = value as? UInt64 { return Int64(n) }
            if let n = value as? Int64 { return n }
            return (value as? NSNumber)?.int64Value
        }
        let settled = history.settledStalled(among: windowDownloads, now: Date(), fileSize: size,
                                             partialExists: { fm.fileExists(atPath: $0 + ".crdownload") })
        for (t, outcome) in settled {
            let size: Int64, state: DownloadInfo.State
            switch outcome {
            case .complete(let n): (size, state) = (n, .complete)
            case .cancelled: (size, state) = (0, .cancelled)
            }
            record(DownloadInfo(identifier: t.id, url: "", fullPath: t.path, suggestedName: t.name, receivedBytes: size,
                                totalBytes: t.total, percent: state == .complete ? 100 : t.percent, state: state))
        }
    }

    func page(_ page: WebPage, requestsPermissionForOrigin origin: String, kinds: PermissionKinds,
              answer: @escaping (Bool) -> Void) {
        permissionQueue.append((origin, kinds, answer))
        if permissionQueue.count == 1 { showNextPermission() }
    }

    /// A click into another pane focuses it (Arc: the split's focusItemID follows the click).
    func pageDidReceiveFocus(_ page: WebPage) {
        guard !closing, let id = tabID(of: page), id != store.selectedTabID, paneIDs.contains(id) else { return }
        store.selectTab(id)
    }

    func pageDidClose(_ page: WebPage) {
        if closing {
            // After this callback: it comes from inside CEF's OnBeforeClose, and destroying the
            // pages' parent window there crashed libcef.
            if cra_cef_live_browser_count() == 0 {
                _ = try? dispatcher.tryEnqueue { [weak self] in self?.finishClosing() }
            }
            return
        }
        guard let id = tabID(of: page), pages[id] === page else { return }
        pages[id] = nil
        // window.close(): the page's tab goes as a closed tab would.
        if page.closedByPage { closeTab(id) }
    }
}
