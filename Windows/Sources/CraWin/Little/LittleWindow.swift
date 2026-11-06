import CraCore
import Foundation
import Observation
import UWP
import WinAppSDK
import WindowsFoundation
import WinSDK
import WinUI

/// Arc's Little Arc, Cra's Little Window (the Mac's LittleWindowController): one page in a small
/// window of its own, the navy strip over it (LittleStripView), opened with Ctrl+Alt+N from any
/// app and by links a Little Window's page opens in a new tab. "Open in <Space>" (Ctrl+O) moves the
/// live page into a browser window as a Today tab, history and sign-ins included; closing archives
/// it to the Library. Little Windows are normal browsing: never in a private window's profile.
///
/// The window keeps Windows' own title bar, in the strip's colour (the Mac hides its title bar
/// behind the strip, beside the traffic lights).
@MainActor
final class LittleWindow {
    let store: SidebarStore
    private weak var list: WindowList?
    private let dispatcher: WinAppSDK.DispatcherQueue
    private(set) var window: HostWindow!
    private let strip = LittleStripView()
    /// The page on screen; nil once it has moved into a browser window or closed.
    private(set) var page: WebPage?
    /// Every page this window made that Chromium hasn't finished closing (a profile change makes
    /// a new one): the window waits for them before it goes (CEF's DoClose order).
    private var livePages: Set<ObjectIdentifier> = []
    /// Hosts a page's window.open (a sign-in popup); its address arrives after it shows.
    private let isPopupHost: Bool
    private var url = ""
    private var title = ""
    /// The space "Open in" names.
    private var targetSpaceID: UUID
    /// The space a link asked for (links from other apps, a later PR): "Open in" stays on it
    /// until the user switches spaces from this window's command bar.
    private var requestedSpaceID: UUID?
    /// The page's profile; nil is Default.
    private var profileID: UUID?
    /// Archived or moved into a browser window: a later close must not archive it again.
    private var promoted = false
    private var closing = false
    private var readyToClose = false
    private var closeTimer: WinAppSDK.DispatcherQueueTimer?
    private var refreshQueued = false
    /// The window's size when it was last saved or opened (a move alone isn't a resize).
    private var savedSize: (Double, Double) = (0, 0)

    private var engine: SuggestionEngine!
    private var commandBar: CommandBarView!
    private var commandWindow: FloatingWindow?
    private var commandBarHeight = CommandBarView.height(forRows: 0)
    private var commandBarDeactivated = false
    private var toast: ToastView!
    private var permissionQueue: [(page: WeakPage, origin: String, kinds: PermissionKinds, answer: (Bool) -> Void)] = []
    private let permissionPrompt = PermissionPromptView()
    private var permissionWindow: FloatingWindow?
    private var permissionHeight = 120.0

    var currentURL: String {
        let live = page?.currentURL ?? ""
        return live.isEmpty ? url : live
    }

    var hasPage: Bool { !currentURL.isEmpty && currentURL != "about:blank" }

    /// `url` nil makes a popup host for `opener`'s window.open; "" an empty window that asks for an
    /// address. `index`: Little Windows already open, for the cascade. `scale`: the DIP scale to
    /// place it with (the window corrects it once it knows its monitor's).
    init(store: SidebarStore, url: String?, opener: WebPage?, index: Int, scale: Double,
         dispatcher: WinAppSDK.DispatcherQueue, list: WindowList) throws {
        self.store = store
        self.list = list
        self.dispatcher = dispatcher
        isPopupHost = url == nil
        targetSpaceID = store.littleWindowTarget(requested: nil)
        // The page's sign-ins (#172): a link or popup from a Little Window stays in its page's
        // profile (Chromium hosts a popup in its opener's); otherwise the target space's.
        profileID = opener.map { store.profileID(path: $0.profilePath) } ?? store.littleWindowProfile(forSpace: targetSpaceID)
        engine = SuggestionEngine(store: store, commands: { WinKeyBindings.shared.barCommands(display: \.windowsDisplay) },
                                  load: WinSuggestLoader.load)
        commandBar = CommandBarView(engine: engine, store: store, windowID: store.lastNormalWindowID)

        let size = LittleWindowLayout.size(saved: store.prefs.littleWindowSize)
        window = try HostWindow(content: Grid(), topBar: strip.root, sidebarWidth: 0,
                                frame: Self.placement(size: size, index: index, scale: scale))
        window.topBarHeight = Double(LittleWindowLayout.barHeight)
        if abs(window.scale - scale) > 0.01 {
            // Opened on a monitor with another scale than guessed: placed again in its DIPs.
            let frame = Self.placement(size: size, index: index, scale: window.scale)
            try? window.appWindow.moveAndResize(RectInt32(x: Int32(frame.x), y: Int32(frame.y),
                                                          width: Int32(frame.width), height: Int32(frame.height)))
        }
        savedSize = (window.frame.width, window.frame.height)
        styleTitleBar()
        window.title = "Little Window"

        window.onLayout = { [weak self] frame in
            self?.page?.frame = frame
            self?.placeCommandBar()
            self?.placePermissionPrompt()
        }
        window.onMove = { [weak self] in
            self?.placeCommandBar()
            self?.placePermissionPrompt()
            self?.toast?.hide()
        }
        window.onFocus = { [weak self] in
            guard let self, !self.closing, !self.commandBar.isOpen else { return }
            self.focusPage()
        }
        window.onActivate = { [weak self] in self?.refresh() }
        window.onMoveEnded = { [weak self] in self?.saveSize() }
        window.shouldClose = { [weak self] in
            guard let self, !self.readyToClose else { return true }
            self.beginClosing()
            return self.readyToClose
        }
        window.onClose = { [weak self] in
            guard let self else { return }
            self.list?.littleWindowDidClose(self)
        }

        strip.onOpenCommandBar = { [weak self] in self?.openCommandBar() }
        strip.onCopyURL = { [weak self] in self?.copyURL(markdown: false) }
        strip.onPromote = { [weak self] in self?.promote(to: nil) }
        strip.onMoreSpaces = { [weak self] in self?.showSpacesMenu() }
        strip.onProfileMenu = { [weak self] in self?.showProfileMenu() }
        strip.onKey = { [weak self] key in self?.handleShortcut(key) ?? false }
        makeCommandBar()
        makePermissionPrompt()
        toast = ToastView(owner: window) { [weak self] in self?.pageOnScreen() }

        let frame = window.contentFrame
        let made: WebPage
        if let opener, url == nil {
            made = WebPage(popupHostIn: window.hwnd, frame: frame, profilePath: opener.profilePath, delegate: self)
        } else {
            let address = url ?? ""
            self.url = address
            made = WebPage(parent: window.hwnd, frame: frame, url: address.isEmpty ? "about:blank" : address,
                           profilePath: store.profilePath(profile: profileID), delegate: self)
        }
        livePages.insert(ObjectIdentifier(made))
        page = made
        refresh()
    }

    /// Where a new Little Window opens (LittleWindowLayout.frame): on the monitor under the
    /// pointer, as the Mac opens it on the screen under the mouse, in physical pixels.
    private static func placement(size: CGSize, index: Int, scale: Double) -> WindowFrame {
        let area = HostWindow.workAreaUnderPointer ?? WindowFrame(x: 0, y: 0, width: 1280 * scale, height: 800 * scale)
        let dips = CGRect(x: area.x / scale, y: area.y / scale, width: area.width / scale, height: area.height / scale)
        let f = LittleWindowLayout.frame(size: size, in: dips, index: index)
        return WindowFrame(x: (Double(f.minX) * scale).rounded(), y: (Double(f.minY) * scale).rounded(),
                           width: (Double(f.width) * scale).rounded(), height: (Double(f.height) * scale).rounded())
    }

    /// Windows' title bar in the strip's navy, so window and strip read as one bar.
    private func styleTitleBar() {
        let (r, g, b) = LittleWindowLayout.Palette.bar
        window.background = HostColor(r: r, g: g, b: b)
        let titleBar: AppWindowTitleBar? = window.appWindow.titleBar
        guard let bar = titleBar else { return }
        let fill = UWP.Color(a: 255, r: r, g: g, b: b)
        let (tr, tg, tb) = LittleWindowLayout.Palette.text
        let ink = UWP.Color(a: 255, r: tr, g: tg, b: tb)
        let (hr, hg, hb) = LittleWindowLayout.Palette.pillHover
        bar.backgroundColor = fill
        bar.inactiveBackgroundColor = fill
        bar.buttonBackgroundColor = fill
        bar.buttonInactiveBackgroundColor = fill
        bar.buttonHoverBackgroundColor = UWP.Color(a: 255, r: hr, g: hg, b: hb)
        bar.foregroundColor = ink
        bar.buttonForegroundColor = ink
        bar.buttonHoverForegroundColor = ink
    }

    /// Brings the window to the front with the keyboard: the page, or the command bar for an
    /// empty window.
    func activate() {
        window.activate()
        // A popup host has no address until Chromium navigates it, but it is a page all the
        // same: the command bar would cover a sign-in popup.
        if hasPage || isPopupHost { focusPage() } else { openCommandBar() }
    }

    private func focusPage() {
        page?.setFocused(true)
    }

    // MARK: Strip

    /// The strip, then waits for the next change to what it reads: the space "Open in" names
    /// follows the browser window used last (Arc 1.171, #92) and the profiles.
    private func refresh() {
        refreshQueued = false
        guard !closing else { return }
        withObservationTracking {
            if let r = requestedSpaceID, store.space(r) == nil { requestedSpaceID = nil }
            targetSpaceID = store.littleWindowTarget(requested: requestedSpaceID)
            drawStrip()
        } onChange: { [weak self] in
            onMain { self?.queueRefresh() }
        }
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        _ = try? dispatcher.tryEnqueue { [weak self] in self?.refresh() }
    }

    private func drawStrip() {
        let space = store.space(targetSpaceID) ?? store.focusedSpace(window: store.lastNormalWindowID)
        // Arc's shouldShowProfileIndicators: only once there is a profile besides Default.
        let profile: String? = store.profiles.isEmpty ? nil : store.profile(profileID)?.name ?? "Default"
        strip.show(url: hasPage ? currentURL : "", space: space, profile: profile)
        window.title = title.isEmpty ? "Little Window" : "\(title) - Little Window"
    }

    // MARK: Command bar

    private func makeCommandBar() {
        commandBar.onCommit = { [weak self] row, typed, mode in self?.handleCommit(row, typed: typed, mode: mode) }
        commandBar.onResize = { [weak self] height in
            self?.commandBarHeight = height
            self?.placeCommandBar()
        }
        commandBar.onClose = { [weak self] in
            guard let self else { return }
            self.commandWindow?.hide()
            guard !self.commandBarDeactivated, !self.closing, let window = HWND(bitPattern: self.window.hwnd) else { return }
            _ = SetForegroundWindow(window)
            self.focusPage()
        }
        do {
            commandWindow = try FloatingWindow(owner: window, content: commandBar.root)
            commandWindow?.onDeactivate = { [weak self] in
                guard let self, self.commandBar.isOpen else { return }
                self.commandBarDeactivated = true
                self.commandBar.close()
            }
        } catch {
            print("The Little Window's command bar could not be made: \(error)")
        }
    }

    /// The pill, Ctrl+L, Ctrl+T: the bar on the page's address (Arc: the command bar in the
    /// window), after the event that asked for it.
    func openCommandBar() {
        _ = try? dispatcher.tryEnqueue { [weak self] in self?.presentCommandBar() }
    }

    private func presentCommandBar() {
        guard !closing, let commandWindow else { return }
        commandBarDeactivated = false
        let space = store.space(targetSpaceID) ?? store.focusedSpace(window: store.lastNormalWindowID)
        commandBar.open(mode: hasPage ? .editURL : .newTab, prefill: hasPage ? currentURL : nil, theme: space.theme)
        placeCommandBar()
        commandWindow.show { [weak self] in self?.commandBar.focusField() }
    }

    /// Arc's Little Arc puts the bar's top a third of the way down the window, 500 wide at most.
    private func placeCommandBar() {
        guard let commandWindow, commandBar.isOpen, let window else { return }
        let scale = window.scale
        let position = window.appWindow.position, size = window.appWindow.size
        let width = min(Double(LittleWindowLayout.commandBarWidth), Double(size.width) / scale - 40) * scale
        let top = Double(position.y) + Double(size.height) / 3
        let left = Double(position.x) + (Double(size.width) - width) / 2
        commandWindow.place(origin: PointInt32(x: Int32(left.rounded()), y: Int32(top.rounded())),
                            size: SizeInt32(width: Int32(width.rounded()), height: Int32((commandBarHeight * scale).rounded())))
    }

    /// What Return in the bar does (LittleWindowController.handleCommit): an address loads here;
    /// an open tab, an archived one or a command goes to the browser window used last.
    private func handleCommit(_ s: Suggestion?, typed: String, mode: CommandBarMode) {
        let query = commandBar.query
        func open(_ url: String) {
            store.recordQuerySelection(query: query, url: url)
            navigate(url)
        }
        guard let s else {
            if typed.isEmpty { return }
            open(SuggestionEngine.looksLikeURL(typed) ? SuggestionEngine.urlFromInput(typed) : engine.searchURL(typed))
            return
        }
        switch s.kind {
        case .switchToTab(let id):
            store.recordQuerySelection(query: query, url: s.url ?? "")
            list?.showTab(id)
        case .archived(let id):
            list?.restoreArchived(id)
        case .navigate:
            open(typed == query ? (s.url ?? SuggestionEngine.urlFromInput(typed)) : SuggestionEngine.urlFromInput(typed))
        case .search:
            open(s.url ?? engine.searchURL(typed))
        case .history, .topDomain:
            open(s.url ?? "")
        case .command(let id):
            if !handle(action: id) { _ = list?.perform(id) }
        case .switchSpace(let id):
            store.focusSpace(id, window: store.lastNormalWindowID)
            requestedSpaceID = nil
            refresh()
        case .moveToSpace(let id):
            promote(to: id)
        case .moveToFolder:
            break
        }
    }

    private func navigate(_ url: String) {
        self.url = url
        page?.loadURL(url)
        focusPage()
        drawStrip()
    }

    // MARK: Actions

    /// Ctrl+W and the rest while this window has the keyboard (LittleWindowController.handle).
    /// False for an action the browser window used last performs instead.
    @discardableResult
    func handle(action id: String) -> Bool {
        switch id {
        case "closeTab", "closeWindow": requestClose()
        case "newTab", "editURL": openCommandBar()
        case "goBack": page?.goBack()
        case "goForward": page?.goForward()
        case "reload": page?.reload()
        case "hardReload": page?.reloadIgnoringCache()
        case "stop": page?.stopLoading()
        case "clearCache": page?.clearSiteDataAndReload(cookies: false)
        case "clearCookies": page?.clearSiteDataAndReload(cookies: true)
        case "zoomIn": if let page { page.zoomLevel += 0.5 }
        case "zoomOut": if let page { page.zoomLevel -= 0.5 }
        case "resetZoom": page?.zoomLevel = 0
        case "copyURL": copyURL(markdown: false)
        case "copyURLMarkdown": copyURL(markdown: true)
        case "viewSource": page?.viewSource()
        case "print": page?.printPage()
        case "devTools": page?.runDevTools(.toggle)
        case "jsConsole": page?.runDevTools(.console)
        case "inspectElement": page?.runDevTools(.inspect)
        case "networkPanel": page?.runDevTools(.network)
        case "promoteLittleWindow": promote(to: nil)
        // Move Tab to Space N sends the page there, as the spaces menu does (#86, #92).
        case let id where id.hasPrefix("moveTabToSpace"):
            if let n = Int(id.dropFirst(14)), n >= 1, n <= store.spaceOrder.count { promote(to: store.spaceOrder[n - 1]) }
        // A Little Window has no sidebar, tabs, split or find bar: these stay off the browser
        // window behind it, as on the Mac.
        case "find", "findNext", "findPrevious", "capturePage", "toggleSidebar", "pinTab", "favoriteTab", "renameTab",
             "duplicateTab", "resetTab", "muteTab", "clearToday", "nextTab", "previousTab", "recentTab", "recentTabBackward",
             "toggleDeveloperMode", "addSplitView", "closeSplitPane", "separateFromSplit", "flipSplitOrientation",
             "nextSplitPane", "previousSplitPane", "changeProfile":
            break
        default:
            return false
        }
        return true
    }

    /// The user's keys (WinKeyBindings): this window's actions, else the browser window's. A
    /// Ctrl+Alt chord that types a character on the layout (AltGr) is left to type.
    private func handleShortcut(_ key: KeyPress) -> Bool {
        guard !WinKeyboard.typesCharacter(key),
              let chord = KeyChord(windowsVirtualKey: key.keyCode, control: key.control, shift: key.shift, alt: key.alt),
              let action = WinKeyBindings.shared.action(matching: chord) else { return false }
        return handle(action: action.id) || (list?.perform(action.id) ?? false)
    }

    /// Ctrl+Shift+C and the link button: the address, and Arc's toast at the page's top right.
    private func copyURL(markdown: Bool) {
        guard hasPage else { return }
        let url = currentURL, title = page?.currentTitle ?? self.title
        guard WinShell.copy(markdown ? "[\(title)](\(url))" : url) else { return }
        let theme = (store.space(targetSpaceID) ?? store.focusedSpace(window: store.lastNormalWindowID)).theme
        if markdown {
            toast.show("Copied URL as Markdown", theme: theme)
        } else {
            toast.show("Copied Current URL", action: ToastView.Action(title: "Share") { [weak self] in
                guard let self else { return }
                WinShell.share(url: url, title: title, owner: self.window.hwnd)
            }, theme: theme)
        }
    }

    private func pageOnScreen() -> (left: Int32, top: Int32, right: Int32, scale: Double)? {
        guard let window, let host = HWND(bitPattern: window.hwnd) else { return nil }
        let frame = window.contentFrame
        var topLeft = POINT(x: frame.x, y: frame.y)
        _ = ClientToScreen(host, &topLeft)
        return (topLeft.x, topLeft.y, topLeft.x + frame.width, window.scale)
    }

    // MARK: Open in a space

    /// "Open in <Space>" (Ctrl+O), the spaces menu, Move Tab to Space N: the live page goes into
    /// `spaceID` (nil: the space the button names) as a Today tab, in the browser window already
    /// showing that space if there is one, and this window closes (Arc).
    func promote(to spaceID: UUID?) {
        guard let page, hasPage, !closing, let list else { return }
        commandBar.close()
        if spaceID == nil { refresh() }
        let destination = store.littleWindowDestination(spaceID ?? targetSpaceID)
        let title = page.currentTitle.isEmpty ? self.title : page.currentTitle
        promoted = true
        self.page = nil
        livePages.remove(ObjectIdentifier(page))
        for request in permissionQueue where request.page.page === page { request.answer(false) }
        permissionQueue.removeAll { $0.page.page === page }
        list.adopt(page, url: currentURLOf(page), title: title, space: destination)
        requestClose()
    }

    private func currentURLOf(_ page: WebPage) -> String {
        page.currentURL.isEmpty ? url : page.currentURL
    }

    /// The chevron: every space, the page going to the one picked (Arc's LittleBrowserMoveMenu,
    /// as a menu).
    private func showSpacesMenu() {
        guard hasPage else { return }
        _ = try? dispatcher.tryEnqueue { [weak self] in
            guard let self, !self.closing else { return }
            let spaces = self.store.spaceOrder.compactMap { self.store.space($0) }
            let items: [String?] = spaces.map { $0.emoji.isEmpty ? $0.title : "\($0.emoji)  \($0.title)" }
            guard let chosen = WinShell.popupMenu(owner: self.window.hwnd, items) else { return }
            self.promote(to: spaces[chosen].id)
        }
    }

    // MARK: Profile

    /// The chip's menu (Arc: showChangeProfileMenu): every profile, the page's ticked.
    private func showProfileMenu() {
        _ = try? dispatcher.tryEnqueue { [weak self] in
            guard let self, !self.closing else { return }
            let options: [(id: UUID?, name: String)] = [(nil, "Default")] + self.store.profiles.map { ($0.id, $0.name) }
            let items: [String?] = options.map { ($0.id == self.profileID ? "\u{2713}  " : "      ") + $0.name }
            guard let chosen = WinShell.popupMenu(owner: self.window.hwnd, items) else { return }
            self.changeProfile(to: options[chosen].id)
        }
    }

    /// Arc asks first (ProfileDialogUtils, changeProfileInLittleWindow); a page can't move between
    /// profiles, so a new one in the other profile loads its address.
    private func changeProfile(to id: UUID?) {
        guard id != profileID, !closing else { return }
        let name = store.profile(id)?.name ?? "Default"
        let ok = Self.confirm(owner: window.hwnd, title: "Open this page in \(name)?",
                              message: "Each Profile has different browser data, so this webpage might look a little different.")
        guard ok, !closing else { return }
        profileID = id
        replacePage(at: hasPage ? currentURL : "about:blank")
        drawStrip()
    }

    private func replacePage(at address: String) {
        let old = page
        let made = WebPage(parent: window.hwnd, frame: window.contentFrame, url: address,
                           profilePath: store.profilePath(profile: profileID), delegate: self)
        livePages.insert(ObjectIdentifier(made))
        page = made
        old?.close()
        focusPage()
    }

    /// Windows' OK/Cancel box over the window; true for OK.
    private static func confirm(owner: UInt, title: String, message: String) -> Bool {
        let okCancel: UINT = 0x1, question: UINT = 0x20  // MB_OKCANCEL, MB_ICONQUESTION
        let answer = message.withCString(encodedAs: UTF16.self) { text in
            title.withCString(encodedAs: UTF16.self) { caption in
                MessageBoxW(HWND(bitPattern: owner), text, caption, okCancel | question)
            }
        }
        return answer == 1  // IDOK
    }

    // MARK: Permissions

    private func makePermissionPrompt() {
        permissionPrompt.onAnswer = { [weak self] allowed in self?.answerPermission(allowed) }
        do {
            permissionWindow = try FloatingWindow(owner: window, content: permissionPrompt.root)
            permissionWindow?.onClose = { [weak self] in self?.answerPermission(false) }
        } catch {
            print("The Little Window's permission prompt could not be made: \(error)")
        }
    }

    /// The browser window's question (the Mac asks with a sheet on the Little Window): a quiet
    /// deny would save a block for the site that its tabs then hit too (#137).
    private func showNextPermission() {
        permissionQueue.removeAll { $0.page.page == nil || $0.page.page?.isClosed == true }
        guard let request = permissionQueue.first, let permissionWindow, !closing else {
            permissionWindow?.hide()
            return
        }
        permissionHeight = permissionPrompt.show(origin: request.origin, kinds: UInt(request.kinds.rawValue), dark: true)
        placePermissionPrompt()
        permissionWindow.show { [weak self] in self?.permissionPrompt.focus() }
    }

    private func answerPermission(_ allowed: Bool) {
        guard !permissionQueue.isEmpty else { return }
        permissionQueue.removeFirst().answer(allowed)
        permissionWindow?.hide()
        if permissionQueue.isEmpty, !closing {
            if let window = HWND(bitPattern: window.hwnd) { _ = SetForegroundWindow(window) }
            focusPage()
        }
        showNextPermission()
    }

    private func placePermissionPrompt() {
        guard let permissionWindow, !permissionQueue.isEmpty, let window, let host = HWND(bitPattern: window.hwnd) else { return }
        let scale = window.scale, area = window.contentFrame
        let width = Int32((PermissionPromptView.width * scale).rounded()), height = Int32((permissionHeight * scale).rounded())
        var corner = POINT(x: area.x + (area.width - width) / 2, y: area.y + Int32((12 * scale).rounded()))
        _ = ClientToScreen(host, &corner)
        permissionWindow.place(origin: PointInt32(x: corner.x, y: corner.y), size: SizeInt32(width: width, height: height))
    }

    // MARK: Size and closing

    /// A resize by the user sets the size the next Little Window opens at, in DIPs (the Mac's
    /// windowDidEndLiveResize); a move alone doesn't.
    private func saveSize() {
        guard !closing, let hwnd = HWND(bitPattern: window.hwnd), !IsIconic(hwnd), !IsZoomed(hwnd) else { return }
        let frame = window.frame, scale = window.scale
        guard (frame.width, frame.height) != savedSize else { return }
        savedSize = (frame.width, frame.height)
        let size = LittleWindowLayout.sizeString(CGSize(width: (frame.width / scale).rounded(), height: (frame.height / scale).rounded()))
        if store.prefs.littleWindowSize != size { store.prefs.littleWindowSize = size }
    }

    /// Closes the window as its close button does (Ctrl+W), after the event that asked.
    func requestClose() {
        guard !closing, window.shouldClose?() ?? true else { return }
        _ = try? dispatcher.tryEnqueue { [weak self] in self?.window?.close() }
    }

    /// Archive the page to the Library (Arc keeps closed Little Arcs there too).
    func archivePage() {
        guard hasPage, !promoted else { return }
        let pageTitle = page?.currentTitle ?? ""
        store.archiveLittleWindowPage(url: currentURL, title: pageTitle.isEmpty ? title : pageTitle)
        promoted = true
    }

    /// Archives and closes the page, then the window once Chromium is done with it (or after 3 s).
    private func beginClosing() {
        guard !closing else { return }
        closing = true
        commandBar.close()
        toast.hide()
        permissionWindow?.hide()
        for request in permissionQueue { request.answer(false) }
        permissionQueue.removeAll()
        archivePage()
        let open = page
        page = nil
        open?.close()
        guard !livePages.isEmpty else {
            readyToClose = true
            return
        }
        closeTimer = try? dispatcher.createTimer()
        closeTimer?.interval = TimeSpan(duration: 3 * 10_000_000)
        closeTimer?.isRepeating = false
        closeTimer?.tick.addHandler { [weak self] _, _ in self?.finishClosing() }
        try? closeTimer?.start()
    }

    private func finishClosing() {
        guard !readyToClose else { return }
        readyToClose = true
        try? closeTimer?.stop()
        closeTimer = nil
        window.close()
    }
}

// MARK: - Chromium → Little Window

extension LittleWindow: WebPageDelegate {
    func page(_ page: WebPage, didChangeTitle title: String) {
        guard page === self.page else { return }
        self.title = title
        drawStrip()
    }

    func page(_ page: WebPage, didChangeURL url: String) {
        guard page === self.page else { return }
        self.url = url == "about:blank" ? "" : url
        drawStrip()
    }

    func page(_ page: WebPage, didFinishLoadingURL url: String, statusCode: Int) {
        guard page === self.page, !url.isEmpty, url != "about:blank" else { return }
        store.recordVisit(url: url, title: page.currentTitle)
    }

    /// Kept under the page's host, so its Today tab or archived row has it later.
    func page(_ page: WebPage, didLoadFavicon png: Data, forURL iconURL: String) {
        guard page === self.page, let key = FaviconKey.key(for: currentURL) else { return }
        Favicons.shared.store(png: png, forKey: key, persist: true)
    }

    /// Links that want a new tab open another Little Window (Arc does the same).
    func page(_ page: WebPage, requestsNewTabWithURL url: String, inBackground background: Bool) {
        // cra:// is Cra's scripting scheme; a page must not drive it.
        guard !url.lowercased().hasPrefix("cra:") else { return }
        list?.openLittleWindow(url: url, opener: page, activate: !background)
        if background { window.activate() }
    }

    func page(_ page: WebPage, popupHostForURL url: String, inBackground background: Bool) -> WebPage? {
        guard !url.lowercased().hasPrefix("cra:"), let host = list?.openLittleWindow(url: nil, opener: page, activate: !background) else { return nil }
        if background { window.activate() }
        return host.page
    }

    func page(_ page: WebPage, handleKey key: KeyPress) -> Bool {
        guard !key.isRepeat || key.keyCode == 0x09 else { return false }
        return handleShortcut(key)
    }

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

    /// Recorded by a browser window, whose downloads list shows it (the Mac's goes to app.main).
    func page(_ page: WebPage, didUpdateDownload download: DownloadInfo) {
        list?.recordDownload(download, from: page)
    }

    func page(_ page: WebPage, requestsPermissionForOrigin origin: String, kinds: PermissionKinds,
              answer: @escaping (Bool) -> Void) {
        guard !closing else { return answer(false) }
        permissionQueue.append((WeakPage(page), origin, kinds, answer))
        if permissionQueue.count == 1 { showNextPermission() }
    }

    func pageDidClose(_ page: WebPage) {
        livePages.remove(ObjectIdentifier(page))
        if closing {
            // After this callback, which comes from inside CEF's OnBeforeClose (BrowserWindow).
            if livePages.isEmpty { _ = try? dispatcher.tryEnqueue { [weak self] in self?.finishClosing() } }
            return
        }
        if permissionQueue.first?.page.page === page {
            permissionQueue.removeFirst()
            permissionWindow?.hide()
            showNextPermission()
        }
        permissionQueue.removeAll { $0.page.page === page }
        guard page === self.page else { return }
        // The page closed itself (window.close()): the window goes with it, the page archived.
        self.page = nil
        archivePage()
        requestClose()
    }
}
