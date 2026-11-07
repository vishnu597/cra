import CraCEFWin
import CraCore
import Foundation
import WinAppSDK
import WinSDK

/// What a BrowserWindow asks of the app: another window, and its own going.
@MainActor
protocol BrowserWindowHost: AnyObject {
    /// Arc's New Window (Ctrl+N) or New Incognito Window (Ctrl+Shift+N).
    func openNewWindow(incognito: Bool)
    /// New Little Window (Ctrl+Alt+N): an empty one asking for an address.
    func newLittleWindow()
    /// Close Little Windows: each archives its page.
    func closeLittleWindows()
    func windowDidClose(_ window: BrowserWindow)
    /// Arc's Peek over `window`, from its tab `fromTab`: one at a time over a window.
    func openPeek(url: String, over window: BrowserWindow, fromTab: UUID?)
    func closePeeks(over window: BrowserWindow)
    func hasPeek(over window: BrowserWindow) -> Bool
    /// A Peek over `window` is on screen and not on its way out (closing, or its page moved
    /// into a tab).
    func hasShowingPeek(over window: BrowserWindow) -> Bool
    /// That Peek takes the keyboard back.
    func focusPeek(over window: BrowserWindow)
    /// The window moved or changed size: its Peek follows.
    func repositionPeeks(over window: BrowserWindow)
}

/// The app's browser windows, one per window session in the store (AppDelegate's mainWindows
/// and openNewWindow on the Mac), and its Little Windows (littleWindows). Closing one of several
/// browser windows ends its session; closing the last quits and keeps it, so the next launch
/// opens the same windows where they were. Cra waits for its Little Windows to close first.
@MainActor
final class WindowList: BrowserWindowHost {
    private let store: SidebarStore
    private let dispatcher: WinAppSDK.DispatcherQueue
    private(set) var windows: [BrowserWindow] = []
    private(set) var littleWindows: [LittleWindow] = []
    /// Arc cascades a new window this far right and down from the one in use (22 pt on the
    /// Mac), in DIPs.
    private static let cascadeStep = 22.0

    init(store: SidebarStore, dispatcher: WinAppSDK.DispatcherQueue) {
        self.store = store
        self.dispatcher = dispatcher
        // Whether a tab has a page in any window (the store asks before it unloads or sleeps one).
        store.hasPage = { [weak self] id in self?.windows.contains { $0.hasPage(id) } ?? false }
    }

    /// The saved windows, each where it was if that's still on a monitor. Incognito sessions are
    /// never saved, so none come back.
    func restore() {
        let areas = HostWindow.workAreas
        for session in store.prefs.windows where !session.isIncognito {
            let frame = session.frame.flatMap(WindowFrame.init(string:)).flatMap { $0.isReachable(in: areas) ? $0 : nil }
            open(session, frame: frame, newWindow: false)
        }
        if windows.isEmpty, let first = store.prefs.windows.first {
            open(first, frame: nil, newWindow: false)
        }
        windows.first?.activate()
    }

    func openNewWindow(incognito: Bool) {
        let current = windows.first { $0.windowID == store.activeWindowID } ?? windows.last
        var frame: WindowFrame?
        if let current, let area = current.workArea {
            frame = current.frame.cascaded(step: Self.cascadeStep * current.scale, within: area)
        }
        let session = incognito ? store.addIncognitoWindow(frame: frame?.string)
            : store.addWindow(spaceID: store.focusedSpaceID(window: store.lastNormalWindowID), frame: frame?.string)
        open(session, frame: frame, newWindow: true)?.activate()
    }

    func windowDidClose(_ window: BrowserWindow) {
        windows.removeAll { $0 === window }
        guard !windows.isEmpty else {
            if window.isIncognito { cra_cef_end_incognito_session() }
            // The last window: Cra quits and the session stays for the next launch, once no
            // Little Window is open either (a page moved out of one reopens the window).
            if littleWindows.isEmpty { PostQuitMessage(0) }
            return
        }
        // The last normal window keeps its session while private ones stay open, so the next
        // launch still has it; any other ends (an incognito one's tabs go with it).
        if window.isIncognito || windows.contains(where: { !$0.isIncognito }) {
            store.removeWindow(window.windowID)
        }
        if window.isIncognito, !windows.contains(where: \.isIncognito) {
            // The last private window: its cookies and storage go too.
            cra_cef_end_incognito_session()
        }
        if !windows.contains(where: { $0.windowID == store.activeWindowID }), let next = windows.last {
            store.activeWindowID = next.windowID
        }
    }

    /// Every window's frame into its session, before the store saves at quit.
    func saveFrames() {
        for w in windows { w.saveFrame() }
    }

    // MARK: Little Windows

    func newLittleWindow() {
        openLittleWindow(url: "", opener: nil, activate: true)
    }

    /// A Little Window on `url` ("" asks for an address; nil hosts `opener`'s window.open),
    /// cascaded off the ones already open (AppDelegate.openLittleWindow on the Mac).
    @discardableResult
    func openLittleWindow(url: String?, opener: WebPage?, activate: Bool) -> LittleWindow? {
        do {
            let w = try LittleWindow(store: store, url: url, opener: opener, index: littleWindows.count, scale: scaleUnderPointer(),
                                     dispatcher: dispatcher, list: self)
            littleWindows.append(w)
            if activate { w.activate() }
            return w
        } catch {
            print("The Little Window could not be made: \(error)")
            return nil
        }
    }

    func closeLittleWindows() {
        for w in littleWindows { w.requestClose() }
    }

    func littleWindowDidClose(_ window: LittleWindow) {
        littleWindows.removeAll { $0 === window }
        if let parent = window.peekParent { parent.peekDidClose() }
        if windows.isEmpty, littleWindows.isEmpty { PostQuitMessage(0) }
    }

    // MARK: Peek

    /// AppDelegate.openPeek on the Mac: the Peek before it over that window closes first, and the
    /// tab it came from wears the peeked page's favicon.
    func openPeek(url: String, over parent: BrowserWindow, fromTab: UUID?) {
        closePeeks(over: parent)
        do {
            let w = try LittleWindow(store: store, url: url, opener: nil, index: 0, scale: parent.scale, dispatcher: dispatcher, list: self,
                                     peekOver: parent, fromTab: fromTab)
            littleWindows.append(w)
            parent.showPeekBadge(tab: fromTab, url: url)
            w.showPeek()
        } catch {
            print("The Peek could not be made: \(error)")
        }
    }

    func closePeeks(over parent: BrowserWindow) {
        for w in littleWindows where w.peekParent === parent { w.requestClose() }
    }

    func hasPeek(over parent: BrowserWindow) -> Bool {
        littleWindows.contains { $0.peekParent === parent }
    }

    func hasShowingPeek(over parent: BrowserWindow) -> Bool {
        littleWindows.contains { $0.peekParent === parent && $0.isShowingPeek }
    }

    func focusPeek(over parent: BrowserWindow) {
        littleWindows.first { $0.peekParent === parent && $0.isShowingPeek }?.focusPeek()
    }

    func repositionPeeks(over parent: BrowserWindow) {
        for w in littleWindows where w.peekParent === parent { w.repositionPeek() }
    }

    /// Every Little Window's page into the Library, at quit.
    func archiveLittleWindows() {
        for w in littleWindows { w.archivePage() }
    }

    /// A Little Window's page into `space` as its selected tab, in the browser window already
    /// showing that space, else the one used last (SpaceWindow), which switches to it. The live
    /// page moves, history and sign-ins included (BrowserManager.adopt on the Mac).
    /// `into`: that window (a Peek's Expand, into the window under it).
    func adopt(_ page: WebPage, url: String, title: String, space: UUID, into: BrowserWindow? = nil) {
        if let into {
            store.activeWindowID = into.windowID
            let tab = store.createTab(url: url, title: title, in: space, select: true, window: into.windowID)
            into.adopt(page, for: tab.id)
            into.activate()
            return
        }
        if !windows.contains(where: { !$0.isIncognito }) {
            // Every browser window closed: the last one's session opens again with the page's tab
            // already selected, so it never makes a page for the tab it showed before.
            let session = closedNormalSession()
            store.activeWindowID = session.id
            let tab = store.createTab(url: url, title: title, in: space, select: true, window: session.id)
            guard let target = reopen(session) else { return page.close() }
            target.adopt(page, for: tab.id)
            target.activate()
            return
        }
        guard let target = normalWindow(forSpace: space) else { return page.close() }
        store.activeWindowID = target.windowID
        let tab = store.createTab(url: url, title: title, in: space, select: true, window: target.windowID)
        target.adopt(page, for: tab.id)
        target.activate()
    }

    /// An open tab picked in a Little Window's command bar: shown in the browser window used last.
    func showTab(_ id: UUID) {
        guard let target = lastNormalWindow() else { return }
        store.activeWindowID = target.windowID
        store.selectTab(id, window: target.windowID)
        target.activate()
    }

    /// An archived tab picked in a Little Window's command bar: back in the browser window used last.
    func restoreArchived(_ id: UUID) {
        guard let target = lastNormalWindow() else { return }
        store.activeWindowID = target.windowID
        _ = store.restoreArchived(id)
        target.activate()
    }

    /// An action a Little Window leaves to the browser window used last (Ctrl+N, Ctrl+, …).
    func perform(_ id: String) -> Bool {
        lastNormalWindow()?.perform(id) ?? false
    }

    /// A Little Window's download, in the browser window used last's downloads list.
    func recordDownload(_ download: DownloadInfo, from page: WebPage) {
        lastNormalWindow()?.page(page, didUpdateDownload: download)
    }

    /// The normal browser window in use last; with none open, the last normal window's session
    /// opens again (it stayed while Little Windows were open).
    private func lastNormalWindow() -> BrowserWindow? {
        if let w = windows.first(where: { !$0.isIncognito && $0.windowID == store.lastNormalWindowID })
            ?? windows.last(where: { !$0.isIncognito }) {
            return w
        }
        return reopen(closedNormalSession())
    }

    /// The session the last normal window left (kept while Little Windows stayed open).
    private func closedNormalSession() -> WindowSession {
        store.prefs.windows.first { !$0.isIncognito && $0.id == store.lastNormalWindowID }
            ?? store.prefs.windows.first { !$0.isIncognito }
            ?? store.addWindow(spaceID: store.focusedSpaceID(window: store.lastNormalWindowID), frame: nil)
    }

    private func reopen(_ session: WindowSession) -> BrowserWindow? {
        let areas = HostWindow.workAreas
        let frame = session.frame.flatMap(WindowFrame.init(string:)).flatMap { $0.isReachable(in: areas) ? $0 : nil }
        return open(session, frame: frame, newWindow: false)
    }

    private func normalWindow(forSpace space: UUID) -> BrowserWindow? {
        guard let last = lastNormalWindow() else { return nil }
        let order = Self.zOrder()
        let normal = windows.filter { !$0.isIncognito }
            .sorted { (order.firstIndex(of: $0.window.hwnd) ?? .max) < (order.firstIndex(of: $1.window.hwnd) ?? .max) }
        let id = SpaceWindow.window(for: space, windows: normal.map { (id: $0.windowID, space: store.focusedSpaceID(window: $0.windowID)) },
                                    lastUsed: last.windowID)
        return normal.first { $0.windowID == id } ?? last
    }

    /// Top-level windows front to back (EnumWindows' order).
    private static func zOrder() -> [UInt] {
        var list: [UInt] = []
        let collect: WNDENUMPROC = { hwnd, context in
            guard let hwnd, let list = UnsafeMutablePointer<[UInt]>(bitPattern: Int(context)) else { return true }
            list.pointee.append(UInt(bitPattern: hwnd))
            return true
        }
        withUnsafeMutablePointer(to: &list) { pointer in
            _ = EnumWindows(collect, LPARAM(Int(bitPattern: pointer)))
        }
        return list
    }

    /// The scale of the monitor under the pointer, from a browser window on it (a guess the new
    /// Little Window corrects once it knows its own).
    private func scaleUnderPointer() -> Double {
        var p = POINT()
        if GetCursorPos(&p), let monitor = MonitorFromPoint(p, DWORD(MONITOR_DEFAULTTONEAREST)),
           let w = windows.first(where: { MonitorFromWindow(HWND(bitPattern: $0.window.hwnd), DWORD(MONITOR_DEFAULTTONEAREST)) == monitor }) {
            return w.scale
        }
        let dpi = GetDpiForSystem()
        return dpi > 0 ? Double(dpi) / 96 : 1
    }

    @discardableResult
    private func open(_ session: WindowSession, frame: WindowFrame?, newWindow: Bool) -> BrowserWindow? {
        do {
            let w = try BrowserWindow(store: store, session: session, frame: frame, newWindow: newWindow, dispatcher: dispatcher, host: self)
            windows.append(w)
            return w
        } catch {
            print("The window could not be made: \(error)")
            return nil
        }
    }
}
