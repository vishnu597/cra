// Entry point for every Chromium subprocess (renderer, GPU, utility). CEF tells it what to
// be through the command line.
#include <windows.h>

#include "include/cef_app.h"

int main() {
    CefMainArgs main_args(GetModuleHandleW(nullptr));
    return CefExecuteProcess(main_args, nullptr, nullptr);
}
