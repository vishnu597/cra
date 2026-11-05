# Cra for Windows

The Windows shell of Cra: WinUI 3 through Swift/WinRT, with Chromium through CEF. It
shares `Packages/CraCore` with the macOS app. [PARITY.md](PARITY.md) lists every Mac feature, its
state on Windows and the shared code behind it.

## Build

You need Windows 10 1809 or later on x64, Visual Studio 2022 with the C++ workload,
CMake, the [Swift toolchain for Windows](https://www.swift.org/install/windows/) (6.1 or
later) and the [Windows App Runtime 1.7](https://aka.ms/windowsappsdk/1.7/1.7.250909003/windowsappruntimeinstall-x64.exe).

    pwsh Windows/scripts/build.ps1
    Windows/build/Cra/Cra.exe

`fetch-deps.ps1` downloads CEF and the Swift/WinRT projections into `Windows/vendor`.

## Layout

| Path | What |
|---|---|
| `Sources/CraWin` | The app: WinUI window, sidebar column, page layout |
| `Sources/CraCEFWin` | C++ bridge to CEF behind a C header, the counterpart of `Sources/CraCEF` |
| `Sources/CraHelperWin` | The Chromium subprocess executable |
