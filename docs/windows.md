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

## Status

Phase 0: one WinUI window with an address field and one page. The parity checklist and
phases are in the porting plan.
