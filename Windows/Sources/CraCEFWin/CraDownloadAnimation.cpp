// Chrome's download-started animation, hidden: the Windows counterpart of the Mac's
// ChromeDownloadAnimation (Sources/Cra/UI/Windows/ChromeDownloadAnimation.swift).
//
// When a download begins Chrome shows a 64 DIP round download glyph that fades in over the
// page and flies to the toolbar's download button (DownloadBubbleStartedAnimationViews,
// 500 ms). Cra keeps Chrome's toolbar hidden, so the glyph flies to nothing at the page's top
// left, and the downloads button in the sidebar shows the progress instead. Chrome has no
// switch for it, so its window is hidden as it is shown. That window is a views popup
// (download_started_animation_views.cc: TYPE_POPUP, accept_events = false, translucent),
// which on Windows is a Chrome_WidgetWin_ window with WS_POPUP, WS_EX_TOOLWINDOW and
// WS_EX_TRANSPARENT (widget_hwnd_utils.cc). It is shown before it is first sized, so it is
// checked again as it moves; the watch only runs for the two seconds after a download starts.
#include "CraCEFWin.h"

#include <windows.h>

#include <cwchar>

namespace {

/// Chrome posts the animation once the toolbar's download button has animated in.
const UINT kWatchMilliseconds = 2000;

HWINEVENTHOOK g_hook = nullptr;
UINT_PTR g_timer = 0;

bool IsAnimationWindow(HWND hwnd) {
    wchar_t name[32] = {};
    if (GetClassNameW(hwnd, name, 32) < 17 || wcsncmp(name, L"Chrome_WidgetWin_", 17) != 0) return false;
    LONG style = GetWindowLongW(hwnd, GWL_STYLE), ex = GetWindowLongW(hwnd, GWL_EXSTYLE);
    if (!(style & WS_POPUP) || (style & WS_CHILD)) return false;
    if ((ex & (WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW)) != (WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW)) return false;
    // Over one of this app's windows (its owner is the page's top-level window).
    HWND owner = GetWindow(hwnd, GW_OWNER);
    DWORD process = 0;
    if (!owner || !GetWindowThreadProcessId(owner, &process) || process != GetCurrentProcessId()) return false;
    // At most the glyph's 64 DIP, with room for rounding: never a page-sized popup.
    RECT r = {};
    GetWindowRect(hwnd, &r);
    UINT dpi = GetDpiForWindow(hwnd);
    LONG most = LONG(80 * (dpi ? dpi : 96) / 96);
    return r.right - r.left <= most && r.bottom - r.top <= most;
}

void CALLBACK OnEvent(HWINEVENTHOOK, DWORD event, HWND hwnd, LONG object, LONG child, DWORD, DWORD) {
    if (event != EVENT_OBJECT_SHOW && event != EVENT_OBJECT_LOCATIONCHANGE) return;
    if (object != OBJID_WINDOW || child != CHILDID_SELF || !hwnd || !IsWindowVisible(hwnd)) return;
    if (IsAnimationWindow(hwnd)) ShowWindow(hwnd, SW_HIDE);
}

void CALLBACK EndWatch(HWND, UINT, UINT_PTR, DWORD) {
    if (g_timer) KillTimer(nullptr, g_timer);
    g_timer = 0;
    if (g_hook) UnhookWinEvent(g_hook);
    g_hook = nullptr;
}

}  // namespace

extern "C" void cra_hide_download_started_animation(void) {
    if (!g_hook) {
        // Out of context: the events come through this thread's message loop.
        // Shown (EVENT_OBJECT_SHOW) through moved or sized (EVENT_OBJECT_LOCATIONCHANGE).
        g_hook = SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_LOCATIONCHANGE, nullptr, OnEvent, GetCurrentProcessId(),
                                 0, WINEVENT_OUTOFCONTEXT);
    }
    // A thread timer: another download in the watch pushes its end back.
    if (g_timer) KillTimer(nullptr, g_timer);
    g_timer = SetTimer(nullptr, 0, kWatchMilliseconds, EndWatch);
}
