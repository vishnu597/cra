import CraCEFWin
import CraCore
import Foundation
import UWP
import WinAppSDK
import WindowsFoundation
import WinSDK
import WinUI

/// The Windows shell while the real sidebar is ported: one WinUI window with a sidebar column
/// (navigation buttons, address field, a plain list of tabs) and the selected tab's page beside
/// it. Exercises the whole CEF bridge (WebPage): tabs, popups, downloads, permissions and the
/// keys Chromium hands back.
@main
public final class CraApp: SwiftApplication {
    private var window: Window!
    /// The window's HWND: every page is a child window of it.
    private var hwnd: UInt = 0
    private var tabs: [WebPage] = []
    private var selected: WebPage?
    /// Permission requests waiting for the user, oldest first.
    private var permissionQueue: [(origin: String, kinds: PermissionKinds, answer: (Bool) -> Void)] = []

    // XAML objects can only be made once the app is launched, on its UI thread (making them in
    // init fails with RPC_E_WRONG_THREAD).
    private var content: Border!
    private var address: TextBox!
    private var tabList: StackPanel!
    private var status: TextBlock!
    private var permissionPanel: StackPanel!
    private var permissionText: TextBlock!

    private static let startPage = "https://crabrowser.app"

    public required init() {
        super.init()
        unhandledException.addHandler { _, args in
            print("Unhandled exception: \(args?.message ?? "")")
        }
    }

    override public func onShutdown(exitCode: Int32) {
        cra_cef_shutdown()
    }

    override public func onLaunched(_ args: WinUI.LaunchActivatedEventArgs) {
        guard startChromium() else {
            // Another Cra already runs on this profile and was handed this launch.
            // (Not `exit`: inside an Application that names its own exit() method.)
            if cra_cef_another_instance_was_notified() != 0 { ExitProcess(0) }
            print("Chromium did not start")
            return
        }

        content = Border()
        address = TextBox()
        tabList = StackPanel()
        status = TextBlock()
        permissionPanel = StackPanel()
        permissionText = TextBlock()
        window = Window()
        window.title = "Cra"
        window.content = makeLayout()
        try? window.activate()

        // WinUI's window id is its HWND.
        hwnd = UInt(window.appWindow.id.value)
        content.sizeChanged.addHandler { [weak self] _, _ in self?.layoutPages() }
        window.closed.addHandler { [weak self] _, _ in
            guard let self else { return }
            for page in self.tabs { page.close() }
            self.tabs.removeAll()
            self.selected = nil
        }
        openTab(Self.startPage, background: false)
    }

    // MARK: Tabs

    @discardableResult
    private func openTab(_ url: String, background: Bool) -> WebPage {
        let page = WebPage(parent: hwnd, frame: contentFrame(), url: url, delegate: self)
        add(page, background: background)
        return page
    }

    private func add(_ page: WebPage, background: Bool) {
        if let current = selected, let index = tabs.firstIndex(where: { $0 === current }) {
            tabs.insert(page, at: index + 1)
        } else {
            tabs.append(page)
        }
        if background {
            page.isVisible = false
            reloadTabList()
        } else {
            select(page)
        }
    }

    private func select(_ page: WebPage) {
        if let current = selected, current !== page { current.isVisible = false }
        selected = page
        page.frame = contentFrame()
        page.isVisible = true
        page.setFocused(true)
        address.text = page.currentURL
        updateWindowTitle()
        reloadTabList()
    }

    private func close(_ page: WebPage) {
        page.close()
        forget(page)
    }

    /// Takes a closed page out of the list and selects its neighbour (a new tab after the last).
    private func forget(_ page: WebPage) {
        guard let index = tabs.firstIndex(where: { $0 === page }) else { return }
        tabs.remove(at: index)
        if selected === page {
            selected = nil
            if tabs.isEmpty {
                openTab(Self.startPage, background: false)
            } else {
                select(tabs[min(index, tabs.count - 1)])
            }
        } else {
            reloadTabList()
        }
    }

    private func selectTab(offset: Int) {
        guard let current = selected, let index = tabs.firstIndex(where: { $0 === current }), !tabs.isEmpty else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// What the user typed, as CraCore turns it into a page: an address, or a search.
    private func navigate(to typed: String) {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let url = TypedURL.looksLikeURL(text) ? TypedURL.fromInput(text) : SearchEngine.google.searchURL(text)
        if let selected {
            selected.loadURL(url)
            selected.setFocused(true)
        } else {
            openTab(url, background: false)
        }
    }

    private func focusAddress() {
        _ = try? address.focus(.programmatic)
        try? address.selectAll()
    }

    private func updateWindowTitle() {
        let title = selected?.currentTitle ?? ""
        window.title = title.isEmpty ? "Cra" : "\(title) - Cra"
    }

    // MARK: Layout

    private func makeLayout() -> UIElement {
        let grid = Grid()
        let sidebarColumn = ColumnDefinition()
        sidebarColumn.width = GridLength(value: 260, gridUnitType: .pixel)
        let pageColumn = ColumnDefinition()
        pageColumn.width = GridLength(value: 1, gridUnitType: .star)
        grid.columnDefinitions.append(sidebarColumn)
        grid.columnDefinitions.append(pageColumn)

        let sidebar = Grid()
        sidebar.padding = Thickness(left: 10, top: 10, right: 10, bottom: 10)
        for height in [GridLength(value: 0, gridUnitType: .auto), GridLength(value: 0, gridUnitType: .auto),
                       GridLength(value: 1, gridUnitType: .star), GridLength(value: 0, gridUnitType: .auto),
                       GridLength(value: 0, gridUnitType: .auto)] {
            let row = RowDefinition()
            row.height = height
            sidebar.rowDefinitions.append(row)
        }

        let toolbar = StackPanel()
        toolbar.orientation = .horizontal
        toolbar.spacing = 4
        toolbar.children.append(button("\u{2190}") { [weak self] in self?.selected?.goBack() })
        toolbar.children.append(button("\u{2192}") { [weak self] in self?.selected?.goForward() })
        toolbar.children.append(button("\u{27F3}") { [weak self] in self?.selected?.reload() })
        toolbar.children.append(button("+") { [weak self] in self?.newTabFromUI() })

        address.placeholderText = "Search or enter address"
        address.margin = Thickness(left: 0, top: 8, right: 0, bottom: 8)
        address.keyDown.addHandler { [weak self] _, args in
            guard let self, args?.key == .enter else { return }
            self.navigate(to: self.address.text)
            args?.handled = true
        }

        tabList.orientation = .vertical
        tabList.spacing = 2
        let scroll = ScrollViewer()
        scroll.content = tabList

        permissionPanel.spacing = 4
        permissionPanel.visibility = .collapsed
        permissionText.textWrapping = .wrap
        let answers = StackPanel()
        answers.orientation = .horizontal
        answers.spacing = 4
        answers.children.append(button("Allow") { [weak self] in self?.answerPermission(true) })
        answers.children.append(button("Block") { [weak self] in self?.answerPermission(false) })
        permissionPanel.children.append(permissionText)
        permissionPanel.children.append(answers)

        status.textWrapping = .wrap
        status.margin = Thickness(left: 0, top: 8, right: 0, bottom: 0)

        let rows: [FrameworkElement] = [toolbar, address, scroll, permissionPanel, status]
        for (i, row) in rows.enumerated() {
            sidebar.children.append(row)
            try? Grid.setRow(row, Int32(i))
        }

        grid.children.append(sidebar)
        grid.children.append(content)
        try? Grid.setColumn(sidebar, 0)
        try? Grid.setColumn(content, 1)
        return grid
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> Button {
        let b = Button()
        let label = TextBlock()
        label.text = title
        b.content = label
        b.click.addHandler { _, _ in action() }
        return b
    }

    private func reloadTabList() {
        tabList.children.clear()
        for page in tabs {
            let row = Grid()
            let titleColumn = ColumnDefinition()
            titleColumn.width = GridLength(value: 1, gridUnitType: .star)
            let closeColumn = ColumnDefinition()
            closeColumn.width = GridLength(value: 0, gridUnitType: .auto)
            row.columnDefinitions.append(titleColumn)
            row.columnDefinitions.append(closeColumn)

            let label = TextBlock()
            let title = page.currentTitle.isEmpty ? page.currentURL : page.currentTitle
            label.text = (page === selected ? "\u{25CF} " : "") + (title.isEmpty ? "New Tab" : title)
            label.textTrimming = .characterEllipsis
            let pick = Button()
            pick.content = label
            pick.horizontalAlignment = .stretch
            pick.horizontalContentAlignment = .left
            pick.click.addHandler { [weak self, weak page] _, _ in if let page { self?.select(page) } }
            let closeButton = button("\u{2715}") { [weak self, weak page] in if let page { self?.close(page) } }

            row.children.append(pick)
            row.children.append(closeButton)
            try? Grid.setColumn(pick, 0)
            try? Grid.setColumn(closeButton, 1)
            tabList.children.append(row)
        }
    }

    private func newTabFromUI() {
        openTab(Self.startPage, background: false)
        focusAddress()
    }

    private func startChromium() -> Bool {
        let exe = CommandLine.arguments[0]
        let helper = URL(fileURLWithPath: exe).deletingLastPathComponent().appendingPathComponent("CraHelper.exe").path
        let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: local).appendingPathComponent("Cra")
        let cache = root.appendingPathComponent("User Data").path
        let log = root.appendingPathComponent("chromium.log").path
        return helper.withCString { h in
            cache.withCString { c in
                log.withCString { l in
                    "Cra/1.0".withCString { product in
                        var settings = CraCEFSettings()
                        settings.helper_path = h
                        settings.cache_root = c
                        settings.log_path = l
                        settings.user_agent_product = product
                        return cra_cef_initialize(&settings) != 0
                    }
                }
            }
        }
    }

    /// The content column in physical pixels, relative to the window's client area.
    private func contentFrame() -> PixelRect {
        guard let content else { return PixelRect(x: 260, y: 0, width: 800, height: 600) }
        let scale = content.xamlRoot?.rasterizationScale ?? 1
        let origin = (try? content.transformToVisual(nil)?.transformPoint(Point(x: 0, y: 0))) ?? Point(x: 260, y: 0)
        return PixelRect(x: Int32((Double(origin.x) * scale).rounded()), y: Int32((Double(origin.y) * scale).rounded()),
                         width: Int32((content.actualWidth * scale).rounded()),
                         height: Int32((content.actualHeight * scale).rounded()))
    }

    private func layoutPages() {
        selected?.frame = contentFrame()
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
        permissionPanel.visibility = .visible
    }

    private func answerPermission(_ allowed: Bool) {
        guard !permissionQueue.isEmpty else { return }
        permissionQueue.removeFirst().answer(allowed)
        showNextPermission()
    }

    // MARK: Keys

    /// Shortcuts Cra keeps from the page (Arc's, with Ctrl in place of Cmd).
    private func handleShortcut(_ key: KeyPress) -> Bool {
        let vkTab: Int32 = 0x09, vkLeft: Int32 = 0x25, vkRight: Int32 = 0x27, vkF5: Int32 = 0x74
        if key.control && !key.alt {
            switch key.keyCode {
            case Int32(UInt8(ascii: "T")): newTabFromUI()
            case Int32(UInt8(ascii: "W")): if let selected { close(selected) }
            case Int32(UInt8(ascii: "L")): focusAddress()
            case Int32(UInt8(ascii: "R")): reload(ignoringCache: key.shift)
            case vkTab: selectTab(offset: key.shift ? -1 : 1)
            case Int32(UInt8(ascii: "1"))...Int32(UInt8(ascii: "9")):
                let n = Int(key.keyCode) - Int(UInt8(ascii: "1"))
                // Ctrl+9 is the last tab, as in Chrome and Arc.
                if !tabs.isEmpty { select(n == 8 ? tabs[tabs.count - 1] : tabs[min(n, tabs.count - 1)]) }
            default: return false
            }
            return true
        }
        if key.alt && !key.control {
            switch key.keyCode {
            case vkLeft: selected?.goBack()
            case vkRight: selected?.goForward()
            default: return false
            }
            return true
        }
        if key.keyCode == vkF5 && !key.alt {
            reload(ignoringCache: key.control)
            return true
        }
        return false
    }

    private func reload(ignoringCache: Bool) {
        if ignoringCache { selected?.reloadIgnoringCache() } else { selected?.reload() }
    }
}

// MARK: - Chromium → shell

extension CraApp: WebPageDelegate {
    func page(_ page: WebPage, didChangeTitle title: String) {
        if page === selected { updateWindowTitle() }
        reloadTabList()
    }

    func page(_ page: WebPage, didChangeURL url: String) {
        if page === selected { address.text = url }
    }

    func page(_ page: WebPage, requestsNewTabWithURL url: String, inBackground background: Bool) {
        openTab(url, background: background)
    }

    func page(_ page: WebPage, popupHostForURL url: String, inBackground background: Bool) -> WebPage? {
        let host = WebPage(popupHostIn: hwnd, frame: contentFrame(), delegate: self)
        add(host, background: background)
        return host
    }

    func page(_ page: WebPage, handleKey key: KeyPress) -> Bool {
        guard !key.isRepeat || key.keyCode == 0x09 else { return false }
        return handleShortcut(key)
    }

    func page(_ page: WebPage, didUpdateDownload download: DownloadInfo) {
        let name = URL(fileURLWithPath: download.fullPath.isEmpty ? download.suggestedName : download.fullPath).lastPathComponent
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
        // A page that closed itself (window.close()); tabs Cra closed are already gone.
        forget(page)
    }
}
