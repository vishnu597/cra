import CraCEFWin
import CraCore
import Foundation
import UWP
import WinAppSDK
import WindowsFoundation
import WinUI

/// Phase 0 of the Windows shell: one WinUI window with a sidebar column (address field and
/// page title) and one Chromium page beside it. Proves the stack (Swift/WinRT, WinUI 3, CEF
/// in a child window, CraCore) before the real sidebar and window controller are ported.
@main
public final class CraApp: SwiftApplication {
    private var window: Window!
    /// The CraBrowser from CraCEFWin (an opaque C pointer in Swift).
    private var page: OpaquePointer?
    // XAML objects can only be made once the app is launched, on its UI thread (making them in
    // init fails with RPC_E_WRONG_THREAD).
    private var content: Border!
    private var address: TextBox!
    private var pageTitle: TextBlock!
    private var dispatcher: WinAppSDK.DispatcherQueue?

    public required init() {
        super.init()
        unhandledException.addHandler { _, args in
            print("Unhandled exception: \(args?.message ?? "")")
        }
    }

    override public func onShutdown(exitCode: Int32) {
        if let page { cra_browser_close(page) }
        cra_cef_shutdown()
    }

    override public func onLaunched(_ args: WinUI.LaunchActivatedEventArgs) {
        dispatcher = try? WinAppSDK.DispatcherQueue.getForCurrentThread()
        guard startChromium() else {
            print("Chromium did not start")
            return
        }

        content = Border()
        address = TextBox()
        pageTitle = TextBlock()
        window = Window()
        window.title = "Cra"
        window.content = makeLayout()
        try? window.activate()

        // The page is a Win32 child of the top-level window; WinUI's window id is its HWND.
        let hwnd = UInt(window.appWindow.id.value)
        let frame = contentFrame()
        page = "https://crabrowser.app".withCString { url in
            cra_browser_create(hwnd, frame.x, frame.y, frame.width, frame.height, url, callbacks())
        }
        content.sizeChanged.addHandler { [weak self] _, _ in self?.layoutPage() }
        window.closed.addHandler { [weak self] _, _ in
            if let page = self?.page { cra_browser_close(page) }
            self?.page = nil
        }
    }

    private func makeLayout() -> UIElement {
        let grid = Grid()
        let sidebarColumn = ColumnDefinition()
        sidebarColumn.width = GridLength(value: 260, gridUnitType: .pixel)
        let pageColumn = ColumnDefinition()
        pageColumn.width = GridLength(value: 1, gridUnitType: .star)
        grid.columnDefinitions.append(sidebarColumn)
        grid.columnDefinitions.append(pageColumn)

        let sidebar = StackPanel()
        sidebar.orientation = .vertical
        sidebar.spacing = 8
        sidebar.padding = Thickness(left: 10, top: 10, right: 10, bottom: 10)
        address.placeholderText = "Search or enter address"
        address.keyDown.addHandler { [weak self] _, args in
            guard let self, args?.key == .enter else { return }
            self.navigate(to: self.address.text)
            args?.handled = true
        }
        pageTitle.text = "Cra"
        sidebar.children.append(address)
        sidebar.children.append(pageTitle)

        grid.children.append(sidebar)
        grid.children.append(content)
        try? Grid.setColumn(sidebar, 0)
        try? Grid.setColumn(content, 1)
        return grid
    }

    /// What the user typed, as CraCore turns it into a page: an address, or a search.
    private func navigate(to typed: String) {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard let page, !text.isEmpty else { return }
        let url = TypedURL.looksLikeURL(text) ? TypedURL.fromInput(text) : SearchEngine.google.searchURL(text)
        url.withCString { cra_browser_load_url(page, $0) }
    }

    private func startChromium() -> Bool {
        let exe = CommandLine.arguments[0]
        let helper = URL(fileURLWithPath: exe).deletingLastPathComponent().appendingPathComponent("CraHelper.exe").path
        let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? NSTemporaryDirectory()
        let cache = URL(fileURLWithPath: local).appendingPathComponent("Cra").appendingPathComponent("User Data").path
        return helper.withCString { h in cache.withCString { c in cra_cef_initialize(h, c) != 0 } }
    }

    /// The content column in physical pixels, relative to the window's client area.
    private func contentFrame() -> (x: Int32, y: Int32, width: Int32, height: Int32) {
        let scale = content.xamlRoot?.rasterizationScale ?? 1
        let origin = (try? content.transformToVisual(nil)?.transformPoint(Point(x: 0, y: 0))) ?? Point(x: 260, y: 0)
        return (Int32((Double(origin.x) * scale).rounded()), Int32((Double(origin.y) * scale).rounded()),
                Int32((content.actualWidth * scale).rounded()), Int32((content.actualHeight * scale).rounded()))
    }

    private func layoutPage() {
        guard let page else { return }
        let f = contentFrame()
        cra_browser_set_frame(page, f.x, f.y, f.width, f.height)
    }

    // MARK: Chromium → UI

    private func callbacks() -> CraBrowserCallbacks {
        CraBrowserCallbacks(
            context: Unmanaged.passUnretained(self).toOpaque(),
            title_changed: { context, value in
                guard let context, let value else { return }
                let app = Unmanaged<CraApp>.fromOpaque(context).takeUnretainedValue()
                let title = String(cString: value)
                app.onMain { app.pageTitle.text = title; app.window.title = "\(title) - Cra" }
            },
            address_changed: { context, value in
                guard let context, let value else { return }
                let app = Unmanaged<CraApp>.fromOpaque(context).takeUnretainedValue()
                let url = String(cString: value)
                app.onMain { app.address.text = url }
            })
    }

    /// CEF calls back on its own UI thread; WinUI objects belong to the main thread.
    private func onMain(_ work: @escaping () -> Void) {
        _ = try? dispatcher?.tryEnqueue { work() }
    }
}
