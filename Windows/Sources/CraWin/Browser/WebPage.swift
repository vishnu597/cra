import CraCEFWin
import CraCore
import Foundation

/// A key press on a page, as Chromium reports it (CraKeyEvent).
struct KeyPress: Equatable, Sendable {
    /// The Windows virtual-key code ('A'...'Z' and '0'...'9' are their ASCII values).
    var keyCode: Int32
    var control: Bool
    var shift: Bool
    var alt: Bool
    var isRepeat: Bool

    init(keyCode: Int32, control: Bool, shift: Bool, alt: Bool, isRepeat: Bool = false) {
        self.keyCode = keyCode
        self.control = control
        self.shift = shift
        self.alt = alt
        self.isRepeat = isRepeat
    }

    init(_ event: CraKeyEvent) {
        keyCode = Int32(event.key_code)
        control = event.modifiers & UInt32(CraKeyModifierControl) != 0
        shift = event.modifiers & UInt32(CraKeyModifierShift) != 0
        alt = event.modifiers & UInt32(CraKeyModifierAlt) != 0
        isRepeat = event.is_repeat != 0
    }
}

struct DownloadInfo: Sendable {
    enum State: Sendable { case inProgress, complete, cancelled, interrupted }
    var identifier: UInt32
    var url: String
    var fullPath: String
    var suggestedName: String
    var receivedBytes: Int64
    var totalBytes: Int64
    var percent: Int
    var state: State
}

struct PermissionKinds: OptionSet, Sendable {
    let rawValue: UInt32
    static let camera = PermissionKinds(rawValue: 1)
    static let microphone = PermissionKinds(rawValue: 2)
    static let location = PermissionKinds(rawValue: 4)
    static let notifications = PermissionKinds(rawValue: 8)
    static let other = PermissionKinds(rawValue: 16)
}

/// What a page tells the shell: CraBrowserDelegate on macOS (Sources/CraCEF/include/CraCEF.h),
/// with the same method names so code ported from the Mac reads the same. Every method has an
/// empty default. Everything runs on the main thread (CraCEFWin.h), the main actor's.
@MainActor
protocol WebPageDelegate: AnyObject {
    func page(_ page: WebPage, didChangeTitle title: String)
    func page(_ page: WebPage, didChangeURL url: String)
    func page(_ page: WebPage, didChangeLoading loading: Bool, canGoBack: Bool, canGoForward: Bool)
    func page(_ page: WebPage, didChangeProgress progress: Double)
    func page(_ page: WebPage, didFinishLoadingURL url: String, statusCode: Int)
    /// PNG bytes.
    func page(_ page: WebPage, didLoadFavicon png: Data, forURL iconURL: String)
    func page(_ page: WebPage, didChangeStatusMessage message: String)
    func page(_ page: WebPage, didReportThemeColor hex: String)
    func page(_ page: WebPage, didReportBackgroundColor hex: String)
    func page(_ page: WebPage, didChangeFullscreen fullscreen: Bool)
    /// Ctrl-click, middle-click and similar: open a plain new tab.
    func page(_ page: WebPage, requestsNewTabWithURL url: String, inBackground background: Bool)
    /// window.open / target=_blank: a popup host (`WebPage(popupHostIn:)`) keeps the opener;
    /// nil blocks the popup.
    func page(_ page: WebPage, popupHostForURL url: String, inBackground background: Bool) -> WebPage?
    /// Reserved shortcuts, before the page sees the key. Return true to consume it.
    func page(_ page: WebPage, handleKey key: KeyPress) -> Bool
    /// A key press while the page's DevTools have the keyboard. Return true to consume it.
    func page(_ page: WebPage, handleDevToolsKey key: KeyPress) -> Bool
    /// Keys the page did not handle. Return true to consume it.
    func page(_ page: WebPage, handleUnhandledKey key: KeyPress) -> Bool
    func page(_ page: WebPage, didUpdateDownload download: DownloadInfo)
    /// Ask the user, then call `answer`.
    func page(_ page: WebPage, requestsPermissionForOrigin origin: String, kinds: PermissionKinds,
              answer: @escaping (Bool) -> Void)
    func page(_ page: WebPage, didFindMatches count: Int, activeMatch: Int)
    func page(_ page: WebPage, didChangeMediaCapture capturing: Bool)
    func pageDidReceiveFocus(_ page: WebPage)
    func pageDidClose(_ page: WebPage)
}

extension WebPageDelegate {
    func page(_ page: WebPage, didChangeTitle title: String) {}
    func page(_ page: WebPage, didChangeURL url: String) {}
    func page(_ page: WebPage, didChangeLoading loading: Bool, canGoBack: Bool, canGoForward: Bool) {}
    func page(_ page: WebPage, didChangeProgress progress: Double) {}
    func page(_ page: WebPage, didFinishLoadingURL url: String, statusCode: Int) {}
    func page(_ page: WebPage, didLoadFavicon png: Data, forURL iconURL: String) {}
    func page(_ page: WebPage, didChangeStatusMessage message: String) {}
    func page(_ page: WebPage, didReportThemeColor hex: String) {}
    func page(_ page: WebPage, didReportBackgroundColor hex: String) {}
    func page(_ page: WebPage, didChangeFullscreen fullscreen: Bool) {}
    func page(_ page: WebPage, requestsNewTabWithURL url: String, inBackground background: Bool) {}
    func page(_ page: WebPage, popupHostForURL url: String, inBackground background: Bool) -> WebPage? { nil }
    func page(_ page: WebPage, handleKey key: KeyPress) -> Bool { false }
    func page(_ page: WebPage, handleDevToolsKey key: KeyPress) -> Bool { false }
    func page(_ page: WebPage, handleUnhandledKey key: KeyPress) -> Bool { false }
    func page(_ page: WebPage, didUpdateDownload download: DownloadInfo) {}
    func page(_ page: WebPage, requestsPermissionForOrigin origin: String, kinds: PermissionKinds,
              answer: @escaping (Bool) -> Void) { answer(false) }
    func page(_ page: WebPage, didFindMatches count: Int, activeMatch: Int) {}
    func page(_ page: WebPage, didChangeMediaCapture capturing: Bool) {}
    func pageDidReceiveFocus(_ page: WebPage) {}
    func pageDidClose(_ page: WebPage) {}
}

/// A rectangle in physical pixels, relative to the parent window's client area.
struct PixelRect: Equatable {
    var x: Int32, y: Int32, width: Int32, height: Int32
}

/// One Chromium page in a Win32 child window: CraBrowser on macOS. Chromium holds the page
/// until `pageDidClose`; a WebPage stays alive until then even when the shell lets go of it.
/// Main thread only, like every call into CraCEFWin (hence the unchecked Sendable: it is only
/// ever handed to the main actor, on the main thread).
final class WebPage: @unchecked Sendable {
    weak var delegate: WebPageDelegate?
    /// Anything the shell wants to hang on the page (the tab id).
    var userInfo: AnyHashable?
    private(set) var isClosed = false
    private var handle: OpaquePointer?

    /// The profile folder the page loads in (SidebarStore.profilePath); nil is Default, and
    /// always for an incognito page. A page can't change profile: one in the wrong one is closed
    /// and made again (BrowserManager.pruneMissingTabs on the Mac).
    let profilePath: String?
    let isIncognito: Bool

    /// A page loading `url` now; `incognito` in the off-the-record profile private windows share,
    /// else in `profilePath`'s profile.
    init(parent: UInt, frame: PixelRect, url: String, incognito: Bool = false, profilePath: String? = nil,
         delegate: WebPageDelegate?) {
        self.delegate = delegate
        self.frame = frame
        self.isIncognito = incognito
        self.profilePath = incognito ? nil : profilePath
        let profile = self.profilePath ?? ""
        handle = url.withCString { url in
            profile.withCString { profile in
                cra_browser_create_in(UInt(parent), frame.x, frame.y, frame.width, frame.height, url, incognito ? 1 : 0, profile,
                                      callbacks())
            }
        }
    }

    /// A popup host: return it from `page(_:popupHostForURL:inBackground:)` and the popup
    /// opens in it, in its opener's profile (which `incognito` and `profilePath` record).
    init(popupHostIn parent: UInt, frame: PixelRect, incognito: Bool = false, profilePath: String? = nil,
         delegate: WebPageDelegate?) {
        self.delegate = delegate
        self.frame = frame
        self.isIncognito = incognito
        self.profilePath = incognito ? nil : profilePath
        handle = cra_browser_create(UInt(parent), frame.x, frame.y, frame.width, frame.height, nil, callbacks())
    }

    var currentURL: String { handle.map { String(cString: cra_browser_current_url($0)) } ?? "" }
    var currentTitle: String { handle.map { String(cString: cra_browser_current_title($0)) } ?? "" }
    var isLoading: Bool { handle.map { cra_browser_is_loading($0) != 0 } ?? false }
    var canGoBack: Bool { handle.map { cra_browser_can_go_back($0) != 0 } ?? false }
    var canGoForward: Bool { handle.map { cra_browser_can_go_forward($0) != 0 } ?? false }
    var isCreated: Bool { handle.map { cra_browser_is_created($0) != 0 } ?? false }
    /// The page closed itself (window.close()).
    var closedByPage: Bool { handle.map { cra_browser_closed_by_page($0) != 0 } ?? false }

    var frame: PixelRect = PixelRect(x: 0, y: 0, width: 0, height: 0) {
        didSet { if let handle, frame != oldValue { cra_browser_set_frame(handle, frame.x, frame.y, frame.width, frame.height) } }
    }
    var isVisible = true {
        didSet { if let handle, isVisible != oldValue { cra_browser_set_visible(handle, isVisible ? 1 : 0) } }
    }

    /// Moves the live page into another window (a Little Window's page going into a browser
    /// window, as BrowserManager.adopt on the Mac): history, scroll position and sign-ins go with it.
    func move(toParent parent: UInt, frame: PixelRect) {
        guard let handle, !isClosed else { return }
        cra_browser_set_parent(handle, UInt(parent))
        self.frame = frame
        cra_browser_set_frame(handle, frame.x, frame.y, frame.width, frame.height)
    }

    func loadURL(_ url: String) { if let handle { url.withCString { cra_browser_load_url(handle, $0) } } }
    func goBack() { if let handle { cra_browser_go_back(handle) } }
    func goForward() { if let handle { cra_browser_go_forward(handle) } }
    func reload() { if let handle { cra_browser_reload(handle) } }
    func reloadIgnoringCache() { if let handle { cra_browser_reload_ignoring_cache(handle) } }
    func stopLoading() { if let handle { cra_browser_stop_loading(handle) } }
    func exitFullscreen() { if let handle { cra_browser_exit_fullscreen(handle) } }
    func setFocused(_ focused: Bool) { if let handle { cra_browser_set_focused(handle, focused ? 1 : 0) } }
    var zoomLevel: Double {
        get { handle.map { cra_browser_zoom_level($0) } ?? 0 }
        set { if let handle { cra_browser_set_zoom_level(handle, newValue) } }
    }
    func find(_ text: String, forward: Bool, matchCase: Bool, findNext: Bool) {
        if let handle { text.withCString { cra_browser_find(handle, $0, forward ? 1 : 0, matchCase ? 1 : 0, findNext ? 1 : 0) } }
    }
    func stopFinding(clearSelection: Bool) { if let handle { cra_browser_stop_finding(handle, clearSelection ? 1 : 0) } }
    func setAudioMuted(_ muted: Bool) { if let handle { cra_browser_set_audio_muted(handle, muted ? 1 : 0) } }
    func executeJavaScript(_ script: String) { if let handle { script.withCString { cra_browser_execute_javascript(handle, $0) } } }
    /// Whether the page's DevTools are open, closing or asked for (the Mac's TabRuntime.devTools).
    private(set) var devTools = DevToolsToggle()
    var hasDevTools: Bool { handle.map { cra_browser_has_dev_tools($0) != 0 } ?? false }

    /// Ctrl+Shift+I, Ctrl+Shift+J, Inspect Elements (BrowserManager.runDevTools on the Mac).
    /// DevTools open docked in the page's place, Chrome's frontend laying the page out beside them.
    func runDevTools(_ command: DevToolsToggle.Command) {
        guard let handle, !isClosed else { return }
        let (effect, frontend) = devTools.run(command)
        // A press made while DevTools close is done when they reopen (DevToolsToggle.didClose),
        // one made while they open once the frontend is up.
        if let frontend { frontend.withCString { cra_browser_set_dev_tools_action(handle, $0) } } else { cra_browser_set_dev_tools_action(handle, nil) }
        performDevTools(effect)
    }

    private func performDevTools(_ effect: DevToolsToggle.Effect) {
        guard let handle, !isClosed else { return }
        switch effect {
        case .show: cra_browser_show_dev_tools(handle)
        case .close: cra_browser_close_dev_tools(handle)
        case .frontend: cra_browser_apply_dev_tools_action(handle)
        case .none: break
        }
    }

    func printPage() { if let handle { cra_browser_print(handle) } }
    func viewSource() { if let handle { cra_browser_view_source(handle) } }

    /// A DevTools protocol method (CraBrowser.sendDevToolsMethod on the Mac): `completion` gets
    /// the answer's JSON, or nil and the error. Always called, on the main thread.
    func sendDevToolsMethod(_ method: String, params: String = "{}", completion: @escaping @MainActor (String?, String?) -> Void) {
        let box = Unmanaged.passRetained(DevToolsCall(completion)).toOpaque()
        let done: CraDevToolsResult = { context, success, json, length in
            guard let context else { return }
            let call = Unmanaged<DevToolsCall>.fromOpaque(context).takeRetainedValue()
            let text = json.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: length), as: UTF8.self) } ?? ""
            onMain { success != 0 ? call.completion(text, nil) : call.completion(nil, text) }
        }
        guard let handle, !isClosed else {
            done(box, 0, nil, 0)
            return
        }
        method.withCString { m in params.withCString { p in cra_browser_send_dev_tools_method(handle, m, p, box, done) } }
    }

    /// The connection of the page on screen (the Mac's sslStatus); nil before anything committed.
    var sslStatus: (status: ConnectionSecurity.Status, hasCertificate: Bool)? {
        guard let handle else { return nil }
        var out = CraSSLStatus()
        guard cra_browser_ssl_status(handle, &out) != 0 else { return nil }
        return (ConnectionSecurity.Status(secureConnection: out.secure_connection != 0, certStatus: UInt(out.cert_status),
                                          contentStatus: UInt(out.content_status)), out.has_certificate != 0)
    }

    /// Windows' certificate dialog for the page's certificate, over `owner`. Modal.
    @discardableResult
    func showCertificate(owner: UInt) -> Bool {
        guard let handle else { return false }
        return cra_browser_show_certificate(handle, owner) != 0
    }

    /// Arc's "Clear Cookies and Refresh" and "Clear Cache and Refresh" (SiteData on the Mac).
    func clearSiteDataAndReload(cookies: Bool) {
        guard let request = SiteDataClearing.request(url: currentURL, cookies: cookies) else { return }
        sendDevToolsMethod(request.method, params: request.params) { [weak self] _, error in
            if let error { print("Cra: clearing site data failed: \(error)") }
            self?.reload()
        }
    }

    /// Asynchronous: `pageDidClose` follows once Chromium is done.
    func close() {
        guard let handle, !isClosed else { return }
        isClosed = true
        cra_browser_close(handle)
    }

    fileprivate func answerPermission(_ id: UInt64, _ allowed: Bool) {
        if let handle, !isClosed { cra_browser_answer_permission(handle, id, allowed ? 1 : 0) }
    }

    fileprivate func didClose() {
        isClosed = true
        handle = nil
        onMain { delegate?.pageDidClose(self) }
    }

    fileprivate var opaque: OpaquePointer? { handle }

    // MARK: Chromium → Swift

    /// Chromium calls back on the main thread (CraCEFWin.h). The context holds a retain on
    /// the page, released when it closes.
    private func callbacks() -> CraBrowserCallbacks {
        var cb = CraBrowserCallbacks()
        cb.context = Unmanaged.passRetained(self).toOpaque()
        cb.title_changed = { ctx, title in
            WebPage.with(ctx) { $0.delegate?.page($0, didChangeTitle: string(title)) }
        }
        cb.address_changed = { ctx, url in
            WebPage.with(ctx) { $0.delegate?.page($0, didChangeURL: string(url)) }
        }
        cb.loading_changed = { ctx, loading, back, forward in
            WebPage.with(ctx) { $0.delegate?.page($0, didChangeLoading: loading != 0, canGoBack: back != 0, canGoForward: forward != 0) }
        }
        cb.progress_changed = { ctx, progress in
            WebPage.with(ctx) { $0.delegate?.page($0, didChangeProgress: progress) }
        }
        cb.load_finished = { ctx, url, status in
            WebPage.with(ctx) { $0.delegate?.page($0, didFinishLoadingURL: string(url), statusCode: Int(status)) }
        }
        cb.favicon_loaded = { ctx, iconURL, png, length in
            guard let png else { return }
            let data = Data(bytes: png, count: length)
            WebPage.with(ctx) { $0.delegate?.page($0, didLoadFavicon: data, forURL: string(iconURL)) }
        }
        cb.status_message_changed = { ctx, message in
            WebPage.with(ctx) { $0.delegate?.page($0, didChangeStatusMessage: string(message)) }
        }
        cb.theme_color_reported = { ctx, hex in
            WebPage.with(ctx) { $0.delegate?.page($0, didReportThemeColor: string(hex)) }
        }
        cb.background_color_reported = { ctx, hex in
            WebPage.with(ctx) { $0.delegate?.page($0, didReportBackgroundColor: string(hex)) }
        }
        cb.fullscreen_changed = { ctx, fullscreen in
            WebPage.with(ctx) { $0.delegate?.page($0, didChangeFullscreen: fullscreen != 0) }
        }
        cb.new_tab_requested = { ctx, url, background in
            WebPage.with(ctx) { $0.delegate?.page($0, requestsNewTabWithURL: string(url), inBackground: background != 0) }
        }
        cb.popup_host_requested = { ctx, url, background in
            let url = string(url)
            let host = WebPage.with(ctx, UInt(0)) { page in
                page.delegate?.page(page, popupHostForURL: url, inBackground: background != 0)?.opaque.map { UInt(bitPattern: $0) } ?? 0
            }
            return OpaquePointer(bitPattern: host)
        }
        cb.key_event = { ctx, event in
            guard let event else { return 0 }
            let key = KeyPress(event.pointee)
            return WebPage.with(ctx, false) { $0.delegate?.page($0, handleKey: key) ?? false } ? 1 : 0
        }
        cb.unhandled_key_event = { ctx, event in
            guard let event else { return 0 }
            let key = KeyPress(event.pointee)
            return WebPage.with(ctx, false) { $0.delegate?.page($0, handleUnhandledKey: key) ?? false } ? 1 : 0
        }
        cb.download_updated = { ctx, info in
            guard let d = info?.pointee else { return }
            let state: DownloadInfo.State = switch d.state {
            case CraDownloadStateComplete: .complete
            case CraDownloadStateCancelled: .cancelled
            case CraDownloadStateInterrupted: .interrupted
            default: .inProgress
            }
            let download = DownloadInfo(identifier: d.identifier, url: string(d.url), fullPath: string(d.full_path),
                                        suggestedName: string(d.suggested_name), receivedBytes: d.received_bytes,
                                        totalBytes: d.total_bytes, percent: Int(d.percent), state: state)
            WebPage.with(ctx) { $0.delegate?.page($0, didUpdateDownload: download) }
        }
        cb.permission_requested = { ctx, id, origin, kinds in
            let origin = string(origin)
            WebPage.with(ctx) { page in
                guard let delegate = page.delegate else {
                    page.answerPermission(id, false)
                    return
                }
                delegate.page(page, requestsPermissionForOrigin: origin, kinds: PermissionKinds(rawValue: kinds)) {
                    [weak page] allowed in page?.answerPermission(id, allowed)
                }
            }
        }
        cb.find_result = { ctx, count, active in
            WebPage.with(ctx) { $0.delegate?.page($0, didFindMatches: Int(count), activeMatch: Int(active)) }
        }
        cb.media_capture_changed = { ctx, capturing in
            WebPage.with(ctx) { $0.delegate?.page($0, didChangeMediaCapture: capturing != 0) }
        }
        cb.focus_received = { ctx in
            WebPage.with(ctx) { $0.delegate?.pageDidReceiveFocus($0) }
        }
        cb.dev_tools_opened = { ctx in
            WebPage.with(ctx) { $0.devTools.didOpen() }
        }
        cb.dev_tools_closed = { ctx in
            WebPage.with(ctx) { page in page.performDevTools(page.devTools.didClose()) }
        }
        cb.dev_tools_panel = { ctx, panel in
            let panel = string(panel)
            WebPage.with(ctx) { $0.devTools.didShowPanel(panel) }
        }
        cb.dev_tools_key_event = { ctx, event in
            guard let event else { return 0 }
            let key = KeyPress(event.pointee)
            return WebPage.with(ctx, false) { $0.delegate?.page($0, handleDevToolsKey: key) ?? false } ? 1 : 0
        }
        cb.closed = { ctx in
            guard let ctx else { return }
            Unmanaged<WebPage>.fromOpaque(ctx).takeRetainedValue().didClose()
        }
        return cb
    }

    /// The page a callback's context stands for, on the main actor (the callback is on the
    /// main thread already).
    private static func with<T>(_ context: UnsafeMutableRawPointer?, _ fallback: T, _ body: @MainActor (WebPage) -> T) -> T {
        guard let context else { return fallback }
        let page = Unmanaged<WebPage>.fromOpaque(context).takeUnretainedValue()
        return onMain { body(page) }
    }

    private static func with(_ context: UnsafeMutableRawPointer?, _ body: @MainActor (WebPage) -> Void) {
        with(context, (), body)
    }
}

/// A DevTools call's completion, held across the C callback.
private final class DevToolsCall {
    let completion: @MainActor (String?, String?) -> Void
    init(_ completion: @escaping @MainActor (String?, String?) -> Void) { self.completion = completion }
}

private func string(_ cString: UnsafePointer<CChar>?) -> String {
    cString.map { String(cString: $0) } ?? ""
}
