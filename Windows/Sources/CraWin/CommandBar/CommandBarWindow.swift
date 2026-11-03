import Foundation
import UWP
import WinAppSDK
import WinSDK
import WindowsFoundation
import WinUI

/// The command bar's own window: borderless, owned by the browser window so it floats over the
/// page (Chromium's child windows sit above anything XAML draws in the browser window itself, the
/// reason HostWindow keeps its XAML to the sidebar). The Windows counterpart of CommandBarPanel.
///
/// Main thread only, like the XAML it holds.
final class CommandBarWindow {
    private let appWindow: AppWindow
    private let hwnd: UInt
    private let xaml = DesktopWindowXamlSource()
    private var poll: WinAppSDK.DispatcherQueueTimer?
    private var wasInFront = false
    /// Another window came to the front (a click on the page or another app), or Alt+F4.
    var onDeactivate: (() -> Void)?

    init(owner: HostWindow, content: UIElement) throws {
        guard let presenter = try OverlappedPresenter.create() else { throw CommandBarWindowError.noPresenter }
        presenter.isResizable = false
        presenter.isMaximizable = false
        presenter.isMinimizable = false
        // A border without a title bar: Windows 11 rounds it and gives it a shadow.
        try presenter.setBorderAndTitleBar(true, false)
        guard let window = try AppWindow.create(presenter, owner.appWindow.id) else { throw CommandBarWindowError.noWindow }
        appWindow = window
        hwnd = UInt(window.id.value)
        appWindow.isShownInSwitchers = false
        try xaml.initialize(appWindow.id)
        xaml.content = content
        appWindow.closing.addHandler { [weak self] _, args in
            args?.cancel = true
            self?.onDeactivate?()
        }
    }

    var isVisible: Bool { appWindow.isVisible }

    /// Places the bar: `origin` its client area's top left on screen, `size` that area, in
    /// physical pixels.
    func place(origin: PointInt32, size: SizeInt32) {
        try? appWindow.resizeClient(size)
        // resizeClient sizes the frame as if the window had a title bar, leaving the client area
        // a title bar taller (an unpainted strip under the rows): take the difference off.
        var client = appWindow.clientSize
        if client.width != size.width || client.height != size.height {
            let outer = appWindow.size
            try? appWindow.resize(SizeInt32(width: outer.width - (client.width - size.width),
                                            height: outer.height - (client.height - size.height)))
            client = appWindow.clientSize
        }
        // The frame has invisible resize borders left and right; the client area is what's centred.
        let border = max(0, (appWindow.size.width - client.width) / 2)
        try? appWindow.move(PointInt32(x: origin.x - border, y: origin.y))
        try? xaml.siteBridge?.moveAndResize(RectInt32(x: 0, y: 0, width: client.width, height: client.height))
    }

    /// Shows the bar in front and gives its XAML the keyboard; `focus` then focuses the field.
    func show(focus: @escaping () -> Void) {
        try? appWindow.show(true)
        if let bridge = xaml.siteBridge, let window = HWND(bitPattern: UInt(bridge.windowId.value)) {
            _ = SetFocus(window)
        }
        focus()
        wasInFront = false
        startWatching()
    }

    func hide() {
        stopWatching()
        try? appWindow.hide()
    }

    /// Windows has no event for another window taking the front from this one that reaches us
    /// here (WM_ACTIVATE goes to the window procedure AppWindow owns), so the bar looks every
    /// tenth of a second while it is open, which costs nothing measurable.
    private func startWatching() {
        stopWatching()
        poll = try? WinAppSDK.DispatcherQueue.getForCurrentThread()?.createTimer()
        poll?.interval = TimeSpan(duration: 100 * 10_000)
        poll?.isRepeating = true
        poll?.tick.addHandler { [weak self] _, _ in self?.checkFront() }
        try? poll?.start()
    }

    private func stopWatching() {
        try? poll?.stop()
        poll = nil
    }

    private func checkFront() {
        let front = UInt(bitPattern: GetForegroundWindow())
        if front == hwnd {
            wasInFront = true
        } else if wasInFront {
            stopWatching()
            onDeactivate?()
        }
    }
}

enum CommandBarWindowError: Swift.Error {
    case noPresenter
    case noWindow
}
