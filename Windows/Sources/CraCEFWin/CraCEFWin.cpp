// CEF on Windows behind the C surface in include/CraCEFWin.h: the counterpart of
// Sources/CraCEF/CraCEF.mm, with HWNDs in place of NSViews.
//
// Threading: CEF's UI thread is the app's main thread. Chromium asks for work through
// OnScheduleMessagePumpWork (from any thread); a message-only window on the main thread turns
// that into CefDoMessageLoopWork calls from WinUI's own message loop. This is cefclient's
// MainMessageLoopExternalPumpWin, and it keeps every callback on the main thread as on macOS.
#include "CraCEFWin.h"

#include <windows.h>
#include <shlobj.h>
#include <wincrypt.h>

#include <climits>
#include <cstdio>
#include <set>
#include <string>
#include <unordered_map>
#include <algorithm>
#include <vector>

// libcef_dll_wrapper is built with MSVC, where CEF's TRIVIAL_ABI is empty. This file is built
// with clang, where the same headers would mark CefRefPtr [[clang::trivial_abi]] and pass it in
// a register instead of by address: CefExecuteProcess then read its CefApp argument from address
// 0. Empty it here, before any other CEF header, so both sides pass CefRefPtr the same way.
#include "include/base/cef_compiler_specific.h"
#undef TRIVIAL_ABI
#define TRIVIAL_ABI

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_handler.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_id_mappers.h"
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/cef_task.h"
#include "include/cef_values.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_helpers.h"

#if __has_builtin(__is_trivially_relocatable)
static_assert(!__is_trivially_relocatable(CefRefPtr<CefApp>),
              "CefRefPtr must be passed by address, as the MSVC-built wrapper expects");
#endif

namespace {

std::wstring Wide(const char *utf8) {
    if (!utf8 || !*utf8) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
    std::wstring out(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out.data(), n);
    return out;
}

/// "rgb(r, g, b)" or "rgba(r, g, b, a)" as "#RRGGBB"; "" for a transparent or unknown colour.
std::string HexFromCSSColor(const std::string &css) {
    int r = 0, g = 0, b = 0;
    float a = 1;
    if (sscanf(css.c_str(), "rgba(%d, %d, %d, %f)", &r, &g, &b, &a) == 4 ||
        sscanf(css.c_str(), "rgb(%d, %d, %d)", &r, &g, &b) == 3) {
        if (a > 0.5f) {
            char hex[8];
            snprintf(hex, sizeof hex, "#%02X%02X%02X", r & 0xFF, g & 0xFF, b & 0xFF);
            return hex;
        }
    }
    return std::string();
}

// The page probes from Sources/CraCEF/CraCEF.mm; their answers come back as console messages.
#define CRA_PAGE_BACKGROUND_FN                                                                                  \
    "function(){var r=document.documentElement;if(!r)return '';"                                                \
    "var bg=function(e){var c=e?getComputedStyle(e).backgroundColor:'';return "                                 \
    "c&&c!=='transparent'&&c!=='rgba(0, 0, 0, 0)'?c:'';};"                                                      \
    "var c=bg(r)||bg(document.body);"                                                                           \
    "if(!c){var d=document.createElement('div');d.style.color='Canvas';r.appendChild(d);c=getComputedStyle(d)." \
    "color;d.remove();}"                                                                                        \
    "return c;}"

// The probes report through console.debug: OnConsoleMessage hears every level, and DevTools'
// Console hides Verbose messages unless asked, so Cra's reports stay out of a page's Console.
const char kBackgroundProbe[] =
    "(function(){if(!window.__craBg){var color=" CRA_PAGE_BACKGROUND_FN ";"
    "window.__craBg=function(){try{var c=color();if(c)console.debug('__cra_bg:'+c);}catch(e){}};"
    "matchMedia('(prefers-color-scheme: dark)').addEventListener('change',function(){setTimeout(window.__craBg,50);});"
    "setTimeout(window.__craBg,1500);}"
    "window.__craBg();})();";

const char kThemeProbe[] =
    "(function(){function probe(){try{var c='';var ms=document.querySelectorAll('meta[name=\"theme-color\"]');"
    "for(var i=0;i<ms.length;i++){if(!ms[i].getAttribute('media')){c=ms[i].getAttribute('content')||'';if(c)break;}}"
    "if(!c&&document.body){var b=getComputedStyle(document.body).backgroundColor;if(b&&b!=='rgba(0, 0, 0, "
    "0)'&&b!=='transparent'){c=b;}}"
    "if(!c){var h=getComputedStyle(document.documentElement).backgroundColor;if(h&&h!=='rgba(0, 0, 0, "
    "0)'&&h!=='transparent'){c=h;}}"
    "if(!c){c='rgb(255, 255, 255)';}"
    "var d=document.createElement('div');d.style.color=c;document.body.appendChild(d);"
    "var rgb=getComputedStyle(d).color;d.remove();console.debug('__cra_theme:'+rgb);}catch(e){}}"
    "probe();setTimeout(probe,1500);})();";

/// Settings for every page Cra makes. Cra draws its own status bubble.
void CraPageSettings(CefBrowserSettings &settings) { settings.chrome_status_bubble = STATE_DISABLED; }

/// Cra shows downloads itself, the way Arc does. Chrome's download bubble ("10Mb.dat · Done")
/// still pops up at the page's top left when a download finishes: Chrome's "Show downloads
/// when they're done" setting, off as on the Mac (HideDownloadBubble in CraCEF.mm).
void HideDownloadBubble(CefRefPtr<CefRequestContext> context) {
    if (!context) return;
    CefRefPtr<CefValue> off = CefValue::Create();
    off->SetBool(false);
    CefString error;
    if (!context->SetPreference("download_bubble.partial_view_enabled", off, error)) {
        fprintf(stderr, "CraCEFWin: download_bubble.partial_view_enabled: %s\n", error.ToString().c_str());
    }
}

/// The off-the-record profile private windows share (an empty cache path keeps cookies,
/// storage and cache in memory), until the last of them closes (cra_cef_end_incognito_session).
/// Its preferences get Cra's settings once it loads, as the Mac's IncognitoContext does.
class IncognitoContextHandler : public CefRequestContextHandler {
public:
    void OnRequestContextInitialized(CefRefPtr<CefRequestContext> context) override { HideDownloadBubble(context); }
private:
    IMPLEMENT_REFCOUNTING(IncognitoContextHandler);
};

CefRefPtr<CefRequestContext> g_incognitoContext;

CefRefPtr<CefRequestContext> IncognitoContext() {
    if (!g_incognitoContext) g_incognitoContext = CefRequestContext::CreateContext(CefRequestContextSettings(), new IncognitoContextHandler());
    return g_incognitoContext;
}

/// Arc's Profiles: a space's own cookies, logins, storage and cache in a folder next to Default
/// (it must sit under root_cache_path), one request context per folder so spaces on the same
/// profile share their sign-ins (ProfileContext in CraCEF.mm). An empty path is the global
/// Default profile. CreateBrowser waits for a context still loading from disk.
class ProfileContextHandler : public CefRequestContextHandler {
public:
    void OnRequestContextInitialized(CefRefPtr<CefRequestContext> context) override { HideDownloadBubble(context); }
private:
    IMPLEMENT_REFCOUNTING(ProfileContextHandler);
};

std::unordered_map<std::wstring, CefRefPtr<CefRequestContext>> g_profileContexts;

CefRefPtr<CefRequestContext> ProfileContext(const std::wstring &path) {
    if (path.empty()) return nullptr;
    auto it = g_profileContexts.find(path);
    if (it != g_profileContexts.end()) return it->second;
    CefRequestContextSettings settings;
    CefString(&settings.cache_path) = path;
    settings.persist_session_cookies = true;
    CefRefPtr<CefRequestContext> context = CefRequestContext::CreateContext(settings, new ProfileContextHandler());
    g_profileContexts[path] = context;
    return context;
}

std::wstring DownloadsFolder() {
    PWSTR path = nullptr;
    std::wstring out;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Downloads, 0, nullptr, &path)) && path) out = path;
    if (path) CoTaskMemFree(path);
    return out;
}

// Chrome's permission request types as the `kinds` bits (CraCEFWin.h), the table in
// Sources/CraCEF/CraCEF.mm, so the prompt can say what a page asks for.
const struct {
    uint32_t cef;
    uint32_t kind;
} kPermissionKinds[] = {
    {CEF_PERMISSION_TYPE_CAMERA_STREAM | CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM, CraPermissionCamera},
    {CEF_PERMISSION_TYPE_MIC_STREAM, CraPermissionMicrophone},
    {CEF_PERMISSION_TYPE_GEOLOCATION, CraPermissionLocation},
    {CEF_PERMISSION_TYPE_NOTIFICATIONS, CraPermissionNotifications},
    {CEF_PERMISSION_TYPE_CLIPBOARD, 1u << 5},
    {CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT, 1u << 6},
    {CEF_PERMISSION_TYPE_LOCAL_NETWORK_ACCESS_DEPRECATED | CEF_PERMISSION_TYPE_LOCAL_NETWORK, 1u << 7},
    {CEF_PERMISSION_TYPE_LOOPBACK_NETWORK, 1u << 8},
    {CEF_PERMISSION_TYPE_STORAGE_ACCESS, 1u << 9},
    {CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, 1u << 10},
    {CEF_PERMISSION_TYPE_LOCAL_FONTS, 1u << 11},
    {CEF_PERMISSION_TYPE_IDLE_DETECTION, 1u << 12},
    {CEF_PERMISSION_TYPE_MIDI_SYSEX, 1u << 13},
    {CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS, 1u << 14},
    {CEF_PERMISSION_TYPE_KEYBOARD_LOCK, 1u << 15},
    {CEF_PERMISSION_TYPE_POINTER_LOCK, 1u << 16},
    {CEF_PERMISSION_TYPE_PROTECTED_MEDIA_IDENTIFIER, 1u << 17},
    {CEF_PERMISSION_TYPE_REGISTER_PROTOCOL_HANDLER, 1u << 18},
    {CEF_PERMISSION_TYPE_AR_SESSION, 1u << 19},
    {CEF_PERMISSION_TYPE_VR_SESSION, 1u << 20},
    {CEF_PERMISSION_TYPE_HAND_TRACKING, 1u << 21},
    {CEF_PERMISSION_TYPE_SENSORS, 1u << 22},
    {CEF_PERMISSION_TYPE_DISK_QUOTA, 1u << 23},
    {CEF_PERMISSION_TYPE_IDENTITY_PROVIDER, 1u << 24},
    {CEF_PERMISSION_TYPE_CAPTURED_SURFACE_CONTROL, 1u << 25},
    {CEF_PERMISSION_TYPE_WEB_APP_INSTALLATION, 1u << 26},
    {CEF_PERMISSION_TYPE_FILE_SYSTEM_ACCESS, 1u << 27},
    {CEF_PERMISSION_TYPE_AMBIENT_LOGIN, 1u << 28},
};

uint32_t PermissionKinds(uint32_t requested) {
    uint32_t kinds = 0;
    for (const auto &k : kPermissionKinds) {
        if (requested & k.cef) kinds |= k.kind;
        requested &= ~k.cef;
    }
    return requested ? kinds | CraPermissionOther : kinds;
}

/// Routes DevTools protocol answers to cra_browser_send_dev_tools_method's callbacks (one
/// observer per page, registered on first use). Refcounted apart from the page, so an answer
/// arriving after the page is gone finds nothing to call.
class DevToolsObserver : public CefDevToolsMessageObserver {
public:
    std::unordered_map<int, std::pair<void *, CraDevToolsResult>> pending;

    void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id, bool success, const void *result,
                                size_t result_size) override {
        auto it = pending.find(message_id);
        if (it == pending.end()) return;
        auto [context, done] = it->second;
        pending.erase(it);
        if (done) done(context, success ? 1 : 0, static_cast<const char *>(result), result_size);
    }

    /// Every caller still waiting hears that no answer is coming.
    void FailAll() {
        auto waiting = std::move(pending);
        pending.clear();
        const char error[] = "{\"message\":\"the page closed\"}";
        for (auto &[id, call] : waiting)
            if (call.second) call.second(call.first, 0, error, sizeof error - 1);
    }

    IMPLEMENT_REFCOUNTING(DevToolsObserver);
};

// MARK: - Message pump

const UINT kMsgHaveWork = WM_USER + 1;
const int64_t kTimerDelayPlaceholder = INT_MAX;
const int64_t kMaxTimerDelay = 1000 / 30;  // Chromium asks again at least 30 times a second.
const UINT_PTR kTimerID = 1;

HWND g_pumpWindow = nullptr;
bool g_pumpTimerPending = false;
bool g_pumpActive = false;
bool g_pumpReentered = false;

void ScheduleWork(int64_t delay_ms) {
    if (g_pumpWindow) PostMessageW(g_pumpWindow, kMsgHaveWork, 0, static_cast<LPARAM>(delay_ms));
}

void KillPumpTimer() {
    if (!g_pumpTimerPending) return;
    KillTimer(g_pumpWindow, kTimerID);
    g_pumpTimerPending = false;
}

/// Returns true when CefDoMessageLoopWork was entered again from inside itself (a modal loop).
bool PerformWork() {
    if (g_pumpActive) {
        g_pumpReentered = true;
        return false;
    }
    g_pumpReentered = false;
    g_pumpActive = true;
    CefDoMessageLoopWork();
    g_pumpActive = false;
    return g_pumpReentered;
}

void DoWork() {
    if (PerformWork()) {
        ScheduleWork(0);
    } else if (!g_pumpTimerPending) {
        ScheduleWork(kTimerDelayPlaceholder);
    }
}

void OnScheduleWork(int64_t delay_ms) {
    if (delay_ms == kTimerDelayPlaceholder && g_pumpTimerPending) return;
    KillPumpTimer();
    if (delay_ms <= 0) {
        DoWork();
    } else {
        if (delay_ms > kMaxTimerDelay) delay_ms = kMaxTimerDelay;
        SetTimer(g_pumpWindow, kTimerID, static_cast<UINT>(delay_ms), nullptr);
        g_pumpTimerPending = true;
    }
}

LRESULT CALLBACK PumpWindowProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    if (msg == kMsgHaveWork) {
        OnScheduleWork(static_cast<int64_t>(lparam));
        return 0;
    }
    if (msg == WM_TIMER && wparam == kTimerID) {
        KillPumpTimer();
        DoWork();
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

void CreatePumpWindow() {
    HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof wc;
    wc.lpfnWndProc = PumpWindowProc;
    wc.hInstance = instance;
    wc.lpszClassName = L"CraCEFMessagePump";
    RegisterClassExW(&wc);
    g_pumpWindow = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, instance, nullptr);
}

// MARK: - Globals

class CraClient;
class DevToolsClient;

bool g_contextInitialized = false;
bool g_anotherInstanceNotified = false;
void *g_relaunchContext = nullptr;
CraRelaunchHandler g_relaunchHandler = nullptr;
std::set<CraBrowser *> g_browsers;
std::vector<CraBrowser *> g_pendingCreation;
uint64_t g_nextBrowserSerial = 1;
/// DevTools browsers Chromium hasn't finished closing (shutdown waits for them too).
int g_liveDevTools = 0;
/// The user undocked DevTools into a window of their own (the frontend's dock menu, which keeps
/// the choice in its own preferences): DevTools open there until they are docked again.
bool g_devToolsUndocked = false;

}  // namespace

// MARK: - CraBrowser

struct CraBrowser {
    CefRefPtr<CraClient> client;
    CefRefPtr<CefBrowser> browser;
    CraBrowserCallbacks callbacks{};
    HWND parent = nullptr;
    CefRect frame;
    bool visible = true;
    std::string pending_url;  // to create once Chromium's context is up
    bool is_popup_host = false;
    bool incognito = false;  // in the off-the-record profile
    std::wstring profile_path;  // a profile's folder; empty is Default
    bool close_requested = false;
    bool closed_by_page = false;
    bool focus_pending = false;  // focused before Chromium made the page: focus it once it is
    bool loading = false;
    bool can_go_back = false;
    bool can_go_forward = false;
    bool capturing_media = false;
    std::string current_url;
    std::string current_title;
    std::string favicon_downloaded;
    std::string returned;  // backing store for the strings the getters return
    uint64_t next_permission_id = 1;
    std::unordered_map<uint64_t, CefRefPtr<CefPermissionPromptCallback>> prompt_callbacks;
    std::unordered_map<uint64_t, std::pair<CefRefPtr<CefMediaAccessCallback>, uint32_t>> media_callbacks;
    CefRefPtr<DevToolsObserver> devtools;
    CefRefPtr<CefRegistration> devtools_registration;
    int next_devtools_id = 100000;  // clear of the ids Chromium's own clients use
    uint64_t serial = g_nextBrowserSerial++;  // tells a freed CraBrowser from a new one at its address

    // DevTools, the way Chrome docks them: the DevTools browser is a child window in the page's
    // place (`frame`), and its frontend (loaded with can_dock=true) draws the dock split and says
    // where the page goes (`devtools_bounds`, DIPs from its top left); the page window sits there,
    // above it, as Chrome's BrowserView lays the tab's contents over DevTools. Undocked, DevTools
    // are a window of their own and the page keeps its frame.
    CefRefPtr<CefBrowser> devtools_browser;
    CefRefPtr<DevToolsClient> devtools_client;
    bool devtools_hosted_docked = true;  // where the DevTools browser was made
    bool devtools_has_bounds = false;
    CefRect devtools_bounds;
    bool devtools_relocating = false;  // closing to open again docked or undocked
    bool devtools_quiet = false;  // that reopening: Swift heard of neither the close nor the open
    std::string devtools_action;

    /// Physical pixels per DIP on the parent window's monitor.
    double Scale() const {
        UINT dpi = parent ? GetDpiForWindow(parent) : 0;
        return dpi ? dpi / 96.0 : 1.0;
    }

    HWND DockedDevToolsWindow() const {
        return devtools_browser && devtools_hosted_docked ? devtools_browser->GetHost()->GetWindowHandle() : nullptr;
    }

    void ApplyFrame() {
        if (!browser) return;
        HWND hwnd = browser->GetHost()->GetWindowHandle();
        if (!hwnd) return;
        UINT flags = SWP_NOACTIVATE | (visible ? SWP_SHOWWINDOW : SWP_HIDEWINDOW);
        HWND devtools = DockedDevToolsWindow();
        CefRect page = frame;
        if (devtools && devtools_has_bounds) {
            double s = Scale();
            int x = static_cast<int>(devtools_bounds.x * s + 0.5), y = static_cast<int>(devtools_bounds.y * s + 0.5);
            int right = static_cast<int>((devtools_bounds.x + devtools_bounds.width) * s + 0.5);
            int bottom = static_cast<int>((devtools_bounds.y + devtools_bounds.height) * s + 0.5);
            x = std::clamp(x, 0, frame.width);
            y = std::clamp(y, 0, frame.height);
            right = std::clamp(right, x, frame.width);
            bottom = std::clamp(bottom, y, frame.height);
            page = CefRect(frame.x + x, frame.y + y, right - x, bottom - y);
        }
        // Above WinUI's content bridge window, which covers the whole client area.
        SetWindowPos(hwnd, HWND_TOP, page.x, page.y, page.width, page.height, flags);
        // Docked DevTools fill the page's place, under the page.
        if (devtools) SetWindowPos(devtools, hwnd, frame.x, frame.y, frame.width, frame.height, flags);
    }

    /// The frontend's own API, which Chrome's DevToolsWindow::DoAction calls through DevToolsAPI.
    void RunDevToolsAction() {
        if (devtools_action.empty() || !devtools_browser) return;
        std::string action = devtools_action;
        devtools_action.clear();
        std::string call;
        if (action == "inspect") {
            call = "enterInspectElementMode()";
        } else if (action == "console" || action == "network" || action == "elements") {
            call = "showPanel('" + action + "')";
        } else {
            return;
        }
        // Hooked frontends run it on loadCompleted (or at once once loaded); one loaded before the
        // hooks went in never reports it, so the call goes out after 3 s regardless.
        std::string js = "(function(){var h=window.InspectorFrontendHost,done=false;"
                         "function run(){if(done)return;done=true;var a=window.InspectorFrontendAPI;if(a)a." + call + ";}"
                         "if(!h||h.__craLoaded){run();return;}(h.__craRun=h.__craRun||[]).push(run);setTimeout(run,3000);})();";
        CefRefPtr<CefFrame> f = devtools_browser->GetMainFrame();
        if (f) f->ExecuteJavaScript(js, f->GetURL(), 0);
    }

    void Create();
    void Finish();
};

namespace {

class FaviconCallback : public CefDownloadImageCallback {
public:
    FaviconCallback(CraBrowser *owner, std::string url) : owner_(owner), url_(std::move(url)) {}

    void OnDownloadImageFinished(const CefString &image_url, int http_status_code, CefRefPtr<CefImage> image) override {
        if (!g_browsers.count(owner_) || owner_->close_requested || !image || image->IsEmpty()) return;
        int w = 0, h = 0;
        CefRefPtr<CefBinaryValue> png = image->GetAsPNG(2.0f, true, w, h);
        if (!png || png->GetSize() == 0) png = image->GetAsPNG(1.0f, true, w, h);
        if (!png || png->GetSize() == 0) return;
        std::vector<uint8_t> bytes(png->GetSize());
        png->GetData(bytes.data(), bytes.size(), 0);
        owner_->favicon_downloaded = url_;
        auto &cb = owner_->callbacks;
        if (cb.favicon_loaded) cb.favicon_loaded(cb.context, image_url.ToString().c_str(), bytes.data(), bytes.size());
    }

private:
    CraBrowser *owner_;
    std::string url_;
    IMPLEMENT_REFCOUNTING(FaviconCallback);
};

/// Chrome's own tab and window commands, which a Chrome-style browser (a page, or its DevTools)
/// runs for a key Cra leaves alone (Ctrl+T once the user moves New Tab elsewhere, Ctrl+N,
/// Ctrl+H...): each would open a bare Chromium window beside Cra's. Cra has its own versions.
bool IsBlockedChromeCommand(int command_id) {
    static const std::set<int> blocked = [] {
        std::set<int> ids;
        for (const char *name : {"IDC_NEW_TAB", "IDC_NEW_WINDOW", "IDC_NEW_INCOGNITO_WINDOW", "IDC_RESTORE_TAB",
                                 "IDC_CLOSE_TAB", "IDC_CLOSE_WINDOW", "IDC_EXIT", "IDC_SELECT_NEXT_TAB",
                                 "IDC_SELECT_PREVIOUS_TAB", "IDC_SELECT_TAB_0", "IDC_SELECT_TAB_1", "IDC_SELECT_TAB_2",
                                 "IDC_SELECT_TAB_3", "IDC_SELECT_TAB_4", "IDC_SELECT_TAB_5", "IDC_SELECT_TAB_6",
                                 "IDC_SELECT_TAB_7", "IDC_SELECT_LAST_TAB", "IDC_MOVE_TAB_NEXT", "IDC_MOVE_TAB_PREVIOUS",
                                 "IDC_DUPLICATE_TAB", "IDC_PIN_TARGET_TAB", "IDC_SHOW_HISTORY", "IDC_SHOW_DOWNLOADS",
                                 "IDC_SHOW_BOOKMARK_MANAGER", "IDC_BOOKMARK_THIS_TAB", "IDC_BOOKMARK_ALL_TABS",
                                 "IDC_SHOW_BOOKMARK_BAR", "IDC_OPTIONS", "IDC_CLEAR_BROWSING_DATA", "IDC_FOCUS_LOCATION",
                                 "IDC_FOCUS_SEARCH", "IDC_FOCUS_TOOLBAR", "IDC_FOCUS_BOOKMARKS", "IDC_SHOW_APP_MENU",
                                 "IDC_MANAGE_EXTENSIONS", "IDC_TASK_MANAGER", "IDC_HELP_PAGE_VIA_KEYBOARD",
                                 "IDC_FEEDBACK", "IDC_SHOW_AVATAR_MENU", "IDC_TOGGLE_FULLSCREEN_TOOLBAR"}) {
            int id = cef_id_for_command_id_name(name);
            if (id > 0) ids.insert(id);  // a name this Chromium lacks maps to -1
        }
        return ids;
    }();
    return blocked.count(command_id) > 0;
}

/// A key press as the C surface reports it.
CraKeyEvent KeyEventOf(const CefKeyEvent &event, CefEventHandle os_event) {
    CraKeyEvent e{};
    e.key_code = event.windows_key_code;
    e.modifiers = event.modifiers & (EVENTFLAG_SHIFT_DOWN | EVENTFLAG_CONTROL_DOWN | EVENTFLAG_ALT_DOWN);
    // Bit 30 of a WM_KEYDOWN's lParam: the key was already down.
    if (os_event) e.is_repeat = (os_event->lParam & (1 << 30)) ? 1 : 0;
    return e;
}

// MARK: - DevTools

// Chrome's DevTools the way Arc (plain Chromium) shows them, as on the Mac (CraCEF.mm): the
// frontend runs with can_dock=true, draws the dock split and the device toolbar itself, and tells
// the embedder where the page goes (InspectorFrontendHost.setInspectedPageBounds). CEF opens
// Chrome-style DevTools as an undockable popup, so the frontend is loaded again once with
// can_dock=true and its embedder calls are mirrored to the bridge as console messages. Its dock
// state comes from its own preferences when it loads, then from setIsDocked when the user picks
// another side or undocks.
const char kDevToolsHooks[] =
    "(function(){var h=window.InspectorFrontendHost;if(!h||h.__cra)return;h.__cra=1;"
    "function find(root,sel){var r=root.querySelector(sel);if(r)return r;var all=root.querySelectorAll('*');"
    "for(var i=0;i<all.length;i++){if(all[i].shadowRoot){var f=find(all[i].shadowRoot,sel);if(f)return f;}}return null;}"
    "h.closeWindow=function(){console.log('__cra_devtools_close');};"
    // Chrome asks the frontend for a panel or the element picker once it reports loadCompleted
    // (DevToolsWindow::DoAction); RunDevToolsAction queues on __craRun until then.
    "var lc=h.loadCompleted;h.loadCompleted=function(){var r=lc&&lc.apply(h,arguments);h.__craLoaded=1;"
    "var q=h.__craRun||[];h.__craRun=[];q.forEach(function(f){f();});return r;};"
    // The panel on show, so Console and Network can tell a switch from a close (GitHub #138):
    // the main tab bar is the one with Elements; its selected tab is #tab-<panel>.
    "(function(){var now=null,n=0,w=setInterval(function(){var e=find(document,'#tab-elements'),tabs=e&&e.parentNode;"
    "if(tabs){clearInterval(w);var report=function(){var t=tabs.querySelector('.tabbed-pane-header-tab.selected');"
    "var p=t&&t.id.indexOf('tab-')==0?t.id.slice(4):null;if(p&&p!==now){now=p;console.log('__cra_devtools_panel:'+p);}};"
    "report();new MutationObserver(report).observe(tabs,{attributes:true,subtree:true,attributeFilter:['class']});return;}"
    "if(++n>200)clearInterval(w);},150);})();"
    "if(!/[?&]can_dock=/.test(location.search))return;"
    "var sent=false;"
    "h.setInspectedPageBounds=function(b){sent=true;try{console.log('__cra_devtools_bounds:'+JSON.stringify({x:b.x,y:b.y,width:b.width,height:b.height}));}catch(e){}};"
    // Chrome never hears about docking: the bridge owns the layout. The frontend only needs the
    // acknowledgement (DockController waits for it before relayout).
    "h.setIsDocked=function(d,cb){console.log('__cra_devtools_docked:'+(d?1:0));if(cb)setTimeout(function(){cb();},0);};"
    // Docked frontends re-send the placeholder on resize.
    "window.dispatchEvent(new Event('resize'));"
    // Where the frontend means to be: its saved dock side ('\"right\"', '\"undocked\"'...; right
    // when it has none). Without getPreferences, a frontend that sent no placeholder is undocked.
    "var told=false;function tell(d){if(told)return;told=true;console.log('__cra_devtools_docked:'+(d?1:0));}"
    "if(h.getPreferences){try{h.getPreferences(function(p){var d=true;try{var s=p&&p.currentDockState;"
    "if(s)d=JSON.parse(s)!=='undocked';}catch(e){}tell(d);});}catch(e){tell(true);}}"
    "else{setTimeout(function(){tell(sent);},600);}"
    "})();";

/// Opens a page's DevTools again after they closed to move (docked to undocked or back). Posted:
/// a browser can't open DevTools from inside its DevTools' close.
class ReopenDevTools : public CefTask {
public:
    ReopenDevTools(CraBrowser *owner, uint64_t serial) : owner_(owner), serial_(serial) {}
    void Execute() override {
        CraBrowser *o = owner_;
        if (!g_browsers.count(o) || o->serial != serial_ || o->close_requested || !o->browser) return;
        o->browser->GetHost()->ShowDevTools(CefWindowInfo(), nullptr, CefBrowserSettings(), CefPoint());
    }

private:
    CraBrowser *owner_;
    uint64_t serial_;
    IMPLEMENT_REFCOUNTING(ReopenDevTools);
};

/// A page's DevTools browser (made through OnBeforeDevToolsPopup). Detached when its page goes.
class DevToolsClient : public CefClient,
                       public CefLifeSpanHandler,
                       public CefLoadHandler,
                       public CefDisplayHandler,
                       public CefKeyboardHandler,
                       public CefCommandHandler {
public:
    explicit DevToolsClient(CraBrowser *owner) : owner_(owner) {}
    void Detach() { owner_ = nullptr; }

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
    CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }

    // The frontend's own helper pages (device_mode_emulation_frame.html) would become stray
    // windows; Chrome never shows them either. A link it opens (a source map, a doc page) goes to
    // a new tab.
    bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                       const CefString &target_url, const CefString &target_frame_name,
                       WindowOpenDisposition target_disposition, bool user_gesture,
                       const CefPopupFeatures &popupFeatures, CefWindowInfo &windowInfo, CefRefPtr<CefClient> &client,
                       CefBrowserSettings &settings, CefRefPtr<CefDictionaryValue> &extra_info,
                       bool *no_javascript_access) override {
        std::string url = target_url.ToString();
        if (url.rfind("devtools://", 0) == 0 || url.empty() || url == "about:blank") return true;
        CraBrowser *o = Live();
        if (o && o->callbacks.new_tab_requested) o->callbacks.new_tab_requested(o->callbacks.context, url.c_str(), 0);
        return true;
    }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        g_liveDevTools++;
        CraBrowser *o = Live();
        if (!o) return;  // its page is closing, and takes DevTools with it
        o->devtools_browser = browser;
        o->devtools_has_bounds = false;
        o->ApplyFrame();
        // The frontend may already be loaded by now.
        CefRefPtr<CefFrame> main = browser->GetMainFrame();
        if (main && !browser->IsLoading()) Prepare(main);
        if (o->devtools_quiet) {
            o->devtools_quiet = false;
        } else if (o->callbacks.dev_tools_opened) {
            o->callbacks.dev_tools_opened(o->callbacks.context);
        }
    }

    bool DoClose(CefRefPtr<CefBrowser> browser) override { return false; }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        g_liveDevTools--;
        CefRefPtr<DevToolsClient> keep(this);  // the owner may hold the last other reference
        CraBrowser *o = owner_;
        if (!o) return;
        if (o->devtools_browser && o->devtools_browser->IsSame(browser)) o->devtools_browser = nullptr;
        if (o->devtools_client.get() == this) o->devtools_client = nullptr;
        owner_ = nullptr;
        o->devtools_has_bounds = false;
        if (o->close_requested) return;
        o->ApplyFrame();  // the page takes its whole place again
        if (o->devtools_relocating) {
            o->devtools_relocating = false;
            o->devtools_quiet = true;
            CefPostTask(TID_UI, new ReopenDevTools(o, o->serial));
            return;
        }
        o->devtools_quiet = false;
        if (o->callbacks.dev_tools_closed) o->callbacks.dev_tools_closed(o->callbacks.context);
    }

    void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType transition_type) override {
        // Chrome picks the frontend URL, so the earliest point to swap in can_dock=true is the
        // first load's start: the frontend app then loads once instead of twice.
        if (frame->IsMain()) MakeDockable(frame);
    }

    void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int httpStatusCode) override {
        if (frame->IsMain()) Prepare(frame);
    }

    bool OnConsoleMessage(CefRefPtr<CefBrowser> browser, cef_log_severity_t level, const CefString &message,
                          const CefString &source, int line) override {
        static const std::string kClose = "__cra_devtools_close", kBounds = "__cra_devtools_bounds:",
                                 kDocked = "__cra_devtools_docked:", kPanel = "__cra_devtools_panel:";
        std::string m = message.ToString();
        bool bounds = m.rfind(kBounds, 0) == 0, docked = m.rfind(kDocked, 0) == 0, panel = m.rfind(kPanel, 0) == 0;
        if (m != kClose && !bounds && !docked && !panel) return false;
        CraBrowser *o = Live();
        if (!o || !o->browser || !o->devtools_browser || !o->devtools_browser->IsSame(browser)) return true;
        if (m == kClose) {
            o->devtools_relocating = false;
            o->browser->GetHost()->CloseDevTools();
        } else if (bounds) {
            CefRefPtr<CefValue> value = CefParseJSON(m.substr(kBounds.size()), JSON_PARSER_RFC);
            if (value && value->GetType() == VTYPE_DICTIONARY) {
                CefRefPtr<CefDictionaryValue> d = value->GetDictionary();
                auto number = [&](const char *key) {
                    return d->GetType(key) == VTYPE_INT ? d->GetInt(key) : static_cast<int>(d->GetDouble(key) + 0.5);
                };
                o->devtools_bounds = CefRect(number("x"), number("y"), number("width"), number("height"));
                o->devtools_has_bounds = true;
                o->ApplyFrame();
            }
        } else if (docked) {
            bool dock = m.size() > kDocked.size() && m[kDocked.size()] == '1';
            g_devToolsUndocked = !dock;
            if (o->devtools_relocating) return true;
            if (dock != o->devtools_hosted_docked) {
                // In the wrong place: close and open again where the frontend wants to be.
                o->devtools_relocating = true;
                o->browser->GetHost()->CloseDevTools();
            } else if (!dock) {
                o->devtools_has_bounds = false;
                o->ApplyFrame();
            }
        } else if (o->callbacks.dev_tools_panel) {
            o->callbacks.dev_tools_panel(o->callbacks.context, m.c_str() + kPanel.size());
        }
        return true;
    }

    bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent &event, CefEventHandle os_event,
                       bool *is_keyboard_shortcut) override {
        CraBrowser *o = Live();
        if (!o || event.type != KEYEVENT_RAWKEYDOWN || !o->callbacks.dev_tools_key_event) return false;
        CraKeyEvent e = KeyEventOf(event, os_event);
        return o->callbacks.dev_tools_key_event(o->callbacks.context, &e) != 0;
    }

    bool OnChromeCommand(CefRefPtr<CefBrowser> browser, int command_id, cef_window_open_disposition_t disposition) override {
        return IsBlockedChromeCommand(command_id);
    }

private:
    CraBrowser *Live() const { return owner_ && !owner_->close_requested ? owner_ : nullptr; }

    static bool IsFrontend(const std::string &url) {
        // Only the main frontend; helper pages it opens must not report dock state or bounds.
        return url.rfind("devtools://", 0) == 0 &&
               (url.find("/devtools_app.html") != std::string::npos || url.find("/inspector.html") != std::string::npos);
    }

    // A Chrome-style frontend opens undockable; load it again with can_dock=true (once).
    bool MakeDockable(CefRefPtr<CefFrame> frame) {
        std::string url = frame->GetURL().ToString();
        if (reloaded_ || !IsFrontend(url) || url.find("can_dock=") != std::string::npos) return false;
        reloaded_ = true;
        frame->LoadURL(url + (url.find('?') == std::string::npos ? "?" : "&") + "can_dock=true");
        return true;
    }

    // Hooks the dockable frontend once it has loaded, then runs the action waiting for it.
    void Prepare(CefRefPtr<CefFrame> frame) {
        std::string url = frame->GetURL().ToString();
        if (!IsFrontend(url) || MakeDockable(frame)) return;
        // The undockable load that MakeDockable replaced still reports its end.
        if (reloaded_ && url.find("can_dock=") == std::string::npos) return;
        frame->ExecuteJavaScript(kDevToolsHooks, frame->GetURL(), 0);
        if (CraBrowser *o = Live()) o->RunDevToolsAction();
    }

    CraBrowser *owner_;
    bool reloaded_ = false;
    IMPLEMENT_REFCOUNTING(DevToolsClient);
};

/// One page (or a popup host waiting for its popup). Holds its CraBrowser until OnBeforeClose.
class CraClient : public CefClient,
                  public CefDisplayHandler,
                  public CefLifeSpanHandler,
                  public CefLoadHandler,
                  public CefRequestHandler,
                  public CefKeyboardHandler,
                  public CefDownloadHandler,
                  public CefFocusHandler,
                  public CefPermissionHandler,
                  public CefFindHandler,
                  public CefCommandHandler {
public:
    explicit CraClient(CraBrowser *owner) : owner_(owner) {}
    void Detach() { owner_ = nullptr; }

    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
    CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
    CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
    CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
    CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }

    // Life span -----------------------------------------------------------

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        CraBrowser *o = owner_;
        if (!o) {
            browser->GetHost()->CloseBrowser(true);
            return;
        }
        o->browser = browser;
        o->ApplyFrame();
        if (!o->visible) browser->GetHost()->WasHidden(true);
        if (o->focus_pending && o->visible) cra_browser_set_focused(o, 1);
        o->focus_pending = false;
        if (o->close_requested) browser->GetHost()->CloseBrowser(true);
    }

    bool DoClose(CefRefPtr<CefBrowser> browser) override {
        // window.close() from the page, as opposed to cra_browser_close.
        if (CraBrowser *o = owner_; o && !o->close_requested) o->closed_by_page = true;
        return false;  // let CEF destroy the window
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        CraBrowser *o = owner_;
        if (!o) return;
        o->browser = nullptr;
        o->Finish();
    }

    bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                       const CefString &target_url, const CefString &target_frame_name,
                       WindowOpenDisposition target_disposition, bool user_gesture,
                       const CefPopupFeatures &popupFeatures, CefWindowInfo &windowInfo, CefRefPtr<CefClient> &client,
                       CefBrowserSettings &settings, CefRefPtr<CefDictionaryValue> &extra_info,
                       bool *no_javascript_access) override {
        CEF_REQUIRE_UI_THREAD();
        CraBrowser *o = owner_;
        if (!o || o->close_requested || !o->callbacks.popup_host_requested) return true;
        bool background = target_disposition == CEF_WOD_NEW_BACKGROUND_TAB;
        CraBrowser *host = o->callbacks.popup_host_requested(o->callbacks.context, target_url.ToString().c_str(),
                                                             background ? 1 : 0);
        if (!host || !g_browsers.count(host) || !host->is_popup_host || host->browser) return true;  // blocked
        host->is_popup_host = false;
        client = host->client;
        CraPageSettings(settings);
        windowInfo.SetAsChild(host->parent, host->frame);
        return false;  // CEF creates it in the host's place, with the opener kept
    }

    /// The page's DevTools, from cra_browser_show_dev_tools or Chromium's own Inspect: docked in
    /// the page's place (a child window under it, ApplyFrame), or in a window of their own once
    /// the user undocked them.
    void OnBeforeDevToolsPopup(CefRefPtr<CefBrowser> browser, CefWindowInfo &windowInfo, CefRefPtr<CefClient> &client,
                               CefBrowserSettings &settings, CefRefPtr<CefDictionaryValue> &extra_info,
                               bool *use_default_window) override {
        CEF_REQUIRE_UI_THREAD();
        CraBrowser *o = Live();
        if (!o) return;
        o->devtools_client = new DevToolsClient(o);
        client = o->devtools_client;
        o->devtools_hosted_docked = !g_devToolsUndocked;
        o->devtools_has_bounds = false;
        if (o->devtools_hosted_docked) {
            windowInfo.SetAsChild(o->parent, o->frame);
            if (!o->visible) windowInfo.style &= ~static_cast<DWORD>(WS_VISIBLE);
        } else {
            // Chrome's undocked DevTools: a normal window, 80% of the browser window's size.
            HWND root = GetAncestor(o->parent, GA_ROOT);
            RECT r{};
            if (!root || !GetWindowRect(root, &r)) r = RECT{100, 100, 1380, 920};
            double s = o->Scale();
            int ww = r.right - r.left, wh = r.bottom - r.top;
            int w = std::clamp(ww * 8 / 10, static_cast<int>(700 * s), static_cast<int>(1100 * s));
            int h = std::clamp(wh * 8 / 10, static_cast<int>(500 * s), static_cast<int>(800 * s));
            windowInfo.SetAsPopup(nullptr, "DevTools");
            windowInfo.bounds = CefRect(r.left + (ww - w) / 2 + static_cast<int>(40 * s),
                                        r.top + (wh - h) / 2 + static_cast<int>(20 * s), w, h);
        }
        *use_default_window = false;
    }

    // Display -------------------------------------------------------------

    void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString &title) override {
        CraBrowser *o = Live();
        if (!o) return;
        o->current_title = title.ToString();
        if (o->callbacks.title_changed) o->callbacks.title_changed(o->callbacks.context, o->current_title.c_str());
    }

    void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString &url) override {
        CraBrowser *o = Live();
        if (!o || !frame->IsMain()) return;
        o->current_url = url.ToString();
        if (o->callbacks.address_changed) o->callbacks.address_changed(o->callbacks.context, o->current_url.c_str());
    }

    void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString> &icon_urls) override {
        CraBrowser *o = Live();
        if (!o || icon_urls.empty() || !o->callbacks.favicon_loaded) return;
        // Prefer PNG/ICO-looking URLs over SVG, which CEF can't decode.
        CefString chosen = icon_urls.front();
        for (const auto &u : icon_urls) {
            if (u.ToString().find(".svg") == std::string::npos) {
                chosen = u;
                break;
            }
        }
        std::string chosenStr = chosen.ToString();
        if (chosenStr == o->favicon_downloaded) return;
        browser->GetHost()->DownloadImage(chosen, true, 64, false, new FaviconCallback(o, chosenStr));
    }

    void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser, bool fullscreen) override {
        CraBrowser *o = Live();
        if (o && o->callbacks.fullscreen_changed) o->callbacks.fullscreen_changed(o->callbacks.context, fullscreen);
    }

    void OnStatusMessage(CefRefPtr<CefBrowser> browser, const CefString &value) override {
        CraBrowser *o = Live();
        if (o && o->callbacks.status_message_changed)
            o->callbacks.status_message_changed(o->callbacks.context, value.ToString().c_str());
    }

    void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) override {
        CraBrowser *o = Live();
        if (o && o->callbacks.progress_changed) o->callbacks.progress_changed(o->callbacks.context, progress);
    }

    void OnMediaAccessChange(CefRefPtr<CefBrowser> browser, bool has_video_access, bool has_audio_access) override {
        CraBrowser *o = Live();
        if (!o) return;
        bool capturing = has_video_access || has_audio_access;
        if (capturing == o->capturing_media) return;
        o->capturing_media = capturing;
        if (o->callbacks.media_capture_changed) o->callbacks.media_capture_changed(o->callbacks.context, capturing);
    }

    bool OnConsoleMessage(CefRefPtr<CefBrowser> browser, cef_log_severity_t level, const CefString &message,
                          const CefString &source, int line) override {
        std::string m = message.ToString();
        const std::string bg = "__cra_bg:", theme = "__cra_theme:";
        CraBrowser *o = Live();
        if (m.compare(0, bg.size(), bg) == 0) {
            std::string hex = HexFromCSSColor(m.substr(bg.size()));
            if (o && !hex.empty() && o->callbacks.background_color_reported)
                o->callbacks.background_color_reported(o->callbacks.context, hex.c_str());
            return true;
        }
        if (m.compare(0, theme.size(), theme) == 0) {
            std::string rgb = m.substr(theme.size());
            std::string hex = rgb == "none" ? "none" : HexFromCSSColor(rgb);
            if (o && o->callbacks.theme_color_reported) o->callbacks.theme_color_reported(o->callbacks.context, hex.c_str());
            return true;
        }
        return false;
    }

    // Load ----------------------------------------------------------------

    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack,
                              bool canGoForward) override {
        CraBrowser *o = Live();
        if (!o) return;
        o->loading = isLoading;
        o->can_go_back = canGoBack;
        o->can_go_forward = canGoForward;
        if (o->callbacks.loading_changed)
            o->callbacks.loading_changed(o->callbacks.context, isLoading, canGoBack, canGoForward);
    }

    void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType transition_type) override {
        CraBrowser *o = Live();
        if (!o || !frame->IsMain()) return;
        if (o->callbacks.background_color_reported) o->callbacks.background_color_reported(o->callbacks.context, "");
    }

    void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int httpStatusCode) override {
        if (!frame->IsMain()) return;
        CraBrowser *o = Live();
        if (!o) return;
        if (o->callbacks.load_finished)
            o->callbacks.load_finished(o->callbacks.context, frame->GetURL().ToString().c_str(), httpStatusCode);
        frame->ExecuteJavaScript(kThemeProbe, frame->GetURL(), 0);
        frame->ExecuteJavaScript(kBackgroundProbe, frame->GetURL(), 0);
    }

    void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode errorCode,
                     const CefString &errorText, const CefString &failedUrl) override {
        if (!frame->IsMain() || errorCode == ERR_ABORTED) return;
        LOG(WARNING) << "Cra: loading failed: " << errorText.ToString() << " (" << static_cast<int>(errorCode) << ")";
    }

    // Request -------------------------------------------------------------

    bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString &target_url,
                          WindowOpenDisposition target_disposition, bool user_gesture) override {
        CraBrowser *o = Live();
        if (!o || !o->callbacks.new_tab_requested) return false;
        bool background = target_disposition == CEF_WOD_NEW_BACKGROUND_TAB;
        o->callbacks.new_tab_requested(o->callbacks.context, target_url.ToString().c_str(), background ? 1 : 0);
        return true;
    }

    void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus status, int error_code,
                                   const CefString &error_string) override {
        LOG(ERROR) << "Cra: a renderer ended (status " << static_cast<int>(status) << ", code " << error_code << ", "
                   << error_string.ToString() << ")";
    }

    // Keyboard ------------------------------------------------------------

    bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent &event, CefEventHandle os_event,
                       bool *is_keyboard_shortcut) override {
        CraBrowser *o = Live();
        if (!o || event.type != KEYEVENT_RAWKEYDOWN || !o->callbacks.key_event) return false;
        CraKeyEvent e = KeyEventOf(event, os_event);
        return o->callbacks.key_event(o->callbacks.context, &e) != 0;
    }

    bool OnKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent &event, CefEventHandle os_event) override {
        CraBrowser *o = Live();
        if (!o || event.type != KEYEVENT_RAWKEYDOWN || !o->callbacks.unhandled_key_event) return false;
        CraKeyEvent e = KeyEventOf(event, os_event);
        return o->callbacks.unhandled_key_event(o->callbacks.context, &e) != 0;
    }

    // Chrome commands -----------------------------------------------------

    /// Chrome's own tab and window commands stop here (IsBlockedChromeCommand). Find, print, zoom,
    /// DevTools and the edit commands keep Chrome's behaviour.
    bool OnChromeCommand(CefRefPtr<CefBrowser> browser, int command_id, cef_window_open_disposition_t disposition) override {
        return IsBlockedChromeCommand(command_id);
    }

    // Downloads -----------------------------------------------------------

    bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> download_item,
                          const CefString &suggested_name, CefRefPtr<CefBeforeDownloadCallback> callback) override {
        std::wstring name = suggested_name.ToWString();
        if (name.empty()) name = L"download";
        std::wstring dir = DownloadsFolder();
        if (dir.empty()) {
            callback->Continue(CefString(), true);  // Chromium's own Save As dialog
            return true;
        }
        size_t dot = name.find_last_of(L'.');
        std::wstring base = dot == std::wstring::npos || dot == 0 ? name : name.substr(0, dot);
        std::wstring ext = dot == std::wstring::npos || dot == 0 ? L"" : name.substr(dot);
        std::wstring path = dir + L"\\" + name;
        for (int n = 1; GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES; n++) {
            path = dir + L"\\" + base + L" (" + std::to_wstring(n) + L")" + ext;
        }
        callback->Continue(CefString(path), false);
        return true;
    }

    void OnDownloadUpdated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
                           CefRefPtr<CefDownloadItemCallback> callback) override {
        CraBrowser *o = Live();
        if (!o || !o->callbacks.download_updated) return;
        std::string url = item->GetURL().ToString(), path = item->GetFullPath().ToString(),
                    name = item->GetSuggestedFileName().ToString();
        CraDownloadInfo info{};
        info.identifier = item->GetId();
        info.url = url.c_str();
        info.full_path = path.c_str();
        info.suggested_name = name.c_str();
        info.received_bytes = item->GetReceivedBytes();
        info.total_bytes = item->GetTotalBytes();
        info.percent = item->GetPercentComplete();
        info.state = item->IsComplete()      ? CraDownloadStateComplete
                     : item->IsCanceled()    ? CraDownloadStateCancelled
                     : item->IsInterrupted() ? CraDownloadStateInterrupted
                                             : CraDownloadStateInProgress;
        o->callbacks.download_updated(o->callbacks.context, &info);
    }

    // Focus ---------------------------------------------------------------

    void OnGotFocus(CefRefPtr<CefBrowser> browser) override {
        CraBrowser *o = Live();
        if (o && o->callbacks.focus_received) o->callbacks.focus_received(o->callbacks.context);
    }

    // Permissions ---------------------------------------------------------

    bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                        const CefString &requesting_origin, uint32_t requested_permissions,
                                        CefRefPtr<CefMediaAccessCallback> callback) override {
        CraBrowser *o = Live();
        if (!o || !o->callbacks.permission_requested) return false;
        // Chrome-style pages use Chrome's permission flow (OnShowPermissionPrompt).
        if (browser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_CHROME) return false;
        uint32_t kinds = 0;
        if (requested_permissions &
            (CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE))
            kinds |= CraPermissionCamera;
        if (requested_permissions &
            (CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE))
            kinds |= CraPermissionMicrophone;
        uint64_t id = o->next_permission_id++;
        o->media_callbacks[id] = {callback, requested_permissions};
        o->callbacks.permission_requested(o->callbacks.context, id, requesting_origin.ToString().c_str(), kinds);
        return true;
    }

    bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt_id, const CefString &requesting_origin,
                                uint32_t requested_permissions,
                                CefRefPtr<CefPermissionPromptCallback> callback) override {
        CraBrowser *o = Live();
        if (!o || !o->callbacks.permission_requested) return false;
        // A page's <usermedia> or <permission> element (Meet's "Use microphone and camera") can
        // ask again for the requests just allowed, from inside Continue. Those are decided, and
        // a second answer hits a CHECK in Chromium (#111 on the Mac): close this one the way
        // Chrome's close button does. CEF runs this Continue after we return.
        if (answering_prompt_) {
            callback->Continue(CEF_PERMISSION_RESULT_DISMISS);
            return true;
        }
        uint64_t id = o->next_permission_id++;
        o->prompt_callbacks[id] = callback;
        o->callbacks.permission_requested(o->callbacks.context, id, requesting_origin.ToString().c_str(),
                                          PermissionKinds(requested_permissions));
        return true;
    }

    /// True while a prompt's answer runs (UI thread only); cra_browser_answer_permission sets it.
    static inline bool answering_prompt_ = false;

    // Find ----------------------------------------------------------------

    void OnFindResult(CefRefPtr<CefBrowser> browser, int identifier, int count, const CefRect &selectionRect,
                      int activeMatchOrdinal, bool finalUpdate) override {
        CraBrowser *o = Live();
        if (o && o->callbacks.find_result) o->callbacks.find_result(o->callbacks.context, count, activeMatchOrdinal);
    }

private:
    /// The owner, unless it asked to close: then only `closed` still fires.
    CraBrowser *Live() const { return owner_ && !owner_->close_requested ? owner_ : nullptr; }

    CraBrowser *owner_;
    IMPLEMENT_REFCOUNTING(CraClient);
};

class CraApp : public CefApp, public CefBrowserProcessHandler {
public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

    void OnBeforeCommandLineProcessing(const CefString &process_type, CefRefPtr<CefCommandLine> command_line) override {
        if (!process_type.empty()) return;
        // Cra's windows are its own; Chrome must not open, restore or reopen any.
        command_line->AppendSwitch("no-startup-window");
        command_line->AppendSwitch("disable-session-crashed-bubble");
        command_line->AppendSwitch("hide-crash-restore-bubble");
        command_line->AppendSwitch("no-first-run");
        command_line->AppendSwitchWithValue("autoplay-policy", "document-user-activation-required");
    }

    void OnContextInitialized() override {
        CEF_REQUIRE_UI_THREAD();
        g_contextInitialized = true;
        HideDownloadBubble(CefRequestContext::GetGlobalContext());
        std::vector<CraBrowser *> pending;
        pending.swap(g_pendingCreation);
        for (CraBrowser *b : pending) {
            if (g_browsers.count(b)) b->Create();
        }
    }

    // Another Cra launch (a link from another app). Chromium's process singleton hands its
    // command line to us; without this CEF opens a stock Chrome window.
    bool OnAlreadyRunningAppRelaunch(CefRefPtr<CefCommandLine> command_line,
                                     const CefString &current_directory) override {
        CEF_REQUIRE_UI_THREAD();
        std::vector<CefString> args;
        command_line->GetArguments(args);
        std::vector<std::string> urls;
        for (const auto &a : args) {
            std::string s = a.ToString();
            if (s.rfind("http://", 0) == 0 || s.rfind("https://", 0) == 0 || s.rfind("cra://", 0) == 0 ||
                s.rfind("file://", 0) == 0)
                urls.push_back(s);
        }
        std::vector<const char *> pointers;
        for (const auto &u : urls) pointers.push_back(u.c_str());
        if (g_relaunchHandler) g_relaunchHandler(g_relaunchContext, pointers.data(), pointers.size());
        return true;
    }

    void OnScheduleMessagePumpWork(int64_t delay_ms) override { ScheduleWork(delay_ms); }

private:
    IMPLEMENT_REFCOUNTING(CraApp);
};

}  // namespace

void CraBrowser::Create() {
    CefWindowInfo info;
    info.SetAsChild(parent, frame);
    CefBrowserSettings settings;
    CraPageSettings(settings);
    CefBrowserHost::CreateBrowser(info, client, pending_url.empty() ? "about:blank" : pending_url, settings, nullptr,
                                  incognito ? IncognitoContext() : ProfileContext(profile_path));
}

/// Chromium is done with the page (or never had one): tell Swift, then free it.
void CraBrowser::Finish() {
    if (!g_browsers.erase(this)) return;
    std::erase(g_pendingCreation, this);
    client->Detach();
    if (devtools_client) devtools_client->Detach();
    devtools_client = nullptr;
    devtools_browser = nullptr;
    for (auto &[id, cb] : prompt_callbacks) cb->Continue(CEF_PERMISSION_RESULT_DISMISS);
    for (auto &[id, pair] : media_callbacks) pair.first->Cancel();
    prompt_callbacks.clear();
    media_callbacks.clear();
    devtools_registration = nullptr;
    if (devtools) devtools->FailAll();
    if (callbacks.closed) callbacks.closed(callbacks.context);
    delete this;
}

// MARK: - C surface: runtime

extern "C" int cra_cef_execute_process(void) {
    CefMainArgs main_args(GetModuleHandleW(nullptr));
    return CefExecuteProcess(main_args, nullptr, nullptr);
}

extern "C" int cra_cef_initialize(const CraCEFSettings *s) {
    if (!s) return 0;
    CreatePumpWindow();
    CefMainArgs main_args(GetModuleHandleW(nullptr));
    CefSettings settings;
    settings.no_sandbox = true;  // The sandbox needs cef_sandbox.lib linked into the exe; later.
    settings.multi_threaded_message_loop = false;
    settings.external_message_pump = true;
    settings.persist_session_cookies = true;
    CefString(&settings.browser_subprocess_path) = Wide(s->helper_path);
    CefString(&settings.root_cache_path) = Wide(s->cache_root);
    CefString(&settings.cache_path) = Wide(s->cache_root) + L"\\Default";
    if (s->log_path) CefString(&settings.log_file) = Wide(s->log_path);
    settings.log_severity = LOGSEVERITY_WARNING;
    if (s->user_agent_product) CefString(&settings.user_agent_product) = Wide(s->user_agent_product);
    settings.background_color = CefColorSetARGB(255, 255, 255, 255);
    CefRefPtr<CraApp> app(new CraApp);
    if (!CefInitialize(main_args, settings, app, nullptr)) {
        g_anotherInstanceNotified = CefGetExitCode() == CEF_RESULT_CODE_NORMAL_EXIT_PROCESS_NOTIFIED;
        return 0;
    }
    ScheduleWork(0);
    return 1;
}

extern "C" int cra_cef_another_instance_was_notified(void) { return g_anotherInstanceNotified ? 1 : 0; }

extern "C" void cra_cef_set_relaunch_handler(void *context, CraRelaunchHandler handler) {
    g_relaunchContext = context;
    g_relaunchHandler = handler;
}

extern "C" void cra_cef_shutdown(void) {
    std::vector<CraBrowser *> open(g_browsers.begin(), g_browsers.end());
    for (CraBrowser *b : open) cra_browser_close(b);
    // Let Chromium destroy the pages: pump its work and the windows' messages until they are
    // gone, for at most five seconds.
    ULONGLONG deadline = GetTickCount64() + 5000;
    while ((!g_browsers.empty() || g_liveDevTools > 0) && GetTickCount64() < deadline) {
        CefDoMessageLoopWork();
        MSG msg;
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Sleep(10);
    }
    g_incognitoContext = nullptr;
    g_profileContexts.clear();
    KillPumpTimer();
    if (g_pumpWindow) DestroyWindow(g_pumpWindow);
    g_pumpWindow = nullptr;
    CefShutdown();
}

extern "C" int cra_cef_live_browser_count(void) { return static_cast<int>(g_browsers.size()); }

extern "C" void cra_cef_end_incognito_session(void) { g_incognitoContext = nullptr; }

extern "C" const char *cra_cef_chromium_version(void) {
    static char version[64];
    snprintf(version, sizeof version, "%d.%d.%d.%d", CHROME_VERSION_MAJOR, CHROME_VERSION_MINOR, CHROME_VERSION_BUILD,
             CHROME_VERSION_PATCH);
    return version;
}

extern "C" const char *cra_cef_version(void) { return CEF_VERSION; }

// MARK: - C surface: browser

extern "C" CraBrowser *cra_browser_create(uintptr_t parent, int x, int y, int width, int height, const char *url,
                                          CraBrowserCallbacks callbacks) {
    return cra_browser_create_in(parent, x, y, width, height, url, 0, nullptr, callbacks);
}

extern "C" CraBrowser *cra_browser_create_in(uintptr_t parent, int x, int y, int width, int height, const char *url,
                                             int incognito, const char *profile_path, CraBrowserCallbacks callbacks) {
    auto *b = new CraBrowser;
    b->incognito = incognito != 0;
    if (!b->incognito) b->profile_path = Wide(profile_path);
    b->client = new CraClient(b);
    b->callbacks = callbacks;
    b->parent = reinterpret_cast<HWND>(parent);
    b->frame = CefRect(x, y, width, height);
    g_browsers.insert(b);
    if (!url) {
        b->is_popup_host = true;
        return b;
    }
    b->pending_url = url;
    if (g_contextInitialized) {
        b->Create();
    } else {
        g_pendingCreation.push_back(b);
    }
    return b;
}

extern "C" void cra_browser_set_frame(CraBrowser *b, int x, int y, int width, int height) {
    if (!b) return;
    b->frame = CefRect(x, y, width, height);
    b->ApplyFrame();
}

extern "C" void cra_browser_set_visible(CraBrowser *b, int visible) {
    if (!b || b->visible == (visible != 0)) return;
    b->visible = visible != 0;
    b->ApplyFrame();
    if (b->browser) b->browser->GetHost()->WasHidden(!b->visible);
}

extern "C" void cra_browser_set_focused(CraBrowser *b, int focused) {
    if (!b) return;
    // A new page is made asynchronously; without this, focus stayed on the page shown before.
    b->focus_pending = focused != 0 && !b->browser;
    if (!b->browser) return;
    // CEF's SetFocus doesn't move Win32 focus off XAML's input site, so keys would stay there.
    if (focused) {
        if (HWND hwnd = b->browser->GetHost()->GetWindowHandle()) SetFocus(hwnd);
    }
    b->browser->GetHost()->SetFocus(focused != 0);
}

extern "C" void cra_browser_load_url(CraBrowser *b, const char *url) {
    if (!b || !url) return;
    if (b->browser) {
        b->browser->GetMainFrame()->LoadURL(Wide(url));
    } else {
        b->pending_url = url;
    }
}

extern "C" void cra_browser_go_back(CraBrowser *b) {
    if (b && b->browser) b->browser->GoBack();
}
extern "C" void cra_browser_go_forward(CraBrowser *b) {
    if (b && b->browser) b->browser->GoForward();
}
extern "C" void cra_browser_reload(CraBrowser *b) {
    if (b && b->browser) b->browser->Reload();
}
extern "C" void cra_browser_reload_ignoring_cache(CraBrowser *b) {
    if (b && b->browser) b->browser->ReloadIgnoreCache();
}
extern "C" void cra_browser_stop_loading(CraBrowser *b) {
    if (b && b->browser) b->browser->StopLoad();
}
extern "C" void cra_browser_exit_fullscreen(CraBrowser *b) {
    if (b && b->browser) b->browser->GetHost()->ExitFullscreen(true);
}

extern "C" int cra_browser_is_created(CraBrowser *b) { return b && b->browser ? 1 : 0; }
extern "C" int cra_browser_is_loading(CraBrowser *b) { return b && b->loading ? 1 : 0; }
extern "C" int cra_browser_can_go_back(CraBrowser *b) { return b && b->can_go_back ? 1 : 0; }
extern "C" int cra_browser_can_go_forward(CraBrowser *b) { return b && b->can_go_forward ? 1 : 0; }
extern "C" int cra_browser_closed_by_page(CraBrowser *b) { return b && b->closed_by_page ? 1 : 0; }

extern "C" const char *cra_browser_current_url(CraBrowser *b) {
    if (!b) return "";
    b->returned = b->current_url;
    return b->returned.c_str();
}

extern "C" const char *cra_browser_current_title(CraBrowser *b) {
    if (!b) return "";
    b->returned = b->current_title;
    return b->returned.c_str();
}

extern "C" double cra_browser_zoom_level(CraBrowser *b) {
    return b && b->browser ? b->browser->GetHost()->GetZoomLevel() : 0;
}
extern "C" void cra_browser_set_zoom_level(CraBrowser *b, double level) {
    if (b && b->browser) b->browser->GetHost()->SetZoomLevel(level);
}

extern "C" void cra_browser_find(CraBrowser *b, const char *text, int forward, int match_case, int find_next) {
    if (b && b->browser && text) b->browser->GetHost()->Find(Wide(text), forward != 0, match_case != 0, find_next != 0);
}
extern "C" void cra_browser_stop_finding(CraBrowser *b, int clear_selection) {
    if (b && b->browser) b->browser->GetHost()->StopFinding(clear_selection != 0);
}
extern "C" void cra_browser_set_audio_muted(CraBrowser *b, int muted) {
    if (b && b->browser) b->browser->GetHost()->SetAudioMuted(muted != 0);
}

extern "C" void cra_browser_answer_permission(CraBrowser *b, uint64_t request_id, int allowed) {
    if (!b) return;
    if (auto it = b->prompt_callbacks.find(request_id); it != b->prompt_callbacks.end()) {
        CefRefPtr<CefPermissionPromptCallback> cb = it->second;
        b->prompt_callbacks.erase(it);
        CraClient::answering_prompt_ = true;
        cb->Continue(allowed ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
        CraClient::answering_prompt_ = false;
    } else if (auto m = b->media_callbacks.find(request_id); m != b->media_callbacks.end()) {
        m->second.first->Continue(allowed ? m->second.second : CEF_MEDIA_PERMISSION_NONE);
        b->media_callbacks.erase(m);
    }
}

extern "C" void cra_browser_execute_javascript(CraBrowser *b, const char *script) {
    if (b && b->browser && script) {
        CefRefPtr<CefFrame> frame = b->browser->GetMainFrame();
        frame->ExecuteJavaScript(Wide(script), frame->GetURL(), 0);
    }
}

extern "C" void cra_browser_show_dev_tools(CraBrowser *b) {
    if (!b || !b->browser || b->close_requested) return;
    bool open = b->devtools_browser != nullptr;
    // Opens them through OnBeforeDevToolsPopup, or brings open ones forward.
    b->browser->GetHost()->ShowDevTools(CefWindowInfo(), nullptr, CefBrowserSettings(), CefPoint());
    // Open DevTools take the action now; new ones once their frontend has loaded (Prepare).
    if (open && b->devtools_browser && !b->devtools_browser->IsLoading()) b->RunDevToolsAction();
}
extern "C" void cra_browser_close_dev_tools(CraBrowser *b) {
    if (!b || !b->browser) return;
    b->devtools_relocating = false;
    b->browser->GetHost()->CloseDevTools();
}
extern "C" int cra_browser_has_dev_tools(CraBrowser *b) { return b && b->devtools_browser ? 1 : 0; }
extern "C" void cra_browser_set_dev_tools_action(CraBrowser *b, const char *action) {
    if (b) b->devtools_action = action ? action : "";
}
extern "C" void cra_browser_apply_dev_tools_action(CraBrowser *b) {
    if (b && b->devtools_browser && !b->devtools_browser->IsLoading()) b->RunDevToolsAction();
}
extern "C" void cra_browser_print(CraBrowser *b) {
    if (b && b->browser) b->browser->GetHost()->Print();
}
extern "C" void cra_browser_view_source(CraBrowser *b) {
    if (b && b->browser) b->browser->GetMainFrame()->ViewSource();
}

extern "C" void cra_browser_send_dev_tools_method(CraBrowser *b, const char *method, const char *params, void *context,
                                                  CraDevToolsResult done) {
    auto fail = [&](const char *why) {
        std::string error = std::string("{\"message\":\"") + why + "\"}";
        if (done) done(context, 0, error.c_str(), error.size());
    };
    if (!b || !b->browser || b->close_requested || !method) return fail("no page");
    if (!b->devtools) {
        b->devtools = new DevToolsObserver();
        b->devtools_registration = b->browser->GetHost()->AddDevToolsMessageObserver(b->devtools);
    }
    int id = ++b->next_devtools_id;
    // Method names are plain identifiers ("Domain.method"): nothing to escape.
    std::string message = "{\"id\":" + std::to_string(id) + ",\"method\":\"" + method +
                          "\",\"params\":" + (params && *params ? params : "{}") + "}";
    b->devtools->pending[id] = {context, done};
    if (!b->browser->GetHost()->SendDevToolsMessage(message.data(), message.size())) {
        b->devtools->pending.erase(id);
        fail("SendDevToolsMessage failed");
    }
}

namespace {

/// The page on screen's SSL status, nil before anything has committed.
CefRefPtr<CefSSLStatus> SSLStatus(CraBrowser *b) {
    if (!b || !b->browser) return nullptr;
    CefRefPtr<CefNavigationEntry> entry = b->browser->GetHost()->GetVisibleNavigationEntry();
    return entry ? entry->GetSSLStatus() : nullptr;
}

/// The server's certificate, then its issuers, DER encoded.
std::vector<std::vector<uint8_t>> Certificates(CefRefPtr<CefSSLStatus> ssl) {
    std::vector<std::vector<uint8_t>> out;
    CefRefPtr<CefX509Certificate> cert = ssl ? ssl->GetX509Certificate() : nullptr;
    if (!cert) return out;
    auto add = [&](CefRefPtr<CefBinaryValue> der) {
        if (!der || !der->GetSize()) return;
        std::vector<uint8_t> bytes(der->GetSize());
        der->GetData(bytes.data(), bytes.size(), 0);
        out.push_back(std::move(bytes));
    };
    add(cert->GetDEREncoded());
    CefX509Certificate::IssuerChainBinaryList chain;
    cert->GetDEREncodedIssuerChain(chain);
    for (auto &der : chain) add(der);
    return out;
}

}  // namespace

extern "C" int cra_browser_ssl_status(CraBrowser *b, CraSSLStatus *out) {
    if (!out) return 0;
    *out = CraSSLStatus{};
    CefRefPtr<CefSSLStatus> ssl = SSLStatus(b);
    if (!ssl) return 0;
    out->secure_connection = ssl->IsSecureConnection() ? 1 : 0;
    out->cert_status = static_cast<uint32_t>(ssl->GetCertStatus());
    out->content_status = static_cast<uint32_t>(ssl->GetContentStatus());
    out->has_certificate = ssl->GetX509Certificate() ? 1 : 0;
    return 1;
}

extern "C" int cra_browser_show_certificate(CraBrowser *b, uintptr_t owner) {
    std::vector<std::vector<uint8_t>> ders = Certificates(SSLStatus(b));
    if (ders.empty()) return 0;
    // cryptui.dll's viewer, the one Explorer and Edge show; loaded when first asked for.
    using ViewContext = BOOL(WINAPI *)(DWORD, const void *, HWND, LPCWSTR, DWORD, void *);
    static ViewContext view = [] {
        HMODULE ui = LoadLibraryExW(L"cryptui.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        return ui ? reinterpret_cast<ViewContext>(GetProcAddress(ui, "CryptUIDlgViewContext")) : nullptr;
    }();
    if (!view) return 0;
    // The issuers in the certificate's own store, so the dialog's Certification Path finds them.
    HCERTSTORE store = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, CERT_STORE_CREATE_NEW_FLAG, nullptr);
    if (!store) return 0;
    for (size_t i = 1; i < ders.size(); i++) {
        CertAddEncodedCertificateToStore(store, X509_ASN_ENCODING | PKCS_7_ASN_ENCODING, ders[i].data(),
                                         static_cast<DWORD>(ders[i].size()), CERT_STORE_ADD_ALWAYS, nullptr);
    }
    PCCERT_CONTEXT leaf = nullptr;
    int shown = 0;
    if (CertAddEncodedCertificateToStore(store, X509_ASN_ENCODING | PKCS_7_ASN_ENCODING, ders[0].data(),
                                         static_cast<DWORD>(ders[0].size()), CERT_STORE_ADD_ALWAYS, &leaf) &&
        leaf) {
        const DWORD kCertificateContext = 1;  // CERT_STORE_CERTIFICATE_CONTEXT
        view(kCertificateContext, leaf, reinterpret_cast<HWND>(owner), nullptr, 0, nullptr);
        CertFreeCertificateContext(leaf);
        shown = 1;
    }
    CertCloseStore(store, 0);
    return shown;
}

extern "C" void cra_browser_close(CraBrowser *b) {
    if (!b || !g_browsers.count(b) || b->close_requested) return;
    b->close_requested = true;
    if (b->browser) {
        // DevTools first, as Chrome closes a tab's; they never outlive their page.
        if (b->devtools_browser) b->browser->GetHost()->CloseDevTools();
        b->browser->GetHost()->CloseBrowser(true);  // OnBeforeClose finishes it
    } else if (b->is_popup_host || !g_contextInitialized) {
        b->Finish();  // no page was ever made
    }
    // Otherwise CreateBrowser is in flight: OnAfterCreated closes it.
}

extern "C" void cra_shell_show_in_folder(const char *path) {
    if (!path || !*path) return;
    std::wstring file = Wide(path);
    PIDLIST_ABSOLUTE item = ILCreateFromPathW(file.c_str());
    if (!item) return;
    SHOpenFolderAndSelectItems(item, 0, nullptr, 0);
    ILFree(item);
}
