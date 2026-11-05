import CraCore
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
    /// The window moved on screen (what floats over it follows).
    var onMove: (() -> Void)?
    /// The user asked to close (title bar, Alt+F4). Return false to keep the window open for
    /// now and call `close()` later.
    var shouldClose: (() -> Bool)?
    /// The window is going away.
    var onClose: (() -> Void)?
    /// The keyboard came to the window itself rather than a page or the sidebar: Windows does
    /// that when the window becomes active (at launch, Alt+Tab back, a dialog or the command bar
    /// going away). Give it to what should have it, or keys go nowhere.
    var onFocus: (() -> Void)?
    /// The window became the active one (a click, Alt+Tab, the taskbar): the store's active
    /// window follows it, as AppKit's key window does on the Mac.
    var onActivate: (() -> Void)?
    /// A move or resize by the user ended (its frame is then worth saving).
    var onMoveEnded: (() -> Void)?
    /// The window's own client area shows wherever no page and no XAML covers it: between split
    /// panes and in an empty pane. It is painted in this colour.
    var background: HostColor = HostColor(r: 28, g: 36, b: 43) { didSet { if background != oldValue { invalidate() } } }
    /// A rounded bar drawn on that area (a split divider being dragged), in `pillColor`.
    var pill: PixelRect? { didSet { if pill != oldValue { invalidate() } } }
    var pillColor = HostColor(r: 0, g: 0, b: 0)
    /// The mouse on that area, in physical pixels relative to the client area. A press captures
    /// the mouse, so moves and the release come here until it is let go.
    var onMouse: ((HostMouseEvent) -> Void)?
    /// The pointer's shape over that area at a client point; nil leaves the arrow.
    var cursor: ((Int32, Int32) -> HostCursor?)?
    private var closed = false
    private var lastPress: (time: Int32, x: Int32, y: Int32)?
    /// The window procedure below is a C function and can't capture its window. Kept after the
    /// window object goes: Windows still sends the window messages while destroying it.
    nonisolated(unsafe) private static var hooks: [UInt: Hook] = [:]
    private struct Hook {
        let previous: WNDPROC?
        weak var window: HostWindow?
    }

    /// `frame`: where to open, in screen pixels (a restored or cascaded window); nil opens a
    /// `width` × `height` window where Windows puts it.
    init(content: UIElement, sidebarWidth: Double, frame: WindowFrame? = nil, width: Double = 1280, height: Double = 820) throws {
        appWindow = try AppWindow.create()
        hwnd = UInt(appWindow.id.value)
        self.sidebarWidth = sidebarWidth
        try xaml.initialize(appWindow.id)
        xaml.content = content
        appWindow.changed.addHandler { [weak self] _, args in
            if args?.didSizeChange == true { self?.layout() }
            if args?.didPositionChange == true { self?.onMove?() }
        }
        appWindow.closing.addHandler { [weak self] _, args in
            guard let self, let args else { return }
            // Destroyed by close(), after this event rather than inside it.
            args.cancel = true
            if self.shouldClose?() ?? true {
                _ = try? WinAppSDK.DispatcherQueue.getForCurrentThread()?.tryEnqueue { [weak self] in self?.close() }
            }
        }
        if let frame {
            try appWindow.moveAndResize(RectInt32(x: Int32(frame.x.rounded()), y: Int32(frame.y.rounded()),
                                                  width: Int32(frame.width.rounded()), height: Int32(frame.height.rounded())))
        } else {
            try appWindow.resize(SizeInt32(width: Int32(width * scale), height: Int32(height * scale)))
        }
        layout()
        hookWindowProcedure()
        try appWindow.show()
    }

    var title: String {
        get { appWindow.title }
        set { appWindow.title = newValue }
    }

    /// The window's outer frame on screen, in physical pixels.
    var frame: WindowFrame {
        let p = appWindow.position, s = appWindow.size
        return WindowFrame(x: Double(p.x), y: Double(p.y), width: Double(s.width), height: Double(s.height))
    }

    /// The work area (the screen less the taskbar) of the monitor the window is on.
    var workArea: WindowFrame? {
        guard let window = HWND(bitPattern: hwnd), let monitor = MonitorFromWindow(window, DWORD(MONITOR_DEFAULTTONEAREST)) else { return nil }
        return HostWindow.workArea(of: monitor)
    }

    /// Every monitor's work area (where a restored window may open).
    static var workAreas: [WindowFrame] {
        var areas: [WindowFrame] = []
        let collect: MONITORENUMPROC = { monitor, _, _, context in
            guard let monitor, let list = UnsafeMutablePointer<[WindowFrame]>(bitPattern: Int(context)),
                  let area = HostWindow.workArea(of: monitor) else { return true }
            list.pointee.append(area)
            return true
        }
        withUnsafeMutablePointer(to: &areas) { pointer in
            _ = EnumDisplayMonitors(nil, nil, collect, LPARAM(Int(bitPattern: pointer)))
        }
        return areas
    }

    private static func workArea(of monitor: HMONITOR) -> WindowFrame? {
        var info = MONITORINFO()
        info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        guard GetMonitorInfoW(monitor, &info) else { return nil }
        let r = info.rcWork
        return WindowFrame(x: Double(r.left), y: Double(r.top), width: Double(r.right - r.left), height: Double(r.bottom - r.top))
    }

    /// Brings the window to the front with the keyboard.
    func activate() {
        guard let window = HWND(bitPattern: hwnd) else { return }
        if IsIconic(window) { _ = ShowWindow(window, SW_RESTORE) }
        _ = SetForegroundWindow(window)
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

    /// Hears messages ahead of AppWindow's own window procedure: WM_SETFOCUS, which it ignores,
    /// and the painting and mouse of the client area the pages and XAML leave uncovered.
    private func hookWindowProcedure() {
        guard let window = HWND(bitPattern: hwnd) else { return }
        // Painting the uncovered area must not paint over the pages.
        let style = GetWindowLongPtrW(window, GWL_STYLE)
        _ = SetWindowLongPtrW(window, GWL_STYLE, style | LONG_PTR(Self.clipChildren))
        let proc: WNDPROC = { hwnd, message, wParam, lParam in
            guard let hook = HostWindow.hooks[UInt(bitPattern: hwnd)], let previous = hook.previous else {
                return DefWindowProcW(hwnd, message, wParam, lParam)
            }
            if let window = hook.window, let handled = window.handle(message, wParam, lParam) { return handled }
            let result = CallWindowProcW(previous, hwnd, message, wParam, lParam)
            if message == UINT(WM_SETFOCUS) { hook.window?.onFocus?() }
            return result
        }
        let previous = SetWindowLongPtrW(window, GWLP_WNDPROC, unsafeBitCast(proc, to: LONG_PTR.self))
        Self.hooks[hwnd] = Hook(previous: unsafeBitCast(previous, to: WNDPROC?.self), window: self)
    }

    // Message numbers and constants, spelled out: WinSDK imports some as macros Swift can't see.
    private static let wmSetCursor: UINT = 0x0020, wmPaint: UINT = 0x000F, wmEraseBackground: UINT = 0x0014
    private static let wmMouseMove: UINT = 0x0200, wmLeftDown: UINT = 0x0201, wmLeftUp: UINT = 0x0202
    private static let wmCaptureChanged: UINT = 0x0215
    private static let wmActivate: UINT = 0x0006, wmExitSizeMove: UINT = 0x0232
    private static let clipChildren: UInt32 = 0x0200_0000  // WS_CLIPCHILDREN
    private static let hitClient = 1  // HTCLIENT
    private static let doubleClickWidth: Int32 = 36, doubleClickHeight: Int32 = 37  // SM_CXDOUBLECLK, SM_CYDOUBLECLK

    /// The result for a message this window answers itself; nil passes it on to AppWindow's.
    private func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch message {
        case Self.wmEraseBackground:
            return 1  // WM_PAINT fills it, without a flash of the class background first
        case Self.wmPaint:
            paint()
            return 0
        case Self.wmSetCursor:
            // Over a page or the XAML, wParam is that child window: it keeps its own pointer.
            guard UInt(wParam) == hwnd, Int(lParam & 0xFFFF) == Self.hitClient, let window = HWND(bitPattern: hwnd) else { return nil }
            var p = POINT()
            _ = GetCursorPos(&p)
            _ = ScreenToClient(window, &p)
            guard let shape = cursor?(p.x, p.y) else { return nil }
            _ = SetCursor(LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: shape.rawValue)))
            return 1
        case Self.wmLeftDown:
            let (x, y) = Self.point(lParam)
            let time = GetMessageTime()
            var clicks = 1
            if let last = lastPress, UInt32(bitPattern: time &- last.time) <= GetDoubleClickTime(),
               abs(x - last.x) <= GetSystemMetrics(Self.doubleClickWidth) / 2, abs(y - last.y) <= GetSystemMetrics(Self.doubleClickHeight) / 2 {
                clicks = 2
            }
            lastPress = clicks == 2 ? nil : (time, x, y)
            if let window = HWND(bitPattern: hwnd) { _ = SetCapture(window) }
            onMouse?(.down(x: x, y: y, clicks: clicks))
            return 0
        case Self.wmMouseMove:
            let (x, y) = Self.point(lParam)
            onMouse?(.move(x: x, y: y))
            return nil
        case Self.wmLeftUp:
            let (x, y) = Self.point(lParam)
            onMouse?(.up(x: x, y: y))
            _ = ReleaseCapture()
            return 0
        case Self.wmCaptureChanged:
            // Taken away mid-drag (Alt+Tab, a menu): the drag ends where it is.
            onMouse?(.cancelled)
            return nil
        case Self.wmActivate:
            // WA_INACTIVE is 0; WA_ACTIVE and WA_CLICKACTIVE are not.
            if wParam & 0xFFFF != 0 { onActivate?() }
            return nil
        case Self.wmExitSizeMove:
            onMoveEnded?()
            return nil
        default:
            return nil
        }
    }

    /// The client point a mouse message carries (signed: a captured drag goes past the edges).
    private static func point(_ lParam: LPARAM) -> (Int32, Int32) {
        (Int32(Int16(truncatingIfNeeded: lParam & 0xFFFF)), Int32(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)))
    }

    private func paint() {
        guard let window = HWND(bitPattern: hwnd) else { return }
        var ps = PAINTSTRUCT()
        guard let dc = BeginPaint(window, &ps) else { return }
        if let brush = CreateSolidBrush(background.colorRef) {
            _ = FillRect(dc, &ps.rcPaint, brush)
            _ = DeleteObject(UnsafeMutableRawPointer(brush))
        }
        if let pill, pill.width > 0, pill.height > 0, let brush = CreateSolidBrush(pillColor.colorRef) {
            let round = min(pill.width, pill.height)
            if let region = CreateRoundRectRgn(pill.x, pill.y, pill.x + pill.width + 1, pill.y + pill.height + 1, round, round) {
                _ = FillRgn(dc, region, brush)
                _ = DeleteObject(UnsafeMutableRawPointer(region))
            }
            _ = DeleteObject(UnsafeMutableRawPointer(brush))
        }
        _ = EndPaint(window, &ps)
    }

    private func invalidate() {
        guard !closed, let window = HWND(bitPattern: hwnd) else { return }
        _ = InvalidateRect(window, nil, false)
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

/// An opaque colour for the window's own painting.
struct HostColor: Equatable {
    var r: UInt8, g: UInt8, b: UInt8

    /// GDI's COLORREF, 0x00BBGGRR.
    var colorRef: COLORREF { COLORREF(r) | COLORREF(g) << 8 | COLORREF(b) << 16 }

    /// This colour with `other` laid over it at `alpha`.
    func blended(with other: HostColor, alpha: Double) -> HostColor {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) * (1 - alpha) + Double(b) * alpha).rounded()) }
        return HostColor(r: mix(r, other.r), g: mix(g, other.g), b: mix(b, other.b))
    }
}

/// The left button on the window's own client area (HostWindow.onMouse).
enum HostMouseEvent {
    case down(x: Int32, y: Int32, clicks: Int)
    case move(x: Int32, y: Int32)
    case up(x: Int32, y: Int32)
    /// The mouse capture was taken away before the release.
    case cancelled
}

/// System pointers, by their IDC_ resource numbers.
enum HostCursor: UInt {
    case resizeLeftRight = 32644  // IDC_SIZEWE
    case resizeUpDown = 32645  // IDC_SIZENS
    case hand = 32649  // IDC_HAND
}
