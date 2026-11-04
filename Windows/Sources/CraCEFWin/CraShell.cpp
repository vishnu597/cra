// The clipboard, Windows' Share window and the Save dialog, for the site control center and
// the toasts (CraCEFWin.h, MARK: Shell). Plain Win32, COM and WinRT's ABI; nothing here
// touches CEF. Main thread: the Share window and the Save dialog belong to a window of it.
#include "CraCEFWin.h"

#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wincodec.h>
#include <roapi.h>
#include <winstring.h>
#include <wrl/client.h>
#include <wrl/event.h>
#include <wrl/wrappers/corewrappers.h>
#include <windows.applicationmodel.datatransfer.h>
#include <windows.foundation.h>

#include <climits>
#include <cstring>
#include <set>
#include <string>
#include <vector>

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HStringReference;
namespace DataTransfer = ABI::Windows::ApplicationModel::DataTransfer;
namespace WinFoundation = ABI::Windows::Foundation;

namespace {

// Spelled out rather than linked from uuid.lib, as in CraImages.cpp.
const CLSID kWICImagingFactory = {0xcacaf262, 0x9370, 0x4615, {0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a}};
const GUID kPixelFormat32bppBGRA = {0x6fddc324, 0x4e03, 0x4bfe, {0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x0f}};
const CLSID kFileSaveDialog = {0xc0b4e2f3, 0xba21, 0x4773, {0x8d, 0xba, 0x33, 0x5e, 0xc9, 0x46, 0xeb, 0x8b}};

std::wstring Wide(const char *utf8) {
    if (!utf8 || !*utf8) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
    std::wstring out(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out.data(), n);
    return out;
}

HStringReference Ref(const std::wstring &s) { return HStringReference(s.c_str(), static_cast<unsigned int>(s.size())); }

/// The clipboard, open for this call. Another app can hold it for a moment: a few tries.
struct Clipboard {
    bool open = false;
    Clipboard() {
        for (int i = 0; i < 10 && !(open = OpenClipboard(nullptr) != 0); i++) Sleep(10);
        if (open) EmptyClipboard();
    }
    ~Clipboard() {
        if (open) CloseClipboard();
    }

    /// Hands `bytes` to the clipboard as `format`, which owns them from then on.
    bool Put(UINT format, const void *bytes, size_t length) {
        HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, length);
        if (!memory) return false;
        void *p = GlobalLock(memory);
        if (!p) {
            GlobalFree(memory);
            return false;
        }
        memcpy(p, bytes, length);
        GlobalUnlock(memory);
        if (!SetClipboardData(format, memory)) {
            GlobalFree(memory);
            return false;
        }
        return true;
    }
};

/// The PNG as a packed bottom-up 32 bpp DIB (header, then rows), as CF_DIB wants it.
std::vector<uint8_t> DIBFromPNG(const uint8_t *png, size_t length) {
    std::vector<uint8_t> dib;
    ComPtr<IWICImagingFactory> factory;
    if (FAILED(CoCreateInstance(kWICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) return dib;
    ComPtr<IWICStream> stream;
    ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame;
    ComPtr<IWICFormatConverter> converter;
    UINT w = 0, h = 0;
    if (FAILED(factory->CreateStream(&stream)) ||
        FAILED(stream->InitializeFromMemory(const_cast<BYTE *>(png), static_cast<DWORD>(length))) ||
        FAILED(factory->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder)) ||
        FAILED(decoder->GetFrame(0, &frame)) || FAILED(frame->GetSize(&w, &h)) || w == 0 || h == 0 ||
        FAILED(factory->CreateFormatConverter(&converter)) ||
        FAILED(converter->Initialize(frame.Get(), kPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0,
                                     WICBitmapPaletteTypeCustom)))
        return dib;
    const size_t stride = size_t(w) * 4, bytes = stride * h;
    std::vector<uint8_t> pixels(bytes);
    if (FAILED(converter->CopyPixels(nullptr, static_cast<UINT>(stride), static_cast<UINT>(bytes), pixels.data())))
        return dib;
    BITMAPINFOHEADER header = {};
    header.biSize = sizeof header;
    header.biWidth = static_cast<LONG>(w);
    header.biHeight = static_cast<LONG>(h);  // bottom-up, the way most apps read a CF_DIB
    header.biPlanes = 1;
    header.biBitCount = 32;
    header.biCompression = BI_RGB;
    header.biSizeImage = static_cast<DWORD>(bytes);
    dib.resize(sizeof header + bytes);
    memcpy(dib.data(), &header, sizeof header);
    for (UINT row = 0; row < h; row++)
        memcpy(dib.data() + sizeof header + size_t(h - 1 - row) * stride, pixels.data() + size_t(row) * stride, stride);
    return dib;
}

// MARK: Share

/// What the next DataRequested hands over (the window asks for it once it opens).
std::wstring g_shareURL, g_shareTitle;
/// Windows whose DataTransferManager already has our handler.
std::set<HWND> g_shareWindows;

HRESULT FillShare(DataTransfer::IDataRequestedEventArgs *args) {
    ComPtr<DataTransfer::IDataRequest> request;
    ComPtr<DataTransfer::IDataPackage> package;
    ComPtr<DataTransfer::IDataPackagePropertySet> properties;
    if (!args || FAILED(args->get_Request(&request)) || FAILED(request->get_Data(&package)) ||
        FAILED(package->get_Properties(&properties)))
        return E_FAIL;
    // The Share window shows the title, and needs one.
    std::wstring title = g_shareTitle.empty() ? g_shareURL : g_shareTitle;
    properties->put_Title(Ref(title).Get());
    package->SetText(Ref(g_shareURL).Get());
    ComPtr<WinFoundation::IUriRuntimeClassFactory> uris;
    ComPtr<WinFoundation::IUriRuntimeClass> uri;
    ComPtr<DataTransfer::IDataPackage2> links;
    if (SUCCEEDED(RoGetActivationFactory(HStringReference(RuntimeClass_Windows_Foundation_Uri).Get(), IID_PPV_ARGS(&uris))) &&
        SUCCEEDED(uris->CreateUri(Ref(g_shareURL).Get(), &uri)) && SUCCEEDED(package.As(&links)))
        links->SetWebLink(uri.Get());
    return S_OK;
}

std::wstring DownloadsFolder() {
    PWSTR path = nullptr;
    std::wstring out;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Downloads, 0, nullptr, &path)) && path) out = path;
    if (path) CoTaskMemFree(path);
    return out;
}

}  // namespace

extern "C" int cra_clipboard_set_text(const char *text) {
    if (!text) return 0;
    std::wstring wide = Wide(text);
    Clipboard clipboard;
    return clipboard.open && clipboard.Put(CF_UNICODETEXT, wide.c_str(), (wide.size() + 1) * sizeof(wchar_t)) ? 1 : 0;
}

extern "C" int cra_clipboard_set_png(const uint8_t *png, size_t length) {
    if (!png || length == 0 || length > UINT_MAX) return 0;
    std::vector<uint8_t> dib = DIBFromPNG(png, length);
    Clipboard clipboard;
    if (!clipboard.open) return 0;
    static const UINT pngFormat = RegisterClipboardFormatW(L"PNG");
    bool ok = pngFormat && clipboard.Put(pngFormat, png, length);
    if (!dib.empty()) ok = clipboard.Put(CF_DIB, dib.data(), dib.size()) || ok;
    return ok ? 1 : 0;
}

extern "C" int cra_share_link(uintptr_t owner, const char *url, const char *title) {
    HWND window = reinterpret_cast<HWND>(owner);
    if (!window || !url || !*url) return 0;
    ComPtr<IDataTransferManagerInterop> interop;
    ComPtr<DataTransfer::IDataTransferManager> manager;
    if (FAILED(RoGetActivationFactory(HStringReference(RuntimeClass_Windows_ApplicationModel_DataTransfer_DataTransferManager).Get(),
                                      IID_PPV_ARGS(&interop))) ||
        FAILED(interop->GetForWindow(window, IID_PPV_ARGS(&manager))))
        return 0;
    g_shareURL = Wide(url);
    g_shareTitle = Wide(title);
    if (!g_shareWindows.count(window)) {
        using Handler = WinFoundation::ITypedEventHandler<DataTransfer::DataTransferManager *, DataTransfer::DataRequestedEventArgs *>;
        auto handler = Callback<Handler>([](DataTransfer::IDataTransferManager *, DataTransfer::IDataRequestedEventArgs *args) {
            return FillShare(args);
        });
        EventRegistrationToken token;
        if (!handler || FAILED(manager->add_DataRequested(handler.Get(), &token))) return 0;
        g_shareWindows.insert(window);
    }
    return SUCCEEDED(interop->ShowShareUIForWindow(window)) ? 1 : 0;
}

extern "C" int cra_popup_menu(uintptr_t owner, const char *const *titles, size_t count) {
    HWND window = reinterpret_cast<HWND>(owner);
    HMENU menu = CreatePopupMenu();
    if (!menu || !titles) return 0;
    for (size_t i = 0; i < count; i++) {
        if (!titles[i] || !*titles[i]) {
            AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
        } else {
            AppendMenuW(menu, MF_STRING, static_cast<UINT_PTR>(i + 1), Wide(titles[i]).c_str());
        }
    }
    POINT p = {};
    GetCursorPos(&p);
    // The menu closes on a click elsewhere only when its owner is in front.
    SetForegroundWindow(window);
    int chosen = static_cast<int>(TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, p.x, p.y, window, nullptr));
    DestroyMenu(menu);
    return chosen;
}

extern "C" int cra_save_png_dialog(uintptr_t owner, const char *title, const char *file_name, char *out, size_t capacity) {
    if (!out || capacity == 0) return 0;
    out[0] = '\0';
    ComPtr<IFileSaveDialog> dialog;
    if (FAILED(CoCreateInstance(kFileSaveDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)))) return 0;
    if (title) dialog->SetTitle(Wide(title).c_str());
    if (file_name) dialog->SetFileName(Wide(file_name).c_str());
    COMDLG_FILTERSPEC types[] = {{L"PNG image", L"*.png"}};
    dialog->SetFileTypes(1, types);
    dialog->SetDefaultExtension(L"png");
    std::wstring downloads = DownloadsFolder();
    ComPtr<IShellItem> folder;
    if (!downloads.empty() && SUCCEEDED(SHCreateItemFromParsingName(downloads.c_str(), nullptr, IID_PPV_ARGS(&folder))))
        dialog->SetFolder(folder.Get());
    ComPtr<IShellItem> result;
    PWSTR path = nullptr;
    if (FAILED(dialog->Show(reinterpret_cast<HWND>(owner))) || FAILED(dialog->GetResult(&result)) ||
        FAILED(result->GetDisplayName(SIGDN_FILESYSPATH, &path)) || !path)
        return 0;
    int n = WideCharToMultiByte(CP_UTF8, 0, path, -1, out, static_cast<int>(capacity), nullptr, nullptr);
    CoTaskMemFree(path);
    return n > 0 ? 1 : 0;
}
