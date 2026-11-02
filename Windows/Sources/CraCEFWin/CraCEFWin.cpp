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

const char kBackgroundProbe[] =
    "(function(){if(!window.__craBg){var color=" CRA_PAGE_BACKGROUND_FN ";"
    "window.__craBg=function(){try{var c=color();if(c)console.log('__cra_bg:'+c);}catch(e){}};"
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
    "var rgb=getComputedStyle(d).color;d.remove();console.log('__cra_theme:'+rgb);}catch(e){}}"
    "probe();setTimeout(probe,1500);})();";

/// Settings for every page Cra makes. Cra draws its own status bubble.
void CraPageSettings(CefBrowserSettings &settings) { settings.chrome_status_bubble = STATE_DISABLED; }

std::wstring DownloadsFolder() {
    PWSTR path = nullptr;
    std::wstring out;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Downloads, 0, nullptr, &path)) && path) out = path;
    if (path) CoTaskMemFree(path);
    return out;
}

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

bool g_contextInitialized = false;
bool g_anotherInstanceNotified = false;
void *g_relaunchContext = nullptr;
CraRelaunchHandler g_relaunchHandler = nullptr;
std::set<CraBrowser *> g_browsers;
std::vector<CraBrowser *> g_pendingCreation;

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

    void ApplyFrame() {
        if (!browser) return;
        HWND hwnd = browser->GetHost()->GetWindowHandle();
        if (!hwnd) return;
        // Above WinUI's content bridge window, which covers the whole client area.
        SetWindowPos(hwnd, HWND_TOP, frame.x, frame.y, frame.width, frame.height,
                     SWP_NOACTIVATE | (visible ? SWP_SHOWWINDOW : SWP_HIDEWINDOW));
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
                  public CefFindHandler {
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
            return true;  // keep it out of the console
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
        CraKeyEvent e = KeyEvent(event, os_event);
        return o->callbacks.key_event(o->callbacks.context, &e) != 0;
    }

    bool OnKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent &event, CefEventHandle os_event) override {
        CraBrowser *o = Live();
        if (!o || event.type != KEYEVENT_RAWKEYDOWN || !o->callbacks.unhandled_key_event) return false;
        CraKeyEvent e = KeyEvent(event, os_event);
        return o->callbacks.unhandled_key_event(o->callbacks.context, &e) != 0;
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
        uint32_t kinds = 0;
        if (requested_permissions & (CEF_PERMISSION_TYPE_CAMERA_STREAM | CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM))
            kinds |= CraPermissionCamera;
        if (requested_permissions & CEF_PERMISSION_TYPE_MIC_STREAM) kinds |= CraPermissionMicrophone;
        if (requested_permissions & CEF_PERMISSION_TYPE_GEOLOCATION) kinds |= CraPermissionLocation;
        if (requested_permissions & CEF_PERMISSION_TYPE_NOTIFICATIONS) kinds |= CraPermissionNotifications;
        if (kinds == 0) kinds = CraPermissionOther;
        uint64_t id = o->next_permission_id++;
        o->prompt_callbacks[id] = callback;
        o->callbacks.permission_requested(o->callbacks.context, id, requesting_origin.ToString().c_str(), kinds);
        return true;
    }

    // Find ----------------------------------------------------------------

    void OnFindResult(CefRefPtr<CefBrowser> browser, int identifier, int count, const CefRect &selectionRect,
                      int activeMatchOrdinal, bool finalUpdate) override {
        CraBrowser *o = Live();
        if (o && o->callbacks.find_result) o->callbacks.find_result(o->callbacks.context, count, activeMatchOrdinal);
    }

private:
    /// The owner, unless it asked to close: then only `closed` still fires.
    CraBrowser *Live() const { return owner_ && !owner_->close_requested ? owner_ : nullptr; }

    static CraKeyEvent KeyEvent(const CefKeyEvent &event, CefEventHandle os_event) {
        CraKeyEvent e{};
        e.key_code = event.windows_key_code;
        e.modifiers = event.modifiers & (EVENTFLAG_SHIFT_DOWN | EVENTFLAG_CONTROL_DOWN | EVENTFLAG_ALT_DOWN);
        // Bit 30 of a WM_KEYDOWN's lParam: the key was already down.
        if (os_event) e.is_repeat = (os_event->lParam & (1 << 30)) ? 1 : 0;
        return e;
    }

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
                                  nullptr);
}

/// Chromium is done with the page (or never had one): tell Swift, then free it.
void CraBrowser::Finish() {
    if (!g_browsers.erase(this)) return;
    std::erase(g_pendingCreation, this);
    client->Detach();
    for (auto &[id, cb] : prompt_callbacks) cb->Continue(CEF_PERMISSION_RESULT_DISMISS);
    for (auto &[id, pair] : media_callbacks) pair.first->Cancel();
    prompt_callbacks.clear();
    media_callbacks.clear();
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
    while (!g_browsers.empty() && GetTickCount64() < deadline) {
        CefDoMessageLoopWork();
        MSG msg;
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Sleep(10);
    }
    KillPumpTimer();
    if (g_pumpWindow) DestroyWindow(g_pumpWindow);
    g_pumpWindow = nullptr;
    CefShutdown();
}

extern "C" int cra_cef_live_browser_count(void) { return static_cast<int>(g_browsers.size()); }

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
    auto *b = new CraBrowser;
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
        it->second->Continue(allowed ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
        b->prompt_callbacks.erase(it);
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
    // In Chromium's own window for now; docking in the content card comes with phase 2.
    if (b && b->browser) b->browser->GetHost()->ShowDevTools(CefWindowInfo(), nullptr, CefBrowserSettings(), CefPoint());
}
extern "C" void cra_browser_close_dev_tools(CraBrowser *b) {
    if (b && b->browser) b->browser->GetHost()->CloseDevTools();
}
extern "C" void cra_browser_print(CraBrowser *b) {
    if (b && b->browser) b->browser->GetHost()->Print();
}
extern "C" void cra_browser_view_source(CraBrowser *b) {
    if (b && b->browser) b->browser->GetMainFrame()->ViewSource();
}

extern "C" void cra_browser_close(CraBrowser *b) {
    if (!b || !g_browsers.count(b) || b->close_requested) return;
    b->close_requested = true;
    if (b->browser) {
        b->browser->GetHost()->CloseBrowser(true);  // OnBeforeClose finishes it
    } else if (b->is_popup_host || !g_contextInitialized) {
        b->Finish();  // no page was ever made
    }
    // Otherwise CreateBrowser is in flight: OnAfterCreated closes it.
}
