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
    func windowDidClose(_ window: BrowserWindow)
}

/// The app's browser windows, one per window session in the store (AppDelegate's mainWindows
/// and openNewWindow on the Mac). Closing one of several ends its session; closing the last
/// quits and keeps it, so the next launch opens the same windows where they were.
@MainActor
final class WindowList: BrowserWindowHost {
    private let store: SidebarStore
    private let dispatcher: WinAppSDK.DispatcherQueue
    private(set) var windows: [BrowserWindow] = []
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
            // The last window: Cra quits and the session stays for the next launch.
            PostQuitMessage(0)
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
