import Foundation
import UWP
import WinAppSDK
import WinSDK
import WinUI

/// A top-level window with XAML in its sidebar column only and Chromium's pages beside it.
///
/// Not a WinUI `Window`: a Window's XAML bridge always covers its whole client area, and WinUI
/// then takes every real click and wheel meant for a page under it, even with the page above it
/// in z-order. (Found on a PC: clicks reached the page whenever the bridge didn't cover it, and
/// never while it did; keys were fine once the page had focus.) So this is an AppWindow with a
/// DesktopWindowXamlSource whose bridge it keeps to the sidebar.
///
/// Main thread only, like the XAML it holds (not marked @MainActor so the app's nonisolated
/// WinUI callbacks can use it directly).
final class HostWindow {
    let appWindow: AppWindow
    /// Every page is a child window of it.
    let hwnd: UInt
    private let xaml = DesktopWindowXamlSource()

    /// The XAML column's width, in DIPs.
    var sidebarWidth: Double { didSet { layout() } }
    /// After every resize, with the page area (`contentFrame`).
    var onLayout: ((PixelRect) -> Void)?
    /// The user asked to close (title bar, Alt+F4). Return false to keep the window open for
    /// now and call `close()` later.
    var shouldClose: (() -> Bool)?
    /// The window is going away.
    var onClose: (() -> Void)?
    /// The keyboard came to the window itself rather than a page or the sidebar: Windows does
    /// that when the window becomes active (at launch, Alt+Tab back, a dialog or the command bar
    /// going away). Give it to what should have it, or keys go nowhere.
    var onFocus: (() -> Void)?
    private var closed = false
    /// The window procedure below is a C function and can't capture its window. Kept after the
    /// window object goes: Windows still sends the window messages while destroying it.
    nonisolated(unsafe) private static var hooks: [UInt: Hook] = [:]
    private struct Hook {
        let previous: WNDPROC?
        weak var window: HostWindow?
    }

    init(content: UIElement, sidebarWidth: Double, width: Double = 1280, height: Double = 820) throws {
        appWindow = try AppWindow.create()
        hwnd = UInt(appWindow.id.value)
        self.sidebarWidth = sidebarWidth
        try xaml.initialize(appWindow.id)
        xaml.content = content
        appWindow.changed.addHandler { [weak self] _, args in
            if args?.didSizeChange == true { self?.layout() }
        }
        appWindow.closing.addHandler { [weak self] _, args in
            guard let self, let args else { return }
            // Destroyed by close(), after this event rather than inside it.
            args.cancel = true
            if self.shouldClose?() ?? true {
                _ = try? WinAppSDK.DispatcherQueue.getForCurrentThread()?.tryEnqueue { [weak self] in self?.close() }
            }
        }
        try appWindow.resize(SizeInt32(width: Int32(width * scale), height: Int32(height * scale)))
        layout()
        watchFocus()
        try appWindow.show()
    }

    var title: String {
        get { appWindow.title }
        set { appWindow.title = newValue }
    }

    /// Physical pixels per DIP.
    var scale: Double {
        guard let window = HWND(bitPattern: hwnd) else { return 1 }
        let dpi = GetDpiForWindow(window)
        return dpi > 0 ? Double(dpi) / 96 : 1
    }

    /// The page area: right of the sidebar, in physical pixels relative to the client area.
    var contentFrame: PixelRect {
        let size = appWindow.clientSize
        let x = min(size.width, Int32((sidebarWidth * scale).rounded()))
        return PixelRect(x: x, y: 0, width: size.width - x, height: size.height)
    }

    /// Moves Win32 focus into the XAML column (from a page), for a programmatic XAML focus to
    /// take.
    func focusXAML() {
        guard let bridge = xaml.siteBridge, let window = HWND(bitPattern: UInt(bridge.windowId.value)) else { return }
        _ = SetFocus(window)
    }

    /// Hears WM_SETFOCUS ahead of AppWindow's own window procedure, which ignores it.
    private func watchFocus() {
        guard let window = HWND(bitPattern: hwnd) else { return }
        let proc: WNDPROC = { hwnd, message, wParam, lParam in
            guard let hook = HostWindow.hooks[UInt(bitPattern: hwnd)], let previous = hook.previous else {
                return DefWindowProcW(hwnd, message, wParam, lParam)
            }
            let result = CallWindowProcW(previous, hwnd, message, wParam, lParam)
            if message == UINT(WM_SETFOCUS) { hook.window?.onFocus?() }
            return result
        }
        let previous = SetWindowLongPtrW(window, GWLP_WNDPROC, unsafeBitCast(proc, to: LONG_PTR.self))
        Self.hooks[hwnd] = Hook(previous: unsafeBitCast(previous, to: WNDPROC?.self), window: self)
    }

    func close() {
        guard !closed else { return }
        closed = true
        onClose?()
        try? xaml.close()
        try? appWindow.destroy()
    }

    private func layout() {
        guard !closed else { return }
        let frame = contentFrame
        try? xaml.siteBridge?.moveAndResize(RectInt32(x: 0, y: 0, width: frame.x, height: frame.height))
        onLayout?(frame)
    }
}
