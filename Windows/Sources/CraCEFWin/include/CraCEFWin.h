// CraCEFWin: the C surface Swift uses to drive Chromium (CEF) on Windows, the counterpart
// of Sources/CraCEF/include/CraCEF.h. Plain C so Swift imports it without C++ interop.
//
// CEF runs its own UI thread (multi_threaded_message_loop), so these calls return before
// Chromium has acted on them; callbacks arrive on CEF's UI thread.
#ifndef CRA_CEF_WIN_H
#define CRA_CEF_WIN_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CraBrowser CraBrowser;

/// Called when a browser's title or address changes. `value` is UTF-8 and only valid during
/// the call. `context` is what was passed to cra_browser_create.
typedef void (*CraBrowserStringCallback)(void *context, const char *value);

typedef struct CraBrowserCallbacks {
    void *context;
    CraBrowserStringCallback title_changed;
    CraBrowserStringCallback address_changed;
} CraBrowserCallbacks;

/// The whole of a Chromium subprocess (CraHelper.exe): runs it and returns its exit code.
int cra_cef_execute_process(void);

/// Starts Chromium. `helper_path` is CraHelper.exe, `cache_root` the folder profiles live in
/// (both UTF-8). Returns 0 when Chromium did not start.
int cra_cef_initialize(const char *helper_path, const char *cache_root);

/// Closes every browser and stops Chromium. Call once, on the thread that initialized it.
void cra_cef_shutdown(void);

/// A page as a child window of `parent` (an HWND) at the given rectangle in physical pixels.
CraBrowser *cra_browser_create(uintptr_t parent, int x, int y, int width, int height,
                               const char *url, CraBrowserCallbacks callbacks);

/// Moves and sizes the page's window, in physical pixels relative to its parent.
void cra_browser_set_frame(CraBrowser *browser, int x, int y, int width, int height);

void cra_browser_load_url(CraBrowser *browser, const char *url);
void cra_browser_go_back(CraBrowser *browser);
void cra_browser_go_forward(CraBrowser *browser);
void cra_browser_reload(CraBrowser *browser);

/// Closes the page and frees `browser`.
void cra_browser_close(CraBrowser *browser);

#ifdef __cplusplus
}
#endif

#endif
