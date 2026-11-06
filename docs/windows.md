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
- Windows-only code stays in `Windows/` and `.github/workflows/windows.yml`
  (`upstream-drift.yml` is the fork's own and is left out when the port is folded back).
- The Windows app reads and writes the same data-folder formats (`sidebar.json` and the
  others), under `%LOCALAPPDATA%\Cra`.

## Keeping up with upstream

The port is meant to fold back into VictorKildahl/cra, so the fork's main merges upstream's
main before each new piece of work, and `.github/workflows/upstream-drift.yml` reports every
Monday how far behind it is (and fails when upstream no longer merges cleanly). Mac code
changes only where a decision moves into CraCore, and then as upstream would write it.

Each sync also updates `Windows/PARITY.md`: a row for every new Mac feature, file and command,
and its `upstream-reviewed` marker moved to the newest upstream commit read.
`python3 -I Windows/scripts/parity.py report --upstream upstream/main` lists what to look at; the
same workflow checks the file on every pull request.

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
shortcuts with Ctrl in place of Cmd, and the command bar (Ctrl+T, Ctrl+L, the sidebar's address
and + New Tab): CraCore's SuggestionEngine in a borderless window owned by the browser window, so
it floats over the page, with inline completion, Tab scopes and Ctrl+Return. Find in page
(Ctrl+F, Ctrl+G, F3) floats the same way at the page's top right, and the downloads list
(CraCore's DownloadHistory, downloads.json) opens from the sidebar footer's downloads button.
Favicons show in the sidebar and the command bar (kept in the data folder's Favicons folder
under the Mac's file names, decoded with WIC), the downloads list shows Explorer's preview or
icon of each file, and Chrome's download-started glyph, which would fly from the page's top
left to the toolbar Cra hides, is hidden as on the Mac.

Phase 2 (Arc parity) has started. Split view: the selected tab's split shows its panes side by
side or stacked, laid out by CraCore's `SplitPaneLayout` like the Mac's. The gaps between them
are the window's own client area, which `HostWindow` paints in the space's colour and where it
takes the divider drags (a double-click makes the panes equal). Ctrl+Shift+= adds a pane,
Ctrl+Shift+- closes one, a click into a pane focuses it, and the split's sidebar row has Arc's
split menu.

Settings: Ctrl+, (or "Settings…" in the command bar) opens Dia's Settings window, an AppWindow
whose XAML island covers it all (no pages in it). CraCore's `SettingsPane`, `SettingsNavigation`
and `SettingsMetrics` give it the Mac's panes, back/forward history and measurements. It lists
the panes whose features Windows has (`SettingsPane.windowsPanes`): General, with "Open Cra at
login" (a value in the user's Run key, cleared from Task Manager's StartupApproved flag when
turned on), and Tabs, with the new-tab, single-space and tab cleanup rows. It follows the
system's light or dark mode and accent colour.

Shortcuts: the actions, their names and command bar phrases and their default keys are CraCore's
(`KeyBindingDefaults`, with `.mac` and `.windows` tables), and `KeyBindingRegistry` lays the
user's own keys from `keybindings.json` over them. Windows' table has the Mac's actions the
Windows app performs, with Ctrl in place of ⌘ and Chrome's Windows keys where those differ
(Alt+Left and Right go back and forward, Ctrl+Tab cycles tabs, F3 and F5). The file keeps the
Mac's format: a key's `.control` bit is Ctrl on Windows, `.option` is Alt. The page's keys, the
command bar's rows and Settings ▸ Shortcuts (Dia's list and shortcut field: click it, press the
new keys, Esc cancels, Backspace removes) all read the registry.

DevTools: Ctrl+Shift+I or F12 (Developer Tools), Ctrl+Shift+J (JavaScript Console), the
command bar, or the page's own Inspect menu item. They dock the way Chrome's do: the DevTools
browser is a child window in the page's place, its frontend (loaded with `can_dock=true`) draws
the split and the device toolbar, and the bridge lays the page window over the part it leaves
for the page. The frontend's dock menu picks the side; undocking moves them into a window of
their own (they close and open again there), and docking moves them back. CraCore's
`DevToolsToggle` decides what each press does, as on the Mac. Cra's own page probes (page and
theme colours) report through `window.__craReport`, a native function CraHelper's renderer puts
in each main frame, so nothing of Cra's shows in a page's Console, even at Verbose.

Developer Mode (Ctrl+Shift+D or the command bar, per site, the Mac's ⌃D): Arc's striped bar over
the page, in a second XAML island HostWindow keeps over the page area's top (the pages move
down under it), with the full URL edited in place, Copy URL, Console, Network, Inspect and Split
View; the site's host and port under its tabs' titles and Arc's dashed ring round the open one.
The bar's colours, stripes and ring are CraCore's (`DeveloperBar.swift`), which the Mac's
toolbar reads too. As on the Mac there is no developer bar in a split.

Little Windows (Ctrl+Alt+N, Arc's Little Arc): one page in a small window, a HostWindow with no
sidebar and the Mac's navy strip in its top island (`Little/LittleStripView.swift`): the host in a
pill that opens the command bar, the profile chip once there are profiles, Copy URL, and "Open in
<Space> Ctrl+O | ⌄". Open in moves the live page into a browser window as a Today tab
(`cra_browser_set_parent` reparents its window and docked DevTools; SpaceWindow picks the window);
closing archives it. Links a Little Window's page opens in a new tab or a popup get Little
Windows of their own. Ctrl+Alt+N also works from any app (Settings ▸ Tabs): `GlobalHotkey`
registers it for the UI thread with RegisterHotKey and `MessageLoop` hands WM_HOTKEY over; a chord
that types a character on the keyboard layout (AltGr+N is ń on Polish keyboards) is left alone,
in Cra's own windows too. CraCore's `LittleWindowLayout` holds the sizes, the placement on the
monitor under the pointer, the colours and the space and profile rules, which the Mac uses too.
Cra stays open while a Little Window is, after its last browser window closes.

Peek is a Little Window in peek mode (as on the Mac): a link to another site from a pinned tab or
favorite (or any tab, or a Shift-click, per Settings ▸ Tabs ▸ Links; CraCore's `PeekTrigger`)
opens over the browser window instead of loading in the tab. The bridge asks first from
OnBeforeBrowse, OnBeforePopup and OnOpenURLFromTab (`opens_peek`). The card is a HostWindow owned
by the browser window, with a border and no title bar, so Windows 11 rounds and shadows it; its
island holds the page-coloured bar (`Peek/PeekBarView.swift`, `PeekLayout.BarColors`). Owned
layered windows from `CraOverlay.cpp` do the rest (`Peek/PeekOverlays.swift`): a catcher over the
client area, a veil in the window's background colour that fades the page to 28 %, and Close,
Expand and Add To Split drawn with GDI+. A click past the card, Escape the page didn't use or
Ctrl+W closes it; Ctrl+O and Expand move the page into a tab; Add To Split joins the tab under it
(`SidebarStore.peekSplitTabs`); Ctrl+Shift+T brings back a Peek closed after the last archived
tab. The card growing out of the link (#204) is still the Mac's alone.

[`Windows/PARITY.md`](../Windows/PARITY.md) lists every Mac feature, what Windows has of it and the
CraCore code both apps share; `Windows/scripts/parity.py` keeps it in step with the Mac app and
upstream (see "Keeping up with upstream").
