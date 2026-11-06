// The Peek's windows that aren't XAML or a page (CraCEFWin.h, MARK: Overlays): the veil that
// fades the browser window's page and catches the click that closes the Peek, and the column of
// round buttons beside the card. Plain Win32 and GDI+; nothing here touches CEF. Main thread.
#include "CraCEFWin.h"

#include <windows.h>
#include <commctrl.h>
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
};

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

void UpdateTips(HWND hwnd, Buttons *b) {
    if (!b->tooltip) return;
    for (size_t i = 0; i < b->rects.size(); ++i) {
        TOOLINFOW tool{};
        tool.cbSize = sizeof(tool);
        tool.hwnd = hwnd;
        tool.uId = i + 1;
        tool.rect = b->rects[i];
        SendMessageW(b->tooltip, TTM_NEWTOOLRECTW, 0, reinterpret_cast<LPARAM>(&tool));
    }
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
    case WM_LBUTTONDOWN:
        if (b) {
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
        if (b && b->tooltip) DestroyWindow(b->tooltip);
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
    INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_WIN95_CLASSES};
    InitCommonControlsEx(&controls);
    b->tooltip = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, nullptr, WS_POPUP | TTS_NOPREFIX | TTS_ALWAYSTIP, CW_USEDEFAULT,
                                 CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, hwnd, nullptr, Instance(), nullptr);
    if (b->tooltip) {
        for (size_t i = 0; i < count; ++i) {
            TOOLINFOW tool{};
            tool.cbSize = sizeof(tool);
            tool.uFlags = TTF_SUBCLASS;
            tool.hwnd = hwnd;
            tool.uId = i + 1;
            tool.lpszText = b->tips[i].data();
            SendMessageW(b->tooltip, TTM_ADDTOOLW, 0, reinterpret_cast<LPARAM>(&tool));
        }
    }
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
    SetWindowPos(hwnd, InsertAfter(insert_after), x, y, std::max(width, 1), std::max(height, 1),
                 SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOOWNERZORDER | SWP_NOREDRAW);
    UpdateTips(hwnd, b);
    Draw(hwnd);
}

void cra_round_buttons_destroy(uintptr_t window) {
    if (window) DestroyWindow(reinterpret_cast<HWND>(window));
}
