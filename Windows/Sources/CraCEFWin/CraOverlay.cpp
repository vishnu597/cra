// The Peek's windows that aren't XAML or a page (CraCEFWin.h, MARK: Overlays): the veil that
// fades the browser window's page and catches the click that closes the Peek, and the column of
// round buttons beside the card. Plain Win32 and GDI+; nothing here touches CEF. Main thread.
#include "CraCEFWin.h"

#include <windows.h>
#include <objidl.h>

#include <algorithm>
// GDI+'s headers use min and max, which NOMINMAX takes away.
namespace Gdiplus {
using std::max;
using std::min;
}  // namespace Gdiplus
#include <gdiplus.h>

#include <cmath>
#include <string>
#include <vector>

namespace {

std::wstring Wide(const char *utf8) {
    if (!utf8 || !*utf8) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
    std::wstring out(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out.data(), n);
    return out;
}

HINSTANCE Instance() { return GetModuleHandleW(nullptr); }

// MARK: Veil

struct Veil {
    COLORREF color;
    void *context;
    CraOverlayClicked clicked;
};

Veil *VeilOf(HWND hwnd) { return reinterpret_cast<Veil *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA)); }

LRESULT CALLBACK VeilProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_NCCREATE: {
        auto *create = reinterpret_cast<CREATESTRUCTW *>(lParam);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
        break;
    }
    case WM_MOUSEACTIVATE:
        // The click closes the Peek; the browser window comes to the front then, not before.
        return MA_NOACTIVATE;
    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
    case WM_MBUTTONDOWN:
        if (Veil *v = VeilOf(hwnd); v && v->clicked) v->clicked(v->context);
        return 0;
    case WM_SETCURSOR:
        SetCursor(LoadCursorW(nullptr, IDC_ARROW));
        return TRUE;
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        if (Veil *v = VeilOf(hwnd)) {
            HBRUSH brush = CreateSolidBrush(v->color);
            FillRect(dc, &ps.rcPaint, brush);
            DeleteObject(brush);
        }
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_NCDESTROY:
        delete VeilOf(hwnd);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        break;
    }
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

const wchar_t *kVeilClass = L"CraPeekVeil";
const wchar_t *kButtonsClass = L"CraPeekButtons";
const wchar_t *kTipClass = L"CraPeekTip";

void RegisterClasses() {
    static bool done = false;
    if (done) return;
    done = true;
    WNDCLASSEXW veil{sizeof(veil)};
    veil.lpfnWndProc = VeilProc;
    veil.hInstance = Instance();
    veil.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    veil.lpszClassName = kVeilClass;
    RegisterClassExW(&veil);
}

// MARK: Buttons

struct Buttons {
    std::vector<std::wstring> glyphs;
    std::vector<std::wstring> tips;
    std::vector<RECT> rects;  // in the window, physical pixels
    void *context = nullptr;
    CraButtonClicked clicked = nullptr;
    uint32_t fill = 0, ink = 0xFFFFFF;
    double scale = 1;
    int pressed = -1;
    HWND tooltip = nullptr;
    int hover = -1;   // the button under the pointer
    int shown = -1;   // the button whose tip shows
    bool tracking = false;  // TrackMouseEvent asked for WM_MOUSELEAVE
};

constexpr UINT_PTR kTipTimer = 1;
constexpr UINT kTipDelay = 450;  // ms, about Windows' own initial tooltip delay

Buttons *ButtonsOf(HWND hwnd) { return reinterpret_cast<Buttons *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA)); }

ULONG_PTR GdiplusToken() {
    static ULONG_PTR token = 0;
    if (!token) {
        Gdiplus::GdiplusStartupInput input;
        Gdiplus::GdiplusStartup(&token, &input, nullptr);
    }
    return token;
}

/// The button under a client point, or -1: a circle in its rect.
int ButtonAt(const Buttons &b, int x, int y) {
    for (size_t i = 0; i < b.rects.size(); ++i) {
        const RECT &r = b.rects[i];
        double cx = (r.left + r.right) / 2.0, cy = (r.top + r.bottom) / 2.0;
        double radius = std::min(r.right - r.left, r.bottom - r.top) / 2.0;
        if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius) return static_cast<int>(i);
    }
    return -1;
}

Gdiplus::Color ColorOf(uint32_t rgb, BYTE alpha) {
    return Gdiplus::Color(alpha, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
}

/// The buttons drawn on a transparent layer, given to the window with UpdateLayeredWindow:
/// GDI+'s antialiased circles with a soft shadow under each, and the glyph in Segoe Fluent Icons.
void Draw(HWND hwnd) {
    Buttons *b = ButtonsOf(hwnd);
    RECT frame{};
    if (!b || !GetWindowRect(hwnd, &frame)) return;
    int w = frame.right - frame.left, h = frame.bottom - frame.top;
    if (w <= 0 || h <= 0) return;
    GdiplusToken();
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = w;
    info.bmiHeader.biHeight = -h;  // top-down
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void *bits = nullptr;
    HDC screen = GetDC(nullptr);
    HDC memory = CreateCompatibleDC(screen);
    HBITMAP dib = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (!dib || !bits) {
        if (dib) DeleteObject(dib);
        DeleteDC(memory);
        ReleaseDC(nullptr, screen);
        return;
    }
    HGDIOBJ old = SelectObject(memory, dib);
    {
        Gdiplus::Bitmap canvas(w, h, w * 4, PixelFormat32bppPARGB, static_cast<BYTE *>(bits));
        Gdiplus::Graphics g(&canvas);
        g.Clear(Gdiplus::Color(0, 0, 0, 0));
        g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
        g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
        Gdiplus::FontFamily fluent(L"Segoe Fluent Icons");
        Gdiplus::FontFamily mdl2(L"Segoe MDL2 Assets");
        const Gdiplus::FontFamily *family = fluent.GetLastStatus() == Gdiplus::Ok ? &fluent : &mdl2;
        Gdiplus::Font font(family, static_cast<Gdiplus::REAL>(15 * b->scale), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
        Gdiplus::StringFormat centred;
        centred.SetAlignment(Gdiplus::StringAlignmentCenter);
        centred.SetLineAlignment(Gdiplus::StringAlignmentCenter);
        for (size_t i = 0; i < b->rects.size(); ++i) {
            const RECT &r = b->rects[i];
            auto x = static_cast<Gdiplus::REAL>(r.left), y = static_cast<Gdiplus::REAL>(r.top);
            auto bw = static_cast<Gdiplus::REAL>(r.right - r.left), bh = static_cast<Gdiplus::REAL>(r.bottom - r.top);
            // The Mac's layer shadow: black at 25 %, 4 pt soft, 1 pt down.
            auto blur = static_cast<Gdiplus::REAL>(4 * b->scale), drop = static_cast<Gdiplus::REAL>(1 * b->scale);
            Gdiplus::GraphicsPath shadowPath;
            shadowPath.AddEllipse(x - blur, y - blur + drop, bw + 2 * blur, bh + 2 * blur);
            Gdiplus::PathGradientBrush shadow(&shadowPath);
            shadow.SetCenterColor(Gdiplus::Color(64, 0, 0, 0));
            Gdiplus::Color edge(0, 0, 0, 0);
            int edges = 1;
            shadow.SetSurroundColors(&edge, &edges);
            Gdiplus::REAL inner = bw / (bw + 2 * blur);
            shadow.SetFocusScales(inner * 0.85f, inner * 0.85f);
            g.FillPath(&shadow, &shadowPath);
            // Pressed: the button at 80 %, as the Mac's alphaValue.
            BYTE alpha = static_cast<int>(i) == b->pressed ? 204 : 255;
            Gdiplus::SolidBrush disc(ColorOf(b->fill, alpha));
            g.FillEllipse(&disc, x, y, bw, bh);
            if (i < b->glyphs.size()) {
                Gdiplus::SolidBrush glyph(ColorOf(b->ink, alpha));
                Gdiplus::RectF box(x, y, bw, bh);
                g.DrawString(b->glyphs[i].c_str(), -1, &font, box, &centred, &glyph);
            }
        }
    }
    POINT origin{frame.left, frame.top}, zero{0, 0};
    SIZE size{w, h};
    BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    UpdateLayeredWindow(hwnd, screen, &origin, &size, memory, &zero, 0, &blend, ULW_ALPHA);
    SelectObject(memory, old);
    DeleteObject(dib);
    DeleteDC(memory);
    ReleaseDC(nullptr, screen);
}

/// Windows 11's own tooltip colours for the apps' theme (light unless the user picked dark).
bool AppsUseDarkTheme() {
    DWORD light = 1, size = sizeof(light);
    return RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", L"AppsUseLightTheme",
                        RRF_RT_REG_DWORD, nullptr, &light, &size) == ERROR_SUCCESS &&
           light == 0;
}

void HideTip(HWND hwnd, Buttons *b) {
    KillTimer(hwnd, kTipTimer);
    if (b->tooltip && b->shown >= 0) ShowWindow(b->tooltip, SW_HIDE);
    b->shown = -1;
}

/// The hovered button's tip, below the pointer as Windows puts its own and kept on the monitor:
/// drawn here in a layered window of Cra's, in Windows 11's tooltip look. Neither of comctl32
/// 5.82's ways worked over these windows: its subclassing never saw the hover, and its tracking
/// tips crashed inside comctl32 on the PC.
void ShowTip(HWND hwnd, Buttons *b) {
    if (!b->tooltip || b->hover < 0 || b->hover >= static_cast<int>(b->tips.size()) || b->tips[b->hover].empty()) return;
    const std::wstring &text = b->tips[b->hover];
    GdiplusToken();
    double scale = b->scale;
    Gdiplus::Font font(L"Segoe UI", static_cast<Gdiplus::REAL>(12 * scale), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::RectF measured;
    {
        HDC screen = GetDC(nullptr);
        Gdiplus::Graphics measure(screen);
        measure.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
        measure.MeasureString(text.c_str(), -1, &font, Gdiplus::PointF(0, 0), &measured);
        ReleaseDC(nullptr, screen);
    }
    int padX = static_cast<int>(std::lround(8 * scale)), padY = static_cast<int>(std::lround(5 * scale));
    int w = static_cast<int>(std::ceil(measured.Width)) + 2 * padX, h = static_cast<int>(std::ceil(measured.Height)) + 2 * padY;
    POINT pointer{};
    GetCursorPos(&pointer);
    int x = pointer.x, y = pointer.y + GetSystemMetrics(SM_CYCURSOR) * 3 / 4;
    MONITORINFO monitor{sizeof(monitor)};
    if (GetMonitorInfoW(MonitorFromPoint(pointer, MONITOR_DEFAULTTONEAREST), &monitor)) {
        const RECT &work = monitor.rcWork;
        x = std::max<int>(work.left, std::min<int>(x, work.right - w));
        if (y + h > work.bottom) y = pointer.y - h - 4;
    }
    bool dark = AppsUseDarkTheme();
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = w;
    info.bmiHeader.biHeight = -h;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void *bits = nullptr;
    HDC screen = GetDC(nullptr);
    HDC memory = CreateCompatibleDC(screen);
    HBITMAP dib = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (dib && bits) {
        HGDIOBJ old = SelectObject(memory, dib);
        {
            Gdiplus::Bitmap canvas(w, h, w * 4, PixelFormat32bppPARGB, static_cast<BYTE *>(bits));
            Gdiplus::Graphics g(&canvas);
            g.Clear(Gdiplus::Color(0, 0, 0, 0));
            g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
            g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
            auto radius = static_cast<Gdiplus::REAL>(4 * scale), inset = 0.5f;
            auto right = static_cast<Gdiplus::REAL>(w) - inset, bottom = static_cast<Gdiplus::REAL>(h) - inset;
            Gdiplus::GraphicsPath shape;
            shape.AddArc(inset, inset, 2 * radius, 2 * radius, 180, 90);
            shape.AddArc(right - 2 * radius, inset, 2 * radius, 2 * radius, 270, 90);
            shape.AddArc(right - 2 * radius, bottom - 2 * radius, 2 * radius, 2 * radius, 0, 90);
            shape.AddArc(inset, bottom - 2 * radius, 2 * radius, 2 * radius, 90, 90);
            shape.CloseFigure();
            Gdiplus::SolidBrush fill(dark ? Gdiplus::Color(255, 0x2C, 0x2C, 0x2C) : Gdiplus::Color(255, 0xF9, 0xF9, 0xF9));
            Gdiplus::Pen edge(dark ? Gdiplus::Color(255, 0x45, 0x45, 0x45) : Gdiplus::Color(255, 0xD9, 0xD9, 0xD9), 1);
            g.FillPath(&fill, &shape);
            g.DrawPath(&edge, &shape);
            Gdiplus::SolidBrush ink(dark ? Gdiplus::Color(255, 0xFF, 0xFF, 0xFF) : Gdiplus::Color(255, 0x1A, 0x1A, 0x1A));
            g.DrawString(text.c_str(), -1, &font, Gdiplus::PointF(static_cast<Gdiplus::REAL>(padX), static_cast<Gdiplus::REAL>(padY)), &ink);
        }
        POINT origin{x, y}, zero{0, 0};
        SIZE size{w, h};
        BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
        UpdateLayeredWindow(b->tooltip, screen, &origin, &size, memory, &zero, 0, &blend, ULW_ALPHA);
        SelectObject(memory, old);
        SetWindowPos(b->tooltip, HWND_TOPMOST, x, y, w, h, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        b->shown = b->hover;
    }
    if (dib) DeleteObject(dib);
    DeleteDC(memory);
    ReleaseDC(nullptr, screen);
}

/// The tip's window: shown, never clicked or focused.
LRESULT CALLBACK TipProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_NCHITTEST:
        return HTTRANSPARENT;
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    }
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

LRESULT CALLBACK ButtonsProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    Buttons *b = ButtonsOf(hwnd);
    switch (message) {
    case WM_NCCREATE: {
        auto *create = reinterpret_cast<CREATESTRUCTW *>(lParam);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
        break;
    }
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    case WM_SETCURSOR:
        SetCursor(LoadCursorW(nullptr, IDC_ARROW));
        return TRUE;
    case WM_MOUSEMOVE:
        if (b) {
            if (!b->tracking) {
                TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE, hwnd, 0};
                b->tracking = TrackMouseEvent(&track) != FALSE;
            }
            int at = ButtonAt(*b, static_cast<short>(LOWORD(lParam)), static_cast<short>(HIWORD(lParam)));
            if (at != b->hover) {
                HideTip(hwnd, b);
                b->hover = at;
                if (at >= 0 && b->pressed < 0) SetTimer(hwnd, kTipTimer, kTipDelay, nullptr);
            }
        }
        return 0;
    case WM_MOUSELEAVE:
        if (b) {
            b->tracking = false;
            b->hover = -1;
            HideTip(hwnd, b);
        }
        return 0;
    case WM_TIMER:
        if (wParam == kTipTimer) {
            KillTimer(hwnd, kTipTimer);
            if (b && b->pressed < 0) ShowTip(hwnd, b);
            return 0;
        }
        break;
    case WM_LBUTTONDOWN:
        if (b) {
            HideTip(hwnd, b);
            b->pressed = ButtonAt(*b, static_cast<short>(LOWORD(lParam)), static_cast<short>(HIWORD(lParam)));
            if (b->pressed >= 0) {
                SetCapture(hwnd);
                Draw(hwnd);
            }
        }
        return 0;
    case WM_LBUTTONUP:
        if (b && b->pressed >= 0) {
            int was = b->pressed;
            b->pressed = -1;
            ReleaseCapture();
            Draw(hwnd);
            if (ButtonAt(*b, static_cast<short>(LOWORD(lParam)), static_cast<short>(HIWORD(lParam))) == was && b->clicked)
                b->clicked(b->context, was);  // last: it may destroy this window
        }
        return 0;
    case WM_CAPTURECHANGED:
        if (b && b->pressed >= 0) {
            b->pressed = -1;
            Draw(hwnd);
        }
        return 0;
    case WM_NCDESTROY:
        KillTimer(hwnd, kTipTimer);  // the tip, an owned window, has already gone
        delete b;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        break;
    }
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

void RegisterButtonsClass() {
    static bool done = false;
    if (done) return;
    done = true;
    WNDCLASSEXW buttons{sizeof(buttons)};
    buttons.lpfnWndProc = ButtonsProc;
    buttons.hInstance = Instance();
    buttons.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    buttons.lpszClassName = kButtonsClass;
    RegisterClassExW(&buttons);
    WNDCLASSEXW tip{sizeof(tip)};
    tip.lpfnWndProc = TipProc;
    tip.hInstance = Instance();
    tip.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    tip.lpszClassName = kTipClass;
    RegisterClassExW(&tip);
}

HWND InsertAfter(uintptr_t after) { return after ? reinterpret_cast<HWND>(after) : HWND_TOP; }

}  // namespace

uintptr_t cra_overlay_create(uintptr_t owner, uint32_t rgb, int alpha, void *context, CraOverlayClicked clicked) {
    RegisterClasses();
    auto *v = new Veil{RGB((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF), context, clicked};
    HWND hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kVeilClass, L"", WS_POPUP, 0, 0, 0, 0,
                                reinterpret_cast<HWND>(owner), nullptr, Instance(), v);
    if (!hwnd) {
        delete v;
        return 0;
    }
    SetLayeredWindowAttributes(hwnd, 0, static_cast<BYTE>(std::clamp(alpha, 1, 255)), LWA_ALPHA);
    return reinterpret_cast<uintptr_t>(hwnd);
}

void cra_overlay_set_alpha(uintptr_t overlay, int alpha) {
    // Never 0: a layered window at 0 lets clicks through, and the veil is what catches them.
    if (overlay) SetLayeredWindowAttributes(reinterpret_cast<HWND>(overlay), 0, static_cast<BYTE>(std::clamp(alpha, 1, 255)), LWA_ALPHA);
}

void cra_overlay_place(uintptr_t overlay, int x, int y, int width, int height, uintptr_t insert_after) {
    if (!overlay) return;
    SetWindowPos(reinterpret_cast<HWND>(overlay), InsertAfter(insert_after), x, y, std::max(width, 1), std::max(height, 1),
                 SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOOWNERZORDER);
}

void cra_overlay_destroy(uintptr_t overlay) {
    if (overlay) DestroyWindow(reinterpret_cast<HWND>(overlay));
}

uintptr_t cra_round_buttons_create(uintptr_t owner, const char *const *glyphs, const char *const *tips, size_t count, void *context,
                                   CraButtonClicked clicked) {
    RegisterButtonsClass();
    auto *b = new Buttons;
    for (size_t i = 0; i < count; ++i) {
        b->glyphs.push_back(Wide(glyphs ? glyphs[i] : nullptr));
        b->tips.push_back(Wide(tips ? tips[i] : nullptr));
    }
    b->context = context;
    b->clicked = clicked;
    HWND hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kButtonsClass, L"", WS_POPUP, 0, 0, 0, 0,
                                reinterpret_cast<HWND>(owner), nullptr, Instance(), b);
    if (!hwnd) {
        delete b;
        return 0;
    }
    // Owned by the buttons, so it goes with them; topmost, as Windows' own tips.
    b->tooltip = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST | WS_EX_TRANSPARENT, kTipClass, L"",
                                 WS_POPUP, 0, 0, 0, 0, hwnd, nullptr, Instance(), nullptr);
    return reinterpret_cast<uintptr_t>(hwnd);
}

void cra_round_buttons_place(uintptr_t window, int x, int y, int width, int height, const int32_t *rects, size_t count, uint32_t fill,
                             uint32_t ink, double scale, uintptr_t insert_after) {
    HWND hwnd = reinterpret_cast<HWND>(window);
    Buttons *b = hwnd ? ButtonsOf(hwnd) : nullptr;
    if (!b) return;
    b->rects.clear();
    for (size_t i = 0; i < count; ++i) {
        const int32_t *r = rects + i * 4;
        b->rects.push_back(RECT{r[0], r[1], r[0] + r[2], r[1] + r[3]});
    }
    b->fill = fill;
    b->ink = ink;
    b->scale = scale > 0 ? scale : 1;
    RECT before{};
    GetWindowRect(hwnd, &before);
    if (before.left != x || before.top != y) {  // moved: a tip would be left behind
        HideTip(hwnd, b);
        b->hover = -1;
    }
    SetWindowPos(hwnd, InsertAfter(insert_after), x, y, std::max(width, 1), std::max(height, 1),
                 SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOOWNERZORDER | SWP_NOREDRAW);
    Draw(hwnd);
}

void cra_round_buttons_destroy(uintptr_t window) {
    if (window) DestroyWindow(reinterpret_cast<HWND>(window));
}
