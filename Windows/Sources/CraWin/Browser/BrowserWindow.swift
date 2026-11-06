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
/// The Windows counterpart of MainWindowController and BrowserManager, smaller for now: a
/// page made when its tab is first shown and closed when the tab leaves the sidebar or is
/// unloaded. Each window draws one of the store's window sessions (WindowSession): its focused
/// space and selected tabs; a private window's session has an incognito space of its own and
/// its pages load in the off-the-record profile.
@MainActor
final class BrowserWindow {
    let store: SidebarStore
    /// The store's window session this window shows.
    let windowID: UUID
    /// A private (incognito) window.
    let isIncognito: Bool
    /// The app's windows: new ones, and this one going.
    private weak var host: BrowserWindowHost?
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
    private let dispatcher: WinAppSDK.DispatcherQueue
    /// The window's HWND: every page is a child window of it.
    private var hwnd: UInt = 0

    /// Pages by tab id.
    private var pages: [UUID: WebPage] = [:]
    /// Every page this window made that Chromium hasn't finished closing: the window waits for
    /// them before it goes (CEF's DoClose order). Other windows' pages don't count.
    private var livePages: Set<ObjectIdentifier> = []
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
    /// Arc's Developer Mode bar over a site's page (HostWindow's strip).
    private let developerBar = DeveloperBarView()
    private var developerTabID: UUID?
    private var findWindow: FloatingWindow?
    private var findVisible = false
    private var refreshQueued = false
    /// The window is waiting for Chromium to close its pages; then it closes for good.
    private var closing = false
    private var readyToClose = false
    private var closeTimer: WinAppSDK.DispatcherQueueTimer?
    /// Ctrl+,: one for the app, made the first time any window opens it, then hidden and shown
    /// again (over the window that asked).
    private static var settingsWindow: SettingsWindow?
    /// Permission requests waiting for the user, oldest first; the first is on screen.
    private var permissionQueue: [(page: WeakPage, origin: String, kinds: PermissionKinds, answer: (Bool) -> Void)] = []
    private let permissionPrompt = PermissionPromptView()
    private var permissionWindow: FloatingWindow?
    private var permissionHeight = 120.0
    private let profileDialog = ProfileDialogView()
    private var profileWindow: FloatingWindow?
    private var profileDialogHeight = 400.0
    /// The sliders button at the end of the address pill, and the Site Control Center it opens.
    private var sliders: Button!
    private let slidersGlyph = FontIcon()
    private let siteControl = SiteControlCenterView()
    private var siteControlWindow: FloatingWindow?
    /// When the Site Control Center last closed because another window took the front: a press
    /// on the sliders right then is the click that closed it, and doesn't open it again.
    private var siteControlClosed = Date.distantPast
    private var toast: ToastView!
    /// A full-page capture is running.
    private var capturing = false
    /// The Peek closed last over this window and the tab it came from: Arc's Ctrl+Shift+T brings
    /// it back when nothing was archived after it.
    var closedPeek: (url: String, tabID: UUID?, at: Date)?

    private static let sidebarWidth = 280.0
    /// What a new window opens when the sidebar has nothing to show.
    static let startPage = "https://crabrowser.app"

    /// `frame`: where the window opens (a restored or cascaded one); nil lets Windows place it.
    /// `newWindow`: opened by New Window, so it starts with the command bar rather than a page.
    init(store: SidebarStore, session: WindowSession, frame: WindowFrame?, newWindow: Bool = false,
         dispatcher: WinAppSDK.DispatcherQueue, host: BrowserWindowHost) throws {
        self.store = store
        windowID = session.id
        isIncognito = session.isIncognito
        self.host = host
        self.dispatcher = dispatcher
        engine = SuggestionEngine(store: store, commands: { WinKeyBindings.shared.barCommands(display: \.windowsDisplay) },
                                  load: WinSuggestLoader.load)
        commandBar = CommandBarView(engine: engine, store: store, windowID: session.id)
        sidebar = SidebarView(store: store, windowID: session.id, actions: self)
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
        window = try HostWindow(content: makeLayout(), topBar: developerBar.root, sidebarWidth: Self.sidebarWidth, frame: frame)
        window.title = Self.title(nil, incognito: isIncognito)
        hwnd = window.hwnd
        window.onLayout = { [weak self] _ in
            self?.repositionPeeks()
            self?.layoutPanes()
            self?.placeCommandBar()
            self?.placeFindBar()
            self?.placePermissionPrompt()
            self?.hideSiteControlCenter()
        }
        window.onMove = { [weak self] in
            self?.repositionPeeks()
            self?.placeFindBar()
            self?.placePermissionPrompt()
            self?.hideSiteControlCenter()
            self?.toast?.hide()
        }
        window.onMouse = { [weak self] event in self?.handlePaneMouse(event) }
        window.cursor = { [weak self] x, y in self?.paneCursor(x: x, y: y) }
        window.onActivate = { [weak self] in
            guard let self, !self.closing else { return }
            self.store.activeWindowID = self.windowID
        }
        window.onMoveEnded = { [weak self] in self?.saveFrame() }
        window.onFocus = { [weak self] in
            guard let self, !self.closing, !self.commandBar.isOpen else { return }
            // A redraw the store asked for first, so the keyboard goes to the page now selected
            // (a Peek's Add To Split selects the new pane just before the card goes and the window
            // takes the keyboard back).
            if self.refreshQueued { self.refresh() }
            self.focusContent()
        }
        makeCommandBar()
        makeFindBar()
        makeDeveloperBar()
        makePermissionPrompt()
        makeProfileDialog()
        makeSiteControlCenter()
        toast = ToastView(owner: window) { [weak self] in self?.pageOnScreen() }
        // Chromium closes its pages before their parent window goes (CEF's DoClose order).
        window.shouldClose = { [weak self] in
            guard let self, !self.readyToClose else { return true }
            self.saveFrame()
            guard !self.canFinishClosing else { return true }
            self.beginClosing()
            return false
        }
        window.onClose = { [weak self] in
            guard let self else { return }
            self.host?.windowDidClose(self)
        }
        store.activeWindowID = windowID
        if newWindow {
            refresh()
            openCommandBar(.newTab)
            return
        }
        if store.selectedTab(window: windowID) == nil && store.visibleTabs(in: store.focusedSpaceID(window: windowID)).isEmpty {
            store.createTab(url: Self.startPage, window: windowID)
        }
        refresh()
    }

    /// "Cra", or the tab's title before it; a private window says so, as Chrome's do.
    private static func title(_ tab: String?, incognito: Bool) -> String {
        let app = incognito ? "Cra (Incognito)" : "Cra"
        guard let tab, !tab.isEmpty else { return app }
        return "\(tab) - \(app)"
    }

    /// Brings the window to the front (another Cra launch, a link from another app, a Little
    /// Window's page moved in). A redraw the store asked for comes first: taking the front hands
    /// the keyboard to the page on screen, and a stale one taking it would select its tab again
    /// over the one just picked (pageDidReceiveFocus; seen when a Little Window's page moved in).
    func activate() {
        if refreshQueued { refresh() }
        window.activate()
    }

    /// Asks the window to close as its close button does (Ctrl+Shift+W).
    func requestClose() {
        guard !closing, window.shouldClose?() ?? true else { return }
        // After the key's event, as the close button's is: the XAML that delivered the key goes
        // with the window, and tearing it down inside its own handler traps.
        _ = try? dispatcher.tryEnqueue { [weak self] in self?.window?.close() }
    }

    /// Where the window is, for the next launch (windows.json). A minimized or maximized window
    /// keeps the frame it had before.
    func saveFrame() {
        guard !closing, let hwnd = HWND(bitPattern: hwnd), !IsIconic(hwnd), !IsZoomed(hwnd) else { return }
        let frame = window.frame.string
        guard store.window(windowID).id == windowID, store.window(windowID).frame != frame else { return }
        store.updateWindow(windowID) { $0.frame = frame }
    }

    /// The window's frame on screen, for a new window cascaded from it.
    var frame: WindowFrame { window.frame }
    var workArea: WindowFrame? { window.workArea }
    var scale: Double { window.scale }

    /// The tab has a live page in this window.
    func hasPage(_ id: UUID) -> Bool { pages[id] != nil }

    /// A Little Window's live page as tab `id`'s (its "Open in <Space>"): moved into this window,
    /// history, scroll position and sign-ins included (BrowserManager.adopt on the Mac). A page in
    /// another profile than the tab's space loads there again (syncPages).
    func adopt(_ page: WebPage, for id: UUID) {
        guard !closing else { return page.close() }
        pages[id]?.close()
        page.delegate = self
        page.userInfo = id
        page.isVisible = false
        page.move(toParent: hwnd, frame: paneFrames[id] ?? contentFrame())
        livePages.insert(ObjectIdentifier(page))
        pages[id] = page
        queueRefresh()
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
            applyPaneColors(store.focusedSpace(window: windowID).theme)
            downloads.apply(SidebarPalette(store.focusedSpace(window: windowID).theme), fill: sidebar.fill)
            syncPages()
            syncDeveloperBar()
            showAddress(store.selectedTab(window: windowID)?.tab?.url ?? "")
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
        // A page can't change its Chromium profile: one whose tab moved to a space on another
        // profile, or whose space changed profile, closes and loads its address again there
        // (BrowserManager.pruneMissingTabs on the Mac).
        for (id, page) in pages where store.item(id)?.isTab != true || !inRightProfile(page, tab: id) {
            page.close()
            pages[id] = nil
        }
        // Split view: the selected tab's split decides which panes are on screen. An empty pane
        // (Arc's "Search or Enter URL…") has no page yet.
        let selected = store.selectedTab(window: windowID)
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
        window.title = Self.title(selected?.displayTitle, incognito: isIncognito)
    }

    private func inRightProfile(_ page: WebPage, tab id: UUID) -> Bool {
        page.isIncognito || page.profilePath == store.profilePath(item: id)
    }

    private func makePage(for id: UUID, url: String) -> WebPage {
        let page = WebPage(parent: hwnd, frame: paneFrames[id] ?? contentFrame(), url: url, incognito: isIncognito,
                           profilePath: store.profilePath(item: id), delegate: self)
        livePages.insert(ObjectIdentifier(page))
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
        hideSiteControlCenter()
        toast.hide()
        permissionWindow?.hide()
        for request in permissionQueue { request.answer(false) }
        permissionQueue.removeAll()
        let open = Array(pages.values)
        pages.removeAll()
        shownPage = nil
        paneIDs = []
        paneDrag = nil
        for page in open { page.close() }
        // A Peek's card is owned by this window: its page closes before the window goes.
        host?.closePeeks(over: self)
        // Popup hosts and pages already on their way out count too (livePages).
        closeTimer = try? dispatcher.createTimer()
        closeTimer?.interval = TimeSpan(duration: 3 * 10_000_000)
        closeTimer?.isRepeating = false
        closeTimer?.tick.addHandler { [weak self] _, _ in self?.finishClosing() }
        try? closeTimer?.start()
        if canFinishClosing { finishClosing() }
    }

    /// No page of this window's and no Peek over it waits for Chromium.
    private var canFinishClosing: Bool { livePages.isEmpty && host?.hasPeek(over: self) != true }

    /// A Peek over this window closed: the window may be waiting for it to go.
    func peekDidClose() {
        if host?.hasPeek(over: self) != true {
            sidebar.peekBadge = nil
            queueRefresh()
        }
        if closing, canFinishClosing { _ = try? dispatcher.tryEnqueue { [weak self] in self?.finishClosing() } }
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
        for height in [UI.auto, UI.auto, UI.star] { sidebarPanel.rowDefinitions.append(UI.row(height)) }

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

        // Arc's URL pill: the address, then the sliders that open the Site Control Center.
        slidersGlyph.glyph = WinGlyph.code("slider.horizontal.3")
        slidersGlyph.fontSize = 13
        sliders = UI.button(slidersGlyph) { [weak self] in self?.toggleSiteControlCenter() }
        try? ToolTipService.setToolTip(sliders, "Site Controls")
        try? AutomationProperties.setName(sliders, "Site Controls")
        let pill = Grid()
        pill.columnDefinitions.append(UI.column(UI.star))
        pill.columnDefinitions.append(UI.column(UI.auto))
        pill.margin = Thickness(left: 0, top: 8, right: 0, bottom: 8)
        pill.children.append(addressButton)
        try? Grid.setColumn(addressButton, 0)
        pill.children.append(sliders)
        try? Grid.setColumn(sliders, 1)

        let parts: [FrameworkElement] = [toolbar, pill, sidebar.root]
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
        slidersGlyph.foreground = sidebar.secondaryTextColor
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
        let fillingEmptyPane = store.selectedTab(window: windowID)?.isEmptyTab == true
        let prefill = mode == .editURL && !fillingEmptyPane ? store.selectedTab(window: windowID)?.tab?.url : nil
        let effective: CommandBarMode = mode == .editURL && (store.selectedTab(window: windowID) == nil || fillingEmptyPane) ? .newTab : mode
        commandBarDeactivated = false
        commandBar.open(mode: effective, prefill: prefill, theme: store.focusedSpace(window: windowID).theme)
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
            let fillsEmptyPane = store.selectedTab(window: windowID)?.isEmptyTab == true
            if mode == .editURL || fillsEmptyPane, store.selectedTabID(window: windowID) != nil {
                loadInSelectedTab(url)
            } else {
                store.createTab(url: url, window: windowID)
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
            store.selectTab(id, window: windowID)
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
            store.focusSpace(id, window: windowID)
        case .moveToSpace(let id):
            if let t = store.selectedTabID(window: windowID) { _ = store.moveTabAndFollow(t, toSpace: id, window: windowID) }
        case .moveToFolder(let id):
            if let t = store.selectedTabID(window: windowID) { store.moveItem(t, to: id, index: nil) }
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
        let tab = store.createTab(url: url, select: false, window: windowID)
        store.markUnread(tab.id, false)  // Arc saves these read, unlike a link opened in the background
        return true
    }

    private func loadInSelectedTab(_ url: String) {
        guard let id = store.selectedTabID(window: windowID) else { return }
        if let page = pages[id] {
            page.loadURL(url)
            page.setFocused(true)
        } else {
            // An empty tab: its first page.
            store.updateTab(id, url: url)
        }
    }

    /// An action by its id (KeyBindingDefaults.windows): a command row or a shortcut. False
    /// for an id the Windows app doesn't perform yet.
    @discardableResult
    func perform(_ id: String) -> Bool {
        switch id {
        case "find": showFindBar()
        case "findNext": findNext(forward: true)
        case "findPrevious": findNext(forward: false)
        case "settings": openSettings()
        case "newWindow": host?.openNewWindow(incognito: false)
        case "newIncognitoWindow": host?.openNewWindow(incognito: true)
        case "newLittleWindow": host?.newLittleWindow()
        case "closeLittleWindows": host?.closeLittleWindows()
        case "closeWindow": requestClose()
        case "changeProfile": if !isIncognito { showChangeProfile(forSpace: store.focusedSpaceID(window: windowID)) }
        case "newTab": beginNewTab()
        case "editURL": openCommandBar(.editURL)
        case "reopenClosedTab": reopenClosedTab()
        case "closeTab": closeCurrentTab()
        case "reload": reload(ignoringCache: false)
        case "hardReload": reload(ignoringCache: true)
        case "pinTab": if let t = store.selectedTabID(window: windowID) { store.togglePinned(t) }
        case "nextTab": cycleTab(1)
        case "previousTab": cycleTab(-1)
        case "nextSpace": store.focusSpace(offset: 1, window: windowID)
        case "previousSpace": store.focusSpace(offset: -1, window: windowID)
        case "copyURL": copyURL(markdown: false)
        case "copyURLMarkdown": copyURL(markdown: true)
        case "capturePage": capture(fullPage: false)
        case "clearCache": shownPage?.clearSiteDataAndReload(cookies: false)
        case "clearCookies": shownPage?.clearSiteDataAndReload(cookies: true)
        case "devTools": shownPage?.runDevTools(.toggle)
        case "jsConsole": shownPage?.runDevTools(.console)
        case "inspectElement": shownPage?.runDevTools(.inspect)
        case "networkPanel": shownPage?.runDevTools(.network)
        case "toggleDeveloperMode": toggleDeveloperMode()
        case "goBack": shownPage?.goBack()
        case "goForward": shownPage?.goForward()
        case "addSplitView": addSplitPane()
        case "closeSplitPane": if let t = store.selectedTabID(window: windowID) { closeSplitPane(t) }
        case "separateFromSplit": if let t = store.selectedTabID(window: windowID) { separatePane(t) }
        case "flipSplitOrientation": if let t = store.selectedTabID(window: windowID), let split = store.splitContaining(t) { store.flipSplitOrientation(split.id) }
        case "nextSplitPane": cycleSplitPane(1)
        case "previousSplitPane": cycleSplitPane(-1)
        default:
            if id.hasPrefix("space"), let n = Int(id.dropFirst(5)), (1...9).contains(n) {
                store.focusSpace(number: n, window: windowID)
                return true
            }
            guard id.hasPrefix("item"), let n = Int(id.dropFirst(4)), (1...9).contains(n) else { return false }
            selectTab(number: n)
        }
        return true
    }

    // MARK: Commands

    private func closeCurrentTab() {
        if let id = store.selectedTabID(window: windowID) { closeTab(id) }
    }

    /// Selects the tab `delta` rows away in the space's favorites, pinned and Today tabs.
    private func cycleTab(_ delta: Int) {
        let tabs = store.visibleTabs(in: store.focusedSpaceID(window: windowID))
        guard !tabs.isEmpty else { return }
        let idx = store.selectedTabID(window: windowID).flatMap { id in tabs.firstIndex { $0.id == id } } ?? -1
        let n = tabs.count
        store.selectTab(tabs[((idx + delta) % n + n) % n].id, window: windowID)
    }

    /// Ctrl+1…8 the nth tab, Ctrl+9 the last (Arc's "Go to Sidebar Item N").
    private func selectTab(number n: Int) {
        let tabs = store.visibleTabs(in: store.focusedSpaceID(window: windowID))
        guard !tabs.isEmpty else { return }
        store.selectTab((n == 9 ? tabs.last : tabs[min(n, tabs.count) - 1])?.id, window: windowID)
    }

    private func reopenClosedTab() {
        // Arc: a Peek closed after the last archived tab comes back, over the tab it came from.
        if !isIncognito, let peek = closedPeek,
           PeekTrigger.reopensClosedPeek(closedAt: peek.at, lastArchivedAt: store.archive.first?.archivedAt) {
            closedPeek = nil
            if let id = peek.tabID, store.item(id) != nil { store.selectTab(id, window: windowID) }
            host?.openPeek(url: peek.url, over: self, fromTab: peek.tabID)
        } else {
            store.reopenLastArchived()
        }
    }

    // MARK: Peek

    /// Where a Peek over this window goes now (its client area on screen, the sidebar's width).
    func peekPlacement() -> PeekPlacement? {
        guard !closing, let host = HWND(bitPattern: hwnd) else { return nil }
        var origin = POINT(x: 0, y: 0)
        _ = ClientToScreen(host, &origin)
        let size = window.appWindow.clientSize
        return PeekPlacement(client: PixelRect(x: origin.x, y: origin.y, width: size.width, height: size.height),
                             sidebar: window.sidebarWidth, scale: window.scale)
    }

    /// Arc badges the tab a Peek came from with the peeked page's favicon.
    func showPeekBadge(tab id: UUID?, url: String) {
        sidebar.peekBadge = id.map { ($0, FaviconKey.key(for: url)) }
        queueRefresh()
    }

    private func repositionPeeks() {
        host?.repositionPeeks(over: self)
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
        findBar.apply(dark: store.focusedSpace(window: windowID).theme.isDark)
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

    // MARK: Settings

    /// Ctrl+, (Arc's ⌘,): the Settings window, centred on this one when it opens.
    private func openSettings() {
        if Self.settingsWindow == nil {
            do {
                Self.settingsWindow = try SettingsWindow(store: store)
            } catch {
                print("The Settings window could not be made: \(error)")
                return
            }
        }
        Self.settingsWindow?.onNewProfile = { [weak self] in self?.showNewProfile(ticked: []) }
        Self.settingsWindow?.show(over: window)
    }

    // MARK: Developer Mode

    private func makeDeveloperBar() {
        developerBar.onAction = { [weak self] id in self?.perform(id) }
        developerBar.onKey = { [weak self] key in self?.handleShortcut(key) ?? false }
        developerBar.onEditEnded = { [weak self] in self?.focusContent() }
        // Arc's developer bar edits its full URL in place (ContentPanelTextField): what's typed
        // loads in the tab, or searches.
        developerBar.onCommit = { [weak self] typed in
            guard let self else { return }
            self.loadInSelectedTab(SuggestionEngine.looksLikeURL(typed) ? SuggestionEngine.urlFromInput(typed) : self.engine.searchURL(typed))
        }
    }

    /// Arc's per-site Developer Mode (View ▸ Developer): the bar over the page, the site's host
    /// and port under its tabs' titles, and a ring round the open one.
    private func toggleDeveloperMode() {
        guard let url = store.selectedTab(window: windowID)?.tab?.url, !url.isEmpty else { return }
        store.settings.toggleDeveloperMode(url: url)
    }

    /// The bar shows over the open tab's page when its site is in Developer Mode, not in a split
    /// (the Mac's ToolbarComposition kind `.developer`), and the pages move down under it.
    private func syncDeveloperBar() {
        let tab = store.selectedTab(window: windowID)
        let url = tab?.tab?.url ?? ""
        let on = paneIDs.count <= 1 && !url.isEmpty && store.settings.isDeveloperMode(url: url)
        // An edit ends without loading when the bar goes or shows another tab (as on the Mac):
        // the keyboard goes back to the page.
        if developerBar.isEditing, !on || tab?.id != developerTabID {
            developerBar.resignEditing()
            focusContent()
        }
        developerTabID = on ? tab?.id : nil
        if on { developerBar.show(url: url, theme: store.focusedSpace(window: windowID).theme) }
        window.topBarHeight = on ? DeveloperBarView.height : 0
    }

    // MARK: Keys

    /// Shortcuts Cra keeps from the page: Windows' table with the user's own keys (Settings ▸
    /// Shortcuts, keybindings.json).
    /// A Ctrl+Alt chord that types a character on the keyboard layout (AltGr+N is ń on Polish
    /// keyboards) is left to type.
    private func handleShortcut(_ key: KeyPress) -> Bool {
        guard !WinKeyboard.typesCharacter(key),
              let chord = KeyChord(windowsVirtualKey: key.keyCode, control: key.control, shift: key.shift, alt: key.alt),
              let action = WinKeyBindings.shared.action(matching: chord) else { return false }
        return perform(action.id)
    }

    private func reload(ignoringCache: Bool) {
        if ignoringCache { shownPage?.reloadIgnoringCache() } else { shownPage?.reload() }
    }

    // MARK: Split view

    /// Arc's "Add Split View" (Ctrl+Shift+=): an empty pane next to the focused one, the command
    /// bar asking what it shows (MainWindowController.addSplitPane). Arc stops at four panes.
    private func addSplitPane() {
        guard let current = store.selectedTabID(window: windowID) else { return beginNewTab() }
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
        store.selectTab(id, window: windowID)
    }

    /// Switch to Next / Previous Split View.
    private func cycleSplitPane(_ delta: Int) {
        guard let current = store.selectedTabID(window: windowID),
              let next = SplitPaneLayout.pane(delta, from: current, in: store.paneTabIDs(for: current)) else { return }
        store.selectTab(next, window: windowID)
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
                if store.selectedTabID(window: windowID) == id { openCommandBar(.editURL) } else { store.selectTab(id, window: windowID) }
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

    private func makePermissionPrompt() {
        permissionPrompt.onAnswer = { [weak self] allowed in self?.answerPermission(allowed) }
        do {
            permissionWindow = try FloatingWindow(owner: window, content: permissionPrompt.root)
            // Alt+F4 on the prompt blocks, as closing the Mac's sheet would.
            permissionWindow?.onClose = { [weak self] in self?.answerPermission(false) }
        } catch {
            print("The permission prompt's window could not be made: \(error)")
        }
    }

    /// The oldest request's question over the page. A page that closed has no say any more.
    private func showNextPermission() {
        permissionQueue.removeAll { $0.page.page == nil || $0.page.page?.isClosed == true }
        guard let request = permissionQueue.first, let permissionWindow, !closing else {
            permissionWindow?.hide()
            return
        }
        permissionHeight = permissionPrompt.show(origin: request.origin, kinds: UInt(request.kinds.rawValue),
                                                 dark: store.focusedSpace(window: windowID).theme.isDark)
        placePermissionPrompt()
        permissionWindow.show { [weak self] in self?.permissionPrompt.focus() }
    }

    private func answerPermission(_ allowed: Bool) {
        guard !permissionQueue.isEmpty else { return }
        permissionQueue.removeFirst().answer(allowed)
        permissionWindow?.hide()
        if permissionQueue.isEmpty {
            if let window = HWND(bitPattern: hwnd) { _ = SetForegroundWindow(window) }
            focusContent()
        }
        showNextPermission()
    }

    /// Centred over the page area, 12 DIPs below its top (where the Mac's sheet drops from).
    private func placePermissionPrompt() {
        guard let permissionWindow, !permissionQueue.isEmpty, let window, let host = HWND(bitPattern: hwnd) else { return }
        let scale = window.scale, area = window.contentFrame
        let width = Int32((PermissionPromptView.width * scale).rounded()), height = Int32((permissionHeight * scale).rounded())
        var corner = POINT(x: area.x + (area.width - width) / 2, y: area.y + Int32((12 * scale).rounded()))
        _ = ClientToScreen(host, &corner)
        permissionWindow.place(origin: PointInt32(x: corner.x, y: corner.y), size: SizeInt32(width: width, height: height))
    }

    // MARK: Profiles

    private func makeProfileDialog() {
        profileDialog.onCreate = { [weak self] name, spaces in
            self?.store.createProfile(name: name, forSpaces: spaces)
            self?.hideProfileDialog()
        }
        profileDialog.onChange = { [weak self] space, profile in
            self?.store.setProfile(profile, forSpace: space)
            self?.hideProfileDialog()
        }
        profileDialog.onCancel = { [weak self] in self?.hideProfileDialog() }
        profileDialog.onResize = { [weak self] height in
            self?.profileDialogHeight = height
            self?.placeProfileDialog()
        }
        do {
            profileWindow = try FloatingWindow(owner: window, content: profileDialog.root)
            // Alt+F4 on the dialog cancels it.
            profileWindow?.onClose = { [weak self] in self?.hideProfileDialog() }
        } catch {
            print("The profile dialog's window could not be made: \(error)")
        }
    }

    /// Create a new Profile (Set Profile ▸ New Profile…, Settings ▸ Profiles ▸ Create Profile…),
    /// with `ticked` spaces chosen on its second step.
    func showNewProfile(ticked: Set<UUID>) {
        guard !closing else { return }
        profileDialogHeight = profileDialog.showNew(spaces: store.profileSpaces, ticked: ticked)
        presentProfileDialog()
    }

    /// Spaces ▸ Change Profile for the space.
    func showChangeProfile(forSpace id: UUID) {
        guard !closing, let space = store.space(id), !store.isIncognito(space: id) else { return }
        profileDialogHeight = profileDialog.showChange(space: space, profiles: store.profiles, spaces: store.profileSpaces)
        presentProfileDialog()
    }

    /// After the event that asked for it (a menu item, a key), as the command bar opens.
    private func presentProfileDialog() {
        _ = try? dispatcher.tryEnqueue { [weak self] in
            guard let self, let profileWindow = self.profileWindow, !self.closing else { return }
            self.placeProfileDialog()
            profileWindow.show { [weak self] in self?.profileDialog.focus() }
        }
    }

    private func hideProfileDialog() {
        guard profileWindow?.isVisible == true else { return }
        profileWindow?.hide()
        if let window = HWND(bitPattern: hwnd) { _ = SetForegroundWindow(window) }
        focusContent()
    }

    /// Centred on the window, as Arc's card is.
    private func placeProfileDialog() {
        guard let profileWindow, let window else { return }
        let scale = window.scale
        let position = window.appWindow.position, size = window.appWindow.size
        let width = (ProfileDialogView.width * scale).rounded(), height = (profileDialogHeight * scale).rounded()
        let left = Double(position.x) + (Double(size.width) - width) / 2
        let top = Double(position.y) + max(0, (Double(size.height) - height) / 2)
        profileWindow.place(origin: PointInt32(x: Int32(left.rounded()), y: Int32(top.rounded())),
                            size: SizeInt32(width: Int32(width), height: Int32(height)))
    }

    // MARK: Site Control Center

    private func makeSiteControlCenter() {
        siteControl.ownerWindow = { [weak self] in self?.siteControlWindow?.hwnd ?? 0 }
        siteControl.onEscape = { [weak self] in self?.hideSiteControlCenter(refocus: true) }
        do {
            siteControlWindow = try FloatingWindow(owner: window, content: siteControl.root)
            // A click anywhere else closes it, as Arc's transient popover.
            siteControlWindow?.onDeactivate = { [weak self] in
                self?.siteControlClosed = Date()
                self?.hideSiteControlCenter()
            }
        } catch {
            print("The Site Control Center's window could not be made: \(error)")
        }
    }

    private var siteControlShown: Bool { siteControlWindow?.isVisible == true }

    /// The sliders: the Site Control Center for the page on screen, or closes it.
    private func toggleSiteControlCenter() {
        if siteControlShown { return hideSiteControlCenter(refocus: true) }
        // The press that just closed it from outside.
        guard Date().timeIntervalSince(siteControlClosed) > 0.3 else { return }
        _ = try? dispatcher.tryEnqueue { [weak self] in self?.showSiteControlCenter() }
    }

    private func showSiteControlCenter() {
        guard !closing, let siteControlWindow, let window, let host = HWND(bitPattern: hwnd) else { return }
        let url = store.selectedTab(window: windowID)?.tab?.url ?? ""
        let ssl = shownPage?.sslStatus
        let secure = ConnectionSecurity.isSecure(url: url, status: ssl?.status)
        var actions = SiteControlCenterView.Actions()
        actions.perform = { [weak self] action in self?.siteControlAction(action) }
        actions.more = { [weak self] item in self?.siteControlMore(item, url: url) }
        actions.toggle = { [weak self] setting in
            guard let self else { return }
            SiteControlCenter.toggle(setting, in: &self.store.settings, url: url)
        }
        if ssl?.hasCertificate == true {
            actions.showCertificate = { [weak self] in
                guard let self else { return }
                self.hideSiteControlCenter(refocus: true)
                self.shownPage?.showCertificate(owner: self.hwnd)
            }
        }
        siteControl.actions = actions
        // Windows has none of the three switches' features yet.
        siteControl.build(url: url, secure: secure, rows: SiteControlCenter.settingRows(store.settings, url: url, available: []),
                          dark: WinAppearance.isDark)
        // Under the sliders, its right edge at theirs, kept on the window.
        let scale = window.scale
        let width = Int32((Double(SiteControlCenter.Metrics.width) * scale).rounded())
        let height = Int32((siteControl.height * scale).rounded())
        var corner = POINT(x: 0, y: 0)
        if let transform = try? sliders.transformToVisual(nil),
           let origin = try? transform.transformPoint(WindowsFoundation.Point(x: 0, y: 0)) {
            let right = (Double(origin.x) + sliders.actualWidth) * scale
            let bottom = (Double(origin.y) + sliders.actualHeight + 4) * scale
            corner = POINT(x: max(0, Int32(right.rounded()) - width), y: Int32(bottom.rounded()))
        }
        _ = ClientToScreen(host, &corner)
        siteControlWindow.place(origin: PointInt32(x: corner.x, y: corner.y), size: SizeInt32(width: width, height: height))
        siteControlWindow.show { [weak self] in self?.siteControl.focus() }
    }

    /// `refocus`: the page takes the keyboard back if the popover had it (a click elsewhere
    /// already put it where it belongs).
    private func hideSiteControlCenter(refocus: Bool = false) {
        guard siteControlShown, let siteControlWindow else { return }
        let hadFront = GetForegroundWindow() == HWND(bitPattern: siteControlWindow.hwnd)
        siteControlWindow.hide()
        guard refocus, hadFront, !closing, let window = HWND(bitPattern: hwnd) else { return }
        _ = SetForegroundWindow(window)
        focusContent()
    }

    /// Every action closes the popover first, as in Arc.
    private func siteControlAction(_ action: SiteControlCenter.Action) {
        hideSiteControlCenter(refocus: true)
        switch action {
        case .share:
            guard let tab = store.selectedTab(window: windowID), let url = tab.tab?.url, !url.isEmpty else { return }
            WinShell.share(url: url, title: tab.displayTitle, owner: hwnd)
        case .copyURL: copyURL(markdown: false)
        case .capture: capture(fullPage: false)
        case .captureFullPage: capture(fullPage: true)
        }
    }

    private func siteControlMore(_ item: SiteControlCenter.MoreItem, url: String) {
        hideSiteControlCenter(refocus: true)
        switch item {
        case .clearCache: shownPage?.clearSiteDataAndReload(cookies: false)
        case .clearCookies: shownPage?.clearSiteDataAndReload(cookies: true)
        case .siteSettings: if let settings = SiteControlCenter.siteSettingsURL(for: url) { store.createTab(url: settings, window: windowID) }
        case .manageExtensions: store.createTab(url: SiteControlCenter.manageExtensionsURL, window: windowID)
        case .addExtension: store.createTab(url: SiteControlCenter.addExtensionURL, window: windowID)
        }
    }

    // MARK: Copy and capture

    /// Ctrl+Shift+C (Arc's ⇧⌘C): the page's address; with Alt, as a Markdown link.
    private func copyURL(markdown: Bool) {
        guard let tab = store.selectedTab(window: windowID), let url = tab.tab?.url, !url.isEmpty else { return }
        guard WinShell.copy(markdown ? "[\(tab.displayTitle)](\(url))" : url) else { return }
        if markdown {
            showToast("Copied URL as Markdown")
        } else {
            let title = tab.displayTitle
            showToast("Copied Current URL", action: ToastView.Action(title: "Share") { [weak self] in
                guard let self else { return }
                WinShell.share(url: url, title: title, owner: self.hwnd)
            })
        }
    }

    /// Arc's "Capture this page" and "Capture the full page": the PNG goes on the clipboard and
    /// the toast's Save puts it in a file. Picking an area of the page, as the Mac's capture
    /// overlay does, comes later; this one takes what the page shows.
    private func capture(fullPage: Bool) {
        guard let page = shownPage, !capturing else { return }
        capturing = true
        let shoot: (String) -> Void = { [weak self, weak page] params in
            guard let page else {
                self?.capturing = false
                return
            }
            page.sendDevToolsMethod("Page.captureScreenshot", params: params) { shot, error in self?.finishCapture(shot, error: error) }
        }
        guard fullPage else { return shoot(PageCapture.screenshotParams()) }
        showToast("Capture in Progress")
        page.sendDevToolsMethod("Page.getLayoutMetrics") { [weak self] result, error in
            guard let size = result.flatMap(PageCapture.contentSize(layoutMetrics:)) else {
                self?.finishCapture(nil, error: error)
                return
            }
            shoot(PageCapture.screenshotParams(fullPageWidth: size.width, height: size.height))
        }
    }

    private func finishCapture(_ shot: String?, error: String?) {
        capturing = false
        guard let png = shot.flatMap(PageCapture.png(screenshot:)), WinShell.copy(png: png) else {
            print("Cra: capture failed: \(error ?? "no data")")
            showToast("Capture Failed")
            return
        }
        showToast("Screenshot Copied to Clipboard", action: ToastView.Action(title: "Save") { [weak self] in self?.saveCapture(png) })
    }

    /// The toast's Save: Arc's "Save Capture Image", in Downloads.
    private func saveCapture(_ png: Data) {
        guard let path = WinShell.savePNG(owner: hwnd, title: "Save Capture Image", fileName: PageCapture.fileName(at: Date())) else { return }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            print("Cra: saving a capture failed: \(error)")
            showToast("Failed to Save Capture")
        }
    }

    func showToast(_ text: String, action: ToastView.Action? = nil) {
        guard !closing else { return }
        toast.show(text, action: action, theme: store.focusedSpace(window: windowID).theme)
    }

    /// The focused pane's frame on screen (the whole page area without a split), for the toast.
    private func pageOnScreen() -> (left: Int32, top: Int32, right: Int32, scale: Double)? {
        guard let window, let host = HWND(bitPattern: hwnd) else { return nil }
        let frame = shownTabID.flatMap { paneFrames[$0] } ?? window.contentFrame
        var topLeft = POINT(x: frame.x, y: frame.y)
        _ = ClientToScreen(host, &topLeft)
        return (topLeft.x, topLeft.y, topLeft.x + frame.width, window.scale)
    }
}

// MARK: - Sidebar → window

extension BrowserWindow: SidebarActions {
    /// Set Profile ▸ New Profile… on a space's menu: the space starts ticked.
    func newProfile(forSpace id: UUID) { showNewProfile(ticked: [id]) }

    /// Today tabs are archived. Pinned tabs and favorites stay; they unload and return to
    /// their pinned page (Arc's close-on-pinned behaviour, MainWindowController.closeTab).
    func closeTab(_ id: UUID) {
        guard let item = store.item(id), item.isTab else { return }
        if store.isPinned(id) {
            let panes = store.paneTabIDs(for: id)
            let wasSelected = store.selectedTabID(window: windowID).map(panes.contains) ?? false
            for p in panes {
                _ = store.resetPinnedTab(p)
                pages[p]?.close()
                pages[p] = nil
            }
            if wasSelected {
                // Back to the tab used before, if it is still open; an unloaded pinned tab doesn't count.
                let back = store.recentTabs(in: store.focusedSpaceID(window: windowID), limit: .max)
                    .first { !panes.contains($0) && (!store.isPinned($0) || pages[$0] != nil) }
                store.selectTab(back, window: windowID)
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
        store.selectTab(last.id, window: windowID)
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

    /// Kept under the page's host, as the Mac's BrowserManager does; the tab takes that key.
    func page(_ page: WebPage, didLoadFavicon png: Data, forURL iconURL: String) {
        guard let id = tabID(of: page), let tab = store.item(id)?.tab,
              let key = FaviconKey.key(for: tab.url) ?? tab.faviconKey else { return }
        Favicons.shared.store(png: png, forKey: key, persist: !store.isIncognito(item: id))
        if tab.faviconKey != key { store.updateTab(id, url: tab.url) }
    }

    func page(_ page: WebPage, didReportThemeColor hex: String) {
        if let id = tabID(of: page) { store.setThemeColor(id, hex) }
    }

    /// In the space of the tab it came from, right below it when that is a Today tab
    /// (SidebarStore.openLinkTab, #202).
    func page(_ page: WebPage, requestsNewTabWithURL url: String, inBackground background: Bool) {
        store.openLinkTab(url, from: tabID(of: page), inBackground: background, window: windowID)
    }

    /// Arc's Peek (PeekTrigger, Settings ▸ Tabs ▸ Links): the link opens over the window and the
    /// tab stays put. Never in a private window.
    func page(_ page: WebPage, opensPeekForURL url: String, shiftClick: Bool, newTab: Bool) -> Bool {
        guard !isIncognito, !closing, !url.lowercased().hasPrefix("cra:"), let id = tabID(of: page), pages[id] === page else { return false }
        let from = page.currentURL.isEmpty ? (store.item(id)?.tab?.url ?? "") : page.currentURL
        guard PeekTrigger.opens(url, from: from, shiftClick: shiftClick, newTab: newTab, fromPinned: store.isPinned(id),
                                settings: store.settings) else { return false }
        // Not from inside Chromium's navigation callback.
        _ = try? dispatcher.tryEnqueue { [weak self] in
            guard let self, !self.closing else { return }
            self.host?.openPeek(url: url, over: self, fromTab: id)
        }
        return true
    }

    func page(_ page: WebPage, popupHostForURL url: String, inBackground background: Bool) -> WebPage? {
        // The popup gets a tab of its own; its page is the host Chromium opens it in.
        let space = tabID(of: page).flatMap { store.spaceID(ofItem: $0) }
        let tab = store.createTab(url: url, in: space, select: false, window: windowID)
        let host = WebPage(popupHostIn: hwnd, frame: contentFrame(), incognito: page.isIncognito, profilePath: page.profilePath,
                           delegate: self)
        livePages.insert(ObjectIdentifier(host))
        host.userInfo = tab.id
        host.isVisible = false
        pages[tab.id] = host
        if !background { store.selectTab(tab.id, window: windowID) }
        return host
    }

    func page(_ page: WebPage, handleKey key: KeyPress) -> Bool {
        guard !key.isRepeat || key.keyCode == 0x09 else { return false }
        return handleShortcut(key)
    }

    /// In DevTools only their own commands, on the page they inspect: every other key is the
    /// frontend's (Ctrl+F searches the panel, Ctrl+R reloads the page from there, as in Chrome).
    func page(_ page: WebPage, handleDevToolsKey key: KeyPress) -> Bool {
        guard !key.isRepeat,
              let chord = KeyChord(windowsVirtualKey: key.keyCode, control: key.control, shift: key.shift, alt: key.alt),
              let action = WinKeyBindings.shared.action(matching: chord) else { return false }
        switch action.id {
        case "devTools": page.runDevTools(.toggle)
        case "jsConsole": page.runDevTools(.console)
        case "inspectElement": page.runDevTools(.inspect)
        default: return false
        }
        return true
    }

    func page(_ page: WebPage, didFindMatches count: Int, activeMatch: Int) {
        guard findVisible, page === shownPage else { return }
        findBar.report(matches: count, active: activeMatch)
    }

    func page(_ page: WebPage, didUpdateDownload download: DownloadInfo) {
        if windowDownloads.insert(download.identifier).inserted {
            // Chrome's glyph would fly from the page's top left to a toolbar Cra hides; the
            // sidebar's downloads button shows the progress (ChromeDownloadAnimation on the Mac).
            cra_hide_download_started_animation()
        }
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
        guard !closing else { return answer(false) }
        permissionQueue.append((WeakPage(page), origin, kinds, answer))
        if permissionQueue.count == 1 { showNextPermission() }
    }

    /// A click into another pane focuses it (Arc: the split's focusItemID follows the click).
    /// Not while a redraw is waiting: the panes on screen are then the old selection's, and a
    /// stale page taking the keyboard would select its tab again over the one just picked.
    func pageDidReceiveFocus(_ page: WebPage) {
        guard !closing, !refreshQueued, let id = tabID(of: page), id != store.selectedTabID(window: windowID),
              paneIDs.contains(id) else { return }
        store.selectTab(id, window: windowID)
    }

    func pageDidClose(_ page: WebPage) {
        livePages.remove(ObjectIdentifier(page))
        if closing {
            // After this callback: it comes from inside CEF's OnBeforeClose, and destroying the
            // pages' parent window there crashed libcef.
            if canFinishClosing {
                _ = try? dispatcher.tryEnqueue { [weak self] in self?.finishClosing() }
            }
            return
        }
        // Chromium dismissed its requests; the prompt moves on if it was asking for this page.
        if permissionQueue.first?.page.page === page {
            permissionQueue.removeFirst()
            permissionWindow?.hide()
            showNextPermission()
        }
        permissionQueue.removeAll { $0.page.page === page }
        guard let id = tabID(of: page), pages[id] === page else { return }
        pages[id] = nil
        // window.close(): the page's tab goes as a closed tab would.
        if page.closedByPage { closeTab(id) }
    }
}

/// A page held without keeping it alive (a permission request waiting its turn).
struct WeakPage {
    weak var page: WebPage?
    init(_ page: WebPage) { self.page = page }
}
