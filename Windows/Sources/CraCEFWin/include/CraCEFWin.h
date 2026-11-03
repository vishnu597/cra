// CraCEFWin: the C surface Swift uses to drive Chromium (CEF) on Windows, the counterpart of
// Sources/CraCEF/include/CraCEF.h. Each page is a Win32 child window of a top-level HWND.
//
// Everything here runs on the main (UI) thread, as on macOS: CEF's work is pumped from the
// app's own message loop (CefSettings.external_message_pump), so every callback below arrives
// on the main thread too, and a callback may call back into this API.
//
// Strings are UTF-8 and only valid for the duration of the call that passes them.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CraBrowser CraBrowser;

// MARK: - Runtime

typedef struct CraCEFSettings {
    /// CraHelper.exe, which every Chromium subprocess runs.
    const char *helper_path;
    /// The profile folder (root_cache_path and the Default profile's parent).
    const char *cache_root;
    /// chrome_debug.log goes here; NULL leaves CEF's default.
    const char *log_path;
    /// Appended to the user agent ("Cra/1.0"); NULL for none.
    const char *user_agent_product;
} CraCEFSettings;

/// Runs a Chromium subprocess when this process is one (CraHelper.exe calls it first thing);
/// returns its exit code, or -1 in the browser process.
int cra_cef_execute_process(void);

/// 1 when Chromium started. 0 when it did not; then cra_cef_another_instance_was_notified()
/// says whether another Cra already runs on this profile and was handed this launch.
int cra_cef_initialize(const CraCEFSettings *settings);
int cra_cef_another_instance_was_notified(void);

/// Another Cra launch was handed to this one (Chromium's process singleton): the URLs on its
/// command line.
typedef void (*CraRelaunchHandler)(void *context, const char *const *urls, size_t count);
void cra_cef_set_relaunch_handler(void *context, CraRelaunchHandler handler);

/// Closes every browser, pumps until Chromium has let go of them (at most a few seconds) and
/// shuts Chromium down. Call once, when the app quits.
void cra_cef_shutdown(void);
int cra_cef_live_browser_count(void);
/// Static strings, "156.0.8078.80" and "156.0.15+g…".
const char *cra_cef_chromium_version(void);
const char *cra_cef_version(void);

/// An Explorer window on the file's folder with the file selected (Finder's "Show in Finder").
/// Reuses a window already open on that folder, as Explorer's own "Open file location" does.
void cra_shell_show_in_folder(const char *path);

// MARK: - Browser callbacks

typedef enum CraDownloadState {
    CraDownloadStateInProgress = 0,
    CraDownloadStateComplete = 1,
    CraDownloadStateCancelled = 2,
    CraDownloadStateInterrupted = 3,
} CraDownloadState;

typedef struct CraDownloadInfo {
    uint32_t identifier;
    const char *url;
    const char *full_path;
    const char *suggested_name;
    int64_t received_bytes;
    int64_t total_bytes;
    int percent;
    CraDownloadState state;
} CraDownloadInfo;

/// Modifier bits of CraKeyEvent, the same values as CEF's cef_event_flags_t.
enum {
    CraKeyModifierShift = 1 << 1,
    CraKeyModifierControl = 1 << 2,
    CraKeyModifierAlt = 1 << 3,
};

/// A key press (raw key down) on a page.
typedef struct CraKeyEvent {
    /// The Windows virtual-key code (VK_*; 'A'..'Z' and '0'..'9' are their ASCII values).
    int key_code;
    uint32_t modifiers;
    /// Repeated by holding the key down.
    int is_repeat;
} CraKeyEvent;

/// Permission kinds, a bitmask as on macOS.
enum {
    CraPermissionCamera = 1,
    CraPermissionMicrophone = 2,
    CraPermissionLocation = 4,
    CraPermissionNotifications = 8,
    CraPermissionOther = 16,
};

/// Every member may be NULL. `context` is passed back to each.
typedef struct CraBrowserCallbacks {
    void *context;
    void (*title_changed)(void *context, const char *title);
    void (*address_changed)(void *context, const char *url);
    void (*loading_changed)(void *context, int loading, int can_go_back, int can_go_forward);
    void (*progress_changed)(void *context, double progress);
    void (*load_finished)(void *context, const char *url, int status_code);
    /// The page's favicon as PNG bytes (up to 64 px, at 2x when the site has it).
    void (*favicon_loaded)(void *context, const char *icon_url, const uint8_t *png, size_t length);
    void (*status_message_changed)(void *context, const char *message);
    /// The page's theme colour as "#RRGGBB", "none", or "" when unknown.
    void (*theme_color_reported)(void *context, const char *hex);
    /// The colour the page paints behind its content as "#RRGGBB"; "" when a new page starts.
    void (*background_color_reported)(void *context, const char *hex);
    void (*fullscreen_changed)(void *context, int fullscreen);
    /// Ctrl-click, middle-click and similar: open a plain new tab.
    void (*new_tab_requested)(void *context, const char *url, int background);
    /// window.open / target=_blank: return a popup host (a browser made with a NULL url) so
    /// the popup keeps its opener, or NULL to block it.
    CraBrowser *(*popup_host_requested)(void *context, const char *url, int background);
    /// Reserved shortcuts, before the page sees the key. Return nonzero to consume it.
    int (*key_event)(void *context, const CraKeyEvent *event);
    /// Keys the page did not handle. Return nonzero to consume it.
    int (*unhandled_key_event)(void *context, const CraKeyEvent *event);
    void (*download_updated)(void *context, const CraDownloadInfo *download);
    /// Ask the user, then answer with cra_browser_answer_permission(request_id).
    void (*permission_requested)(void *context, uint64_t request_id, const char *origin, uint32_t kinds);
    /// Find in page: `count` matches, `active_match` (1-based) is highlighted; -1 when unchanged.
    void (*find_result)(void *context, int count, int active_match);
    void (*media_capture_changed)(void *context, int capturing);
    void (*focus_received)(void *context);
    /// Chromium is done with the page; the CraBrowser is freed after this returns.
    void (*closed)(void *context);
} CraBrowserCallbacks;

// MARK: - Browser

/// A page as a child window of `parent` (an HWND) at `x, y, width, height` (physical pixels,
/// relative to the parent's client area). A NULL `url` makes a popup host that adopts the
/// popup returned for it from popup_host_requested.
CraBrowser *cra_browser_create(uintptr_t parent, int x, int y, int width, int height, const char *url,
                               CraBrowserCallbacks callbacks);
void cra_browser_set_frame(CraBrowser *browser, int x, int y, int width, int height);
/// Shows or hides the page (a background tab is hidden; Chromium also throttles it).
void cra_browser_set_visible(CraBrowser *browser, int visible);
void cra_browser_set_focused(CraBrowser *browser, int focused);

void cra_browser_load_url(CraBrowser *browser, const char *url);
void cra_browser_go_back(CraBrowser *browser);
void cra_browser_go_forward(CraBrowser *browser);
void cra_browser_reload(CraBrowser *browser);
void cra_browser_reload_ignoring_cache(CraBrowser *browser);
void cra_browser_stop_loading(CraBrowser *browser);
void cra_browser_exit_fullscreen(CraBrowser *browser);

int cra_browser_is_created(CraBrowser *browser);
int cra_browser_is_loading(CraBrowser *browser);
int cra_browser_can_go_back(CraBrowser *browser);
int cra_browser_can_go_forward(CraBrowser *browser);
/// UTF-8, valid until the next call into this browser.
const char *cra_browser_current_url(CraBrowser *browser);
const char *cra_browser_current_title(CraBrowser *browser);
/// The page closed itself (window.close()) rather than through cra_browser_close.
int cra_browser_closed_by_page(CraBrowser *browser);

double cra_browser_zoom_level(CraBrowser *browser);
void cra_browser_set_zoom_level(CraBrowser *browser, double level);
void cra_browser_find(CraBrowser *browser, const char *text, int forward, int match_case, int find_next);
void cra_browser_stop_finding(CraBrowser *browser, int clear_selection);
void cra_browser_set_audio_muted(CraBrowser *browser, int muted);
void cra_browser_answer_permission(CraBrowser *browser, uint64_t request_id, int allowed);
void cra_browser_execute_javascript(CraBrowser *browser, const char *script);
void cra_browser_show_dev_tools(CraBrowser *browser);
void cra_browser_close_dev_tools(CraBrowser *browser);
void cra_browser_print(CraBrowser *browser);
void cra_browser_view_source(CraBrowser *browser);

/// Asynchronous: `closed` fires once Chromium is done, and is the only callback that still
/// fires after this call. The browser must not be used once `closed` has fired.
void cra_browser_close(CraBrowser *browser);

#ifdef __cplusplus
}
#endif
