# Cra for Windows

The Windows app lives in `Windows/`, a Swift package of its own beside the macOS app. It
shares `Packages/CraCore` (models, file formats, layout and policy decisions) and has its
own shell: WinUI 3 through The Browser Company's Swift/WinRT projections, with Chromium
through CEF's Windows build. Nothing in `Windows/` is built by the macOS scripts, and
nothing outside it is Windows-only.

## Build

On Windows 10 1809+ (x64) with Visual Studio 2022 (C++ workload), CMake, the Swift
toolchain for Windows (6.1+) and the Windows App Runtime 1.7:

    pwsh Windows/scripts/build.ps1     # fetches CEF and the projections, builds Windows/build/Cra
    Windows/build/Cra/Cra.exe

`Windows/scripts/fetch-deps.ps1` reads the Chromium version from `scripts/fetch-cef.sh`, so
both apps run the same Chromium. It uses Spotify's stock CEF build for now (no H.264/AAC,
none of `scripts/cef-patches`).

## Rules

- Shared decisions go in CraCore with a test, as CLAUDE.md says for the macOS app, so both
  shells get them. Don't copy logic from `Sources/Cra` into `Windows/`; move it to CraCore.
- CraCore keeps building off Apple platforms: Apple-only frameworks go behind
  `#if canImport(...)`. The Windows workflow runs its tests on Windows and Linux.
- Windows-only code stays in `Windows/` and `.github/workflows/windows.yml`.
- The Windows app reads and writes the same data-folder formats (`sidebar.json` and the
  others), under `%LOCALAPPDATA%\Cra`.

## Chromium

`Windows/Sources/CraCEFWin` is the Windows counterpart of `Sources/CraCEF`: a C++ bridge with
a plain C surface (`include/CraCEFWin.h`) that `Windows/Sources/CraWin/Browser/WebPage.swift`
wraps with the same delegate methods as `CraBrowserDelegate`. Each page is a Win32 child
window of the WinUI window.

CEF runs on the main thread, as on macOS: `external_message_pump` hands Chromium's work to a
message-only window, so WinUI's message loop pumps it and every callback arrives on the main
thread. No locks, no hops between threads.

Chromium's own crash recovery is off: after a run that didn't quit cleanly it would reopen
the last session in a stock Chromium window, so `CrashRecovery` clears it from the profiles
before Chromium starts (`ChromiumCrashState` in CraCore, as the Mac bridge does).

The window is not a WinUI `Window`. A Window's XAML bridge covers its whole client area, and
while it covers a page no real click or wheel reaches the page, whatever the z-order.
`HostWindow` is an AppWindow with a `DesktopWindowXamlSource` whose bridge it keeps to the
sidebar column; the pages sit beside it. WinUI's `ContentPreTranslateMessage` also takes key
messages meant for Chromium's windows, so the app's `MessageLoop` hands those windows their
messages without it.

Two things the build takes care of and must keep doing:

- `libcef_dll_wrapper` is built with MSVC and the bridge with clang. The bridge empties CEF's
  `TRIVIAL_ABI` before its headers so `CefRefPtr` arguments are passed the same way on both
  sides (a compile-time check guards it).
- `Windows/Resources/app.manifest` (Windows 10 support, per-monitor DPI) is embedded in both
  executables. Without it Chromium's GPU process crashes and pages stay black.

## Status

Phase 1 in progress: the full page bridge, with a plain list of tabs in the sidebar while the
real sidebar (spaces, pinned and Today tabs, favorites) is ported. The parity checklist and
phases are in the porting plan.
