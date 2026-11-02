// CEF on Windows: one CefApp for the browser process and a CefClient per page, behind the C
// surface in include/CraCEFWin.h.
#include "CraCEFWin.h"

#include <windows.h>

#include <mutex>
#include <string>

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

class CraApp : public CefApp, public CefBrowserProcessHandler {
public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

private:
    IMPLEMENT_REFCOUNTING(CraApp);
};

// One page. Calls made before Chromium created the browser are remembered and applied in
// OnAfterCreated.
class CraClient : public CefClient, public CefDisplayHandler, public CefLifeSpanHandler {
public:
    explicit CraClient(CraBrowserCallbacks callbacks) : callbacks_(callbacks) {}

    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

    void OnTitleChange(CefRefPtr<CefBrowser>, const CefString &title) override {
        if (callbacks_.title_changed) callbacks_.title_changed(callbacks_.context, title.ToString().c_str());
    }

    void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString &url) override {
        if (frame->IsMain() && callbacks_.address_changed)
            callbacks_.address_changed(callbacks_.context, url.ToString().c_str());
    }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        std::lock_guard<std::mutex> lock(mutex_);
        browser_ = browser;
        if (has_frame_) ApplyFrame();
        if (close_requested_) browser_->GetHost()->CloseBrowser(true);
    }

    void OnBeforeClose(CefRefPtr<CefBrowser>) override {
        CEF_REQUIRE_UI_THREAD();
        std::lock_guard<std::mutex> lock(mutex_);
        browser_ = nullptr;
    }

    void SetFrame(int x, int y, int width, int height) {
        std::lock_guard<std::mutex> lock(mutex_);
        frame_ = {x, y, width, height};
        has_frame_ = true;
        if (browser_) ApplyFrame();
    }

    CefRefPtr<CefBrowser> Browser() {
        std::lock_guard<std::mutex> lock(mutex_);
        return browser_;
    }

    void Close() {
        std::lock_guard<std::mutex> lock(mutex_);
        callbacks_ = CraBrowserCallbacks{};
        if (browser_) browser_->GetHost()->CloseBrowser(true);
        else close_requested_ = true;
    }

private:
    void ApplyFrame() {
        HWND hwnd = browser_->GetHost()->GetWindowHandle();
        if (hwnd) SetWindowPos(hwnd, nullptr, frame_.x, frame_.y, frame_.width, frame_.height,
                               SWP_NOZORDER | SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS);
    }

    CraBrowserCallbacks callbacks_;
    std::mutex mutex_;
    CefRefPtr<CefBrowser> browser_;
    CefRect frame_;
    bool has_frame_ = false;
    bool close_requested_ = false;

    IMPLEMENT_REFCOUNTING(CraClient);
};

}  // namespace

struct CraBrowser {
    CefRefPtr<CraClient> client;
};

extern "C" int cra_cef_execute_process(void) {
    CefMainArgs main_args(GetModuleHandleW(nullptr));
    return CefExecuteProcess(main_args, nullptr, nullptr);
}

extern "C" int cra_cef_initialize(const char *helper_path, const char *cache_root) {
    CefMainArgs main_args(GetModuleHandleW(nullptr));
    CefSettings settings;
    settings.no_sandbox = true;  // The sandbox needs cef_sandbox.lib linked into the exe; later.
    settings.multi_threaded_message_loop = true;
    CefString(&settings.browser_subprocess_path) = Wide(helper_path);
    CefString(&settings.root_cache_path) = Wide(cache_root);
    CefString(&settings.cache_path) = Wide(cache_root) + L"\\Default";
    CefRefPtr<CraApp> app(new CraApp);
    return CefInitialize(main_args, settings, app, nullptr) ? 1 : 0;
}

extern "C" void cra_cef_shutdown(void) { CefShutdown(); }

extern "C" CraBrowser *cra_browser_create(uintptr_t parent, int x, int y, int width, int height,
                                          const char *url, CraBrowserCallbacks callbacks) {
    auto *browser = new CraBrowser{new CraClient(callbacks)};
    browser->client->SetFrame(x, y, width, height);
    CefWindowInfo info;
    info.SetAsChild(reinterpret_cast<HWND>(parent), CefRect(x, y, width, height));
    CefBrowserSettings browser_settings;
    CefBrowserHost::CreateBrowser(info, browser->client, Wide(url), browser_settings, nullptr, nullptr);
    return browser;
}

extern "C" void cra_browser_set_frame(CraBrowser *browser, int x, int y, int width, int height) {
    if (browser) browser->client->SetFrame(x, y, width, height);
}

extern "C" void cra_browser_load_url(CraBrowser *browser, const char *url) {
    if (!browser) return;
    if (auto b = browser->client->Browser()) b->GetMainFrame()->LoadURL(Wide(url));
}

extern "C" void cra_browser_go_back(CraBrowser *browser) {
    if (!browser) return;
    if (auto b = browser->client->Browser()) b->GoBack();
}

extern "C" void cra_browser_go_forward(CraBrowser *browser) {
    if (!browser) return;
    if (auto b = browser->client->Browser()) b->GoForward();
}

extern "C" void cra_browser_reload(CraBrowser *browser) {
    if (!browser) return;
    if (auto b = browser->client->Browser()) b->Reload();
}

extern "C" void cra_browser_close(CraBrowser *browser) {
    if (!browser) return;
    browser->client->Close();
    delete browser;
}
