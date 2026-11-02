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
  `#if canImport(...)`. The Windows workflow runs its tests on Windows and Linux, and the
  Linux job holds CraCore to the same 85 % line coverage as the macOS CI.
- The sidebar's model (`SidebarStore`: spaces, tabs, folders, splits, the archive) is in
  CraCore, so the Windows sidebar edits the same `sidebar.json` the Mac app does.
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

Two things the build takes care of and must keep doing:

- `libcef_dll_wrapper` is built with MSVC and the bridge with clang. The bridge empties CEF's
  `TRIVIAL_ABI` before its headers so `CefRefPtr` arguments are passed the same way on both
  sides (a compile-time check guards it).
- `Windows/Resources/app.manifest` (Windows 10 support, per-monitor DPI) is embedded in both
  executables. Without it Chromium's GPU process crashes and pages stay black.

## Main thread

CEF and WinUI both call Swift on the main thread, but their callbacks are plain C functions
and `@Sendable` closures, which Swift doesn't know are on the main actor.
`Windows/Sources/CraWin/App/MainThread.swift` has `onMain`, which asserts the main actor
(`MainActor.assumeIsolated`) and runs its body there. XAML event handlers written inside a
`@MainActor` type inherit its isolation and need nothing.

WinUI's message loop doesn't run a Foundation RunLoop, so `Timer` and `RunLoop.main` don't
fire. `WinScheduler` is CraCore's `Scheduler` on DispatcherQueue timers, and the window
redraws through `DispatcherQueue.tryEnqueue`.

## Status

Phase 1 in progress. Done: the full page bridge, and the sidebar on the shared SidebarStore:
spaces (switch, create, delete), favorites, pinned tabs and folders, splits shown as one row,
Today tabs, archive and reopen (Ctrl+Shift+T), unread and theme colours, Arc's tab and space
shortcuts with Ctrl in place of Cmd. Next: the command bar, then downloads and find in page.
The parity checklist and phases are in the porting plan.
