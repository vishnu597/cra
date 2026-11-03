// Images for the Windows shell's XAML: favicons decoded from the PNG bytes Chromium hands over,
// and the downloads list's file thumbnails from Explorer (the Mac's Quick Look). Both come out
// as premultiplied BGRA, which is what a XAML WriteableBitmap holds.
//
// Plain Win32, COM and WIC; nothing here touches CEF. Any thread: each call sets up COM for
// itself and leaves the thread as it found it.
#include "CraCEFWin.h"

#include <windows.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <commctrl.h>
#include <commoncontrols.h>
#include <wincodec.h>

#include <climits>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

// Spelled out here rather than linked from uuid.lib / windowscodecs.lib.
const CLSID kWICImagingFactory = {0xcacaf262, 0x9370, 0x4615, {0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a}};
const GUID kPixelFormat32bppPBGRA = {0x6fddc324, 0x4e03, 0x4bfe, {0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x10}};

/// The largest side cra_image_decode keeps when asked for the natural size.
const UINT kMaxNaturalSide = 256;

std::wstring Wide(const char *utf8) {
    if (!utf8 || !*utf8) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
    std::wstring out(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out.data(), n);
    return out;
}

/// COM for the length of one call. The UI thread already has it (S_FALSE, or RPC_E_CHANGED_MODE
/// when it was set up multithreaded); either way COM is usable and only a success is undone.
struct ComScope {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    ~ComScope() {
        if (SUCCEEDED(hr)) CoUninitialize();
    }
};

/// A COM pointer released on scope exit.
template <typename T>
struct Com {
    T *p = nullptr;
    ~Com() {
        if (p) p->Release();
    }
    T *operator->() const { return p; }
    T **operator&() { return &p; }
    explicit operator bool() const { return p != nullptr; }
};

IWICImagingFactory *Factory() {
    IWICImagingFactory *factory = nullptr;
    CoCreateInstance(kWICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
    return factory;
}

/// `source` scaled to `width` × `height` (unchanged when 0) in premultiplied BGRA.
bool CopyOut(IWICImagingFactory *factory, IWICBitmapSource *source, UINT width, UINT height, CraImage *out) {
    UINT w = 0, h = 0;
    if (FAILED(source->GetSize(&w, &h)) || w == 0 || h == 0) return false;
    Com<IWICBitmapScaler> scaler;
    IWICBitmapSource *sized = source;
    if (width > 0 && height > 0 && (width != w || height != h)) {
        if (FAILED(factory->CreateBitmapScaler(&scaler)) ||
            FAILED(scaler->Initialize(source, width, height, WICBitmapInterpolationModeFant)))
            return false;
        sized = scaler.p;
        w = width;
        h = height;
    }
    Com<IWICFormatConverter> converter;
    if (FAILED(factory->CreateFormatConverter(&converter)) ||
        FAILED(converter->Initialize(sized, kPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0,
                                     WICBitmapPaletteTypeCustom)))
        return false;
    size_t bytes = size_t(w) * h * 4;
    auto *pixels = static_cast<uint8_t *>(malloc(bytes));
    if (!pixels) return false;
    if (FAILED(converter->CopyPixels(nullptr, w * 4, UINT(bytes), pixels))) {
        free(pixels);
        return false;
    }
    out->width = int32_t(w);
    out->height = int32_t(h);
    out->pixels = pixels;
    return true;
}

/// A shell HBITMAP (32 bpp, premultiplied where it has alpha) read top-down.
bool CopyOut(HBITMAP bitmap, CraImage *out) {
    BITMAP info = {};
    if (!GetObjectW(bitmap, sizeof info, &info) || info.bmWidth <= 0 || info.bmHeight == 0) return false;
    int w = info.bmWidth, h = info.bmHeight < 0 ? -info.bmHeight : info.bmHeight;
    BITMAPINFO header = {};
    header.bmiHeader.biSize = sizeof header.bmiHeader;
    header.bmiHeader.biWidth = w;
    header.bmiHeader.biHeight = -h;  // top-down
    header.bmiHeader.biPlanes = 1;
    header.bmiHeader.biBitCount = 32;
    header.bmiHeader.biCompression = BI_RGB;
    size_t bytes = size_t(w) * h * 4;
    auto *pixels = static_cast<uint8_t *>(malloc(bytes));
    if (!pixels) return false;
    HDC dc = GetDC(nullptr);
    int rows = GetDIBits(dc, bitmap, 0, UINT(h), pixels, &header, DIB_RGB_COLORS);
    ReleaseDC(nullptr, dc);
    if (rows != h) {
        free(pixels);
        return false;
    }
    // A photo's thumbnail can come with every alpha byte 0: it is opaque.
    bool anyAlpha = false;
    for (size_t i = 3; i < bytes && !anyAlpha; i += 4) anyAlpha = pixels[i] != 0;
    if (!anyAlpha)
        for (size_t i = 3; i < bytes; i += 4) pixels[i] = 255;
    out->width = w;
    out->height = h;
    out->pixels = pixels;
    return true;
}

/// Explorer's thumbnail (or, with SIIGBF_ICONONLY, icon) of a file that exists.
bool ShellItemImage(const std::wstring &path, int side, SIIGBF flags, CraImage *out) {
    Com<IShellItemImageFactory> item;
    if (FAILED(SHCreateItemFromParsingName(path.c_str(), nullptr, IID_PPV_ARGS(&item)))) return false;
    HBITMAP bitmap = nullptr;
    if (FAILED(item->GetImage(SIZE{side, side}, flags, &bitmap)) || !bitmap) return false;
    bool ok = CopyOut(bitmap, out);
    DeleteObject(bitmap);
    return ok;
}

/// The icon Explorer shows for files named like `path`, which needn't exist (a download that
/// is still running is "name.crdownload" on disk until it finishes).
bool TypeIcon(const std::wstring &path, int side, CraImage *out) {
    SHFILEINFOW info = {};
    if (!SHGetFileInfoW(path.c_str(), FILE_ATTRIBUTE_NORMAL, &info, sizeof info,
                        SHGFI_SYSICONINDEX | SHGFI_USEFILEATTRIBUTES))
        return false;
    Com<IImageList> list;
    if (FAILED(SHGetImageList(side > 32 ? SHIL_EXTRALARGE : SHIL_LARGE, IID_PPV_ARGS(&list)))) return false;
    HICON icon = nullptr;
    if (FAILED(list->GetIcon(info.iIcon, ILD_TRANSPARENT, &icon)) || !icon) return false;
    bool ok = false;
    if (IWICImagingFactory *factory = Factory()) {
        Com<IWICBitmap> bitmap;
        if (SUCCEEDED(factory->CreateBitmapFromHICON(icon, &bitmap))) ok = CopyOut(factory, bitmap.p, 0, 0, out);
        factory->Release();
    }
    DestroyIcon(icon);
    return ok;
}

}  // namespace

extern "C" int cra_image_decode(const uint8_t *bytes, size_t length, int side, CraImage *out) {
    if (!bytes || length == 0 || length > UINT_MAX || !out) return 0;
    *out = CraImage{};
    ComScope com;
    IWICImagingFactory *factory = Factory();
    if (!factory) return 0;
    bool ok = false;
    Com<IWICStream> stream;
    Com<IWICBitmapDecoder> decoder;
    Com<IWICBitmapFrameDecode> frame;
    if (SUCCEEDED(factory->CreateStream(&stream)) &&
        SUCCEEDED(stream->InitializeFromMemory(const_cast<BYTE *>(bytes), DWORD(length))) &&
        SUCCEEDED(factory->CreateDecoderFromStream(stream.p, nullptr, WICDecodeMetadataCacheOnDemand, &decoder)) &&
        SUCCEEDED(decoder->GetFrame(0, &frame))) {
        UINT w = 0, h = 0;
        frame->GetSize(&w, &h);
        UINT tw = 0, th = 0;
        if (side > 0) {
            tw = th = UINT(side);
        } else if (w > kMaxNaturalSide || h > kMaxNaturalSide) {
            // Kept within kMaxNaturalSide, its shape kept.
            tw = w >= h ? kMaxNaturalSide : (w * kMaxNaturalSide + h / 2) / h;
            th = h >= w ? kMaxNaturalSide : (h * kMaxNaturalSide + w / 2) / w;
            if (tw == 0) tw = 1;
            if (th == 0) th = 1;
        }
        ok = CopyOut(factory, frame.p, tw, th, out);
    }
    factory->Release();
    return ok ? 1 : 0;
}

extern "C" int cra_shell_file_image(const char *path, int side, CraImage *out) {
    if (!path || !*path || side <= 0 || !out) return 0;
    *out = CraImage{};
    ComScope com;
    std::wstring file = Wide(path);
    if (GetFileAttributesW(file.c_str()) != INVALID_FILE_ATTRIBUTES) {
        // A picture's or document's preview when Explorer has one, else the file's own icon.
        if (ShellItemImage(file, side, SIIGBF_RESIZETOFIT, out)) return 1;
        if (ShellItemImage(file, side, SIIGBF_ICONONLY, out)) return 1;
    }
    return TypeIcon(file, side, out) ? 1 : 0;
}

extern "C" void cra_image_free(CraImage *image) {
    if (!image) return;
    free(image->pixels);
    *image = CraImage{};
}
