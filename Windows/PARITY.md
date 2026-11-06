# Mac feature parity

Every feature of the Mac app, what the Windows app has of it, and where the code that both
can share lives. The goal is the Mac app's features on Windows, built on the Mac's own logic:
what decides something goes in CraCore once and both shells call it (CLAUDE.md, rule 1).

<!-- upstream-reviewed: dd8ae64 -->
Upstream reviewed through **ef42649** (VictorKildahl/cra main, 5 Nov 2026). Fork main has
merged upstream through ef42649 (#22).

**Status:** ✅ on Windows · 🟡 partly · 🔜 in review · ❌ not yet · ➖ Mac only, or replaced by a
Windows counterpart

**Sources:** the Mac code (the files named in each row), the upstream history, and the site's
[release notes](https://crabrowser.app/release-notes) and [changelog](https://crabrowser.app/changelog),
which say in users' words how each feature behaves. For look and feel: [brand](https://crabrowser.app/brand),
[design notes](https://crabrowser.app/design-notes), `brand/` and `docs/arc-reverse-engineering.md`.

## Summary

<!-- summary: parity.py summary --write -->
| Area | ✅ | 🟡 | 🔜 | ❌ | ➖ |
|---|--:|--:|--:|--:|--:|
| Window, pages and toolbar | 6 | 3 | 0 | 5 | 1 |
| Sidebar | 6 | 4 | 0 | 11 | 0 |
| Command bar and shortcuts | 3 | 1 | 0 | 1 | 0 |
| Split view | 1 | 1 | 0 | 0 | 0 |
| Little Windows, Peek and the Library | 0 | 1 | 1 | 5 | 0 |
| Tabs and memory | 1 | 1 | 0 | 3 | 0 |
| Media and capture | 0 | 2 | 0 | 2 | 1 |
| Profiles, privacy and site data | 3 | 1 | 0 | 6 | 0 |
| DevTools and Developer Mode | 2 | 0 | 0 | 1 | 0 |
| Extensions | 0 | 0 | 0 | 5 | 0 |
| Settings | 4 | 1 | 0 | 4 | 0 |
| Import and onboarding | 0 | 0 | 0 | 5 | 1 |
| Arc Max (on-device AI) | 0 | 0 | 0 | 0 | 3 |
| System integration and release | 3 | 0 | 0 | 6 | 2 |
| **All** | 29 | 15 | 1 | 54 | 8 |
<!-- /summary -->

## Window, pages and toolbar

| Feature | Windows | Mac code | Shared in CraCore | Notes and next step |
|---|---|---|---|---|
| Browser window with pages inside it (CEF child windows), crash-safe start | ✅ [#2] [#3] | `main.swift`, `AppDelegate.swift`, `AppComposition.swift`, `MainWindowController.swift`, `ShellView.swift`, `BrowserManager.swift`, `EmbeddedPages.swift`, `ChromiumWindowCorners.swift`, `ChromiumChildHover.swift`, `ChromiumChildFullscreen.swift`, `WindowDragGesture.swift`, `CraCEF.mm`, `CraCEF.h`, `main.cc` | `ChromiumCrashState`, `JSONStore`, `Scheduling`, `ObserveChanges` | Windows: `HostWindow`, `CraCEFWin.cpp`. Missing: Settings' edge-to-edge pages, Escape leaves video fullscreen (check). |
| More than one window, window frames saved in `windows.json` | ✅ [#18] | `MainWindowController.swift` | `WindowFrame`, `SpaceWindow` | `SpaceWindow` picks the window a Little Window's page goes to (#23); `moveTabToSpaceN` still waits for a key. |
| Private (incognito) windows | ✅ [#18] | `BrowserManager.swift` | `SidebarStore` | |
| Toolbar: optional (`toggleToolbar`), host-only address, Show Full URL, reload that turns into stop (`stop`), tab colour, link-copy glyph | ❌ | `PaneToolbarView.swift`, `AppKitControls.swift` | `ToolbarComposition`, `ToolbarColor`, `ToolbarExtensionFit` | Off by default as on the Mac, so it comes after the sidebar's address pill. Composition and colour decisions are already shared. |
| Loading bar at the top middle of the window | ❌ | `LoadingIndicatorView.swift` | `LoadingIndicator` | Small: drive a XAML bar from `LoadingIndicator`. |
| Hide the sidebar (`toggleSidebar`) and the floating sidebar that slides in from the left edge | ❌ | `FloatingSidebar.swift`, `FloatingSidebarGeometry.swift` | (move `FloatingSidebarGeometry` here) | `FloatingSidebarGeometry` is a CLAUDE.md known exception: move it to CraCore with this PR. |
| Find in page with match count | ✅ [#10] | `Overlays.swift` | `FindInPage` | |
| Toasts (copied URL with Share, captures, downloads) | ✅ [#17] | `ShinyToast.swift`, `Overlays.swift` | `ToastStyle` | Share button on Windows needs the Windows share sheet (DataTransferManager). |
| Site Control Center, lock badge and certificate viewer | ✅ [#17] | `SiteControlCenter.swift`, `CertificateWindow.swift` | `SiteControlCenter`, `ConnectionSecurity`, `PageCapture` | Missing: the protected-media card (Mac only, see Media). |
| Zoom (`zoomIn`, `zoomOut`, `resetZoom`), `print`, `viewSource` | 🟡 | `AppDelegate.swift` | `KeyBindingDefaults` | Left to Chromium's own keys on Windows: not in Cra's key table, the command bar or Settings ▸ Shortcuts. Add them to `KeyBindingDefaults.windowsShortcuts`. |
| Page context menu: Open Link in New Tab / Background Tab | 🟡 | `BrowserManager.swift` | `LinkMenu` | Chromium's menu shows; Cra's two items and the background setting are missing. |
| Arc-style tooltips in the space's tones | ❌ | `ArcTooltip.swift` | `ThemeTones` (`TooltipTones`) | Windows uses plain WinUI tooltips. |
| Theme, metrics and the brand mark | 🟡 | `Theme.swift`, `Tuning.swift`, `BrandMark.swift` | `SpaceTheme`, `ThemeTones` | Sidebar palette from `SpaceTheme` is shared; Windows has its own metrics. Brand mark from `brand/`. |
| Sidebar blur, Reduce transparency, active/inactive look | ❌ | `ActiveAppearanceProbe.swift` | `SidebarBackdrop` | Windows counterpart: Mica or Acrylic, and Windows' transparency setting. Since f6b9fb6 a full-screen window keeps its active look while its Space slides away (AppKit's own answer, `windowActive(activeAppearance:)`). |
| Only one Cra running (an older copy quits) | ➖ | `NewestCopy.swift` | | Windows: a single-instance mutex when the installer lands. |

## Sidebar

| Feature | Windows | Mac code | Shared in CraCore | Notes and next step |
|---|---|---|---|---|
| Spaces: switch, create, delete, the space dock | ✅ [#5] | `SidebarView.swift`, `SidebarRootView.swift`, `SpaceDock.swift`, `SpaceListView.swift`, `SpaceColumnView.swift`, `SidebarUIState.swift` | `SidebarStore`, `SidebarModel`, `ItemTable`, `SidebarIntegrity` | Same `sidebar.json` as the Mac. |
| Go to Space N (`spaceN`) on Alt+1–9, next and previous space on Ctrl+Alt+Right and Left | ✅ [#5] [#21] | `MainWindowController.swift`, `AppDelegate.swift` | `KeyBindingDefaults`, `SidebarStore` (`focusSpace(number:)`) | Arc for Windows' keys: Ctrl+1–9 stays Go to Tab, as in Chrome. |
| Move Tab to Space N (`moveTabToSpaceN`) | ❌ | `MainWindowController.swift`, `AppDelegate.swift` | `SpaceWindow`, `SidebarStore` | No Windows key yet (the Mac's is ⌃⌘N); comes with Little Windows, whose page it can also send. |
| Swipe, Shift + wheel or sideways wheel between spaces | ❌ | `SpacePagerView.swift` | `WheelSpaceSwitch` | Decision shared; Windows needs the wheel hook and the slide. |
| Pinned tabs and folders, Today, Clear Today, archive on close | ✅ [#5] | `SidebarRowViews.swift`, `SidebarItemView.swift` | `SidebarStore`, `CloseSuccessor`, `SidebarClose` | `clearToday` and `newFolder` are in the sidebar menus, not yet commands; `SidebarClose` (Arc's close buttons per row kind) isn't used on Windows yet. |
| Pinned tab extras: back to its page by the favicon, the slash, Reset (`resetTab`), edit URL | ❌ | `EditPinnedURLDialog.swift`, `SidebarRowViews.swift` | `PinnedNavigation` | Since 6e371cc "Back to Pinned URL" slides in under the title on hovering the icon (0.16 s). |
| Folders: hinge animation, hover previews with search, tabs shown under a closed folder | 🟡 | `FolderPreview.swift` | `FolderPeek` | Windows has folders without previews or the animation. |
| Favorites | 🟡 [#5] | `SidebarRowViews.swift`, `TileColor.swift` | `FavoritesLayout`, `FavoritesSharing` | Missing: 4/2/1 columns by width (`FavoritesLayout`), tile colours and icons, "Drag to add Favorites" card, Settings' share-across-spaces switch. |
| Drag and drop: reorder, into folders and favorites, onto a space's icon, several picked tabs at once, reorder spaces | ❌ | `SidebarListDrop.swift`, `SpaceListView.swift` | `SidebarStore` | The store's moves are shared; the XAML drag layer is the work. Big item. Since 1f3c3d3 a tab dropped on any tab, pinned too, offers a split (no folder drop); since dfa3358 rows keep their hover through AppKit's stray exits (Mac only). |
| Space menu: rename, icon, theme, profile, folder, export, delete | 🟡 [#5] [#19] | `MainWindowController+SpaceMenu.swift`, `SidebarMenus.swift`, `SpaceIconPicker.swift`, `EmojiCatalog.swift`, `EmojiCatalog+Data.swift` | `SpaceProfiles` | Windows has New Folder, New Space, Clear Today, Hide Space Header, Set Profile, Delete. Missing `editSpace`, `deleteSpace` and `newSpace` as commands, rename, the emoji picker. `EmojiCatalog+Data.swift` has no imports: move it to CraCore for the Windows picker. |
| Space theme editor: Arc's presets, light and dark halves, grain | ❌ | `SpaceStyleEditor.swift`, `SpaceEditorView.swift` | `SpaceTheme`, `SpaceThemeVariants`, `SpaceColorPresets`, `ArcThemeImport` | Windows draws themes it reads; editing is missing. The colour logic is all shared. Since 6e371cc swatches and knobs grow under the pointer and shrink when pressed. |
| Manage Spaces page (`manageSpaces`) | ❌ | `SpacesManagerView.swift` | `SidebarStore` | |
| Space tooltip with its profile and keys | ❌ | `SpaceDock.swift`, `ArcTooltip.swift` | `ThemeTones` | |
| Jump pill back to the open tab | ❌ | `SidebarJumpPill.swift` | | |
| Rename (`renameTab`), duplicate (`duplicateTab`), Add to Favorites (`favoriteTab`) as commands | 🟡 | `SidebarMenus.swift` | `SidebarStore` | Duplicate and favorites are in the row menu; rename is missing; none are commands yet. |
| Unread dots and theme colours | ✅ [#5] | `SidebarRowViews.swift` | `SidebarModel` | |
| Download location per profile: a folder, or ask where to save each file (Settings ▸ Profiles) | ❌ | `DownloadDestinations.swift`, `ProfilesPane.swift` | `DownloadLocation` | Upstream ef42649. `DownloadLocation`'s decoder keeps only folders starting with "/": Windows needs drive paths (`C:\…`) to count as absolute first. |
| Downloads list in the footer, thumbnails, no Chrome download arrow | ✅ [#10] [#12] | `DownloadsTray.swift`, `DownloadThumbnails.swift`, `ChromeDownloadAnimation.swift` | `DownloadHistory`, `DownloadRow`, `RelativeTime` | Missing: the flight into the bin (`DownloadFlight.swift`), `viewDownloads` (⇧⌘J) as a command. |
| Download flight into the Library button | ❌ | `DownloadFlight.swift` | | |
| Favicons in rows, tiles and the command bar | ✅ [#12] | `FaviconCache.swift` | `FaviconKey` | |
| GitHub live folders (`newGitHubLiveFolder`) | ❌ | `LiveFolderManager.swift`, `GitHubLiveClient.swift`, `LiveFolderViews.swift` | `LiveFolderModel` | `GitHubLiveClient.swift` is Foundation only: move it to CraCore so Windows doesn't rewrite it. Sign-in token storage needs Credential Manager. |

## Command bar and shortcuts

| Feature | Windows | Mac code | Shared in CraCore | Notes and next step |
|---|---|---|---|---|
| Command bar: tabs, archive, history, domains, actions, inline completion, ⌘Return background tab | ✅ [#8] [#9] | `CommandBarController.swift`, `CommandBarView.swift`, `CommandTextField.swift`, `SearchSuggestLoader.swift` | `SuggestionEngine`, `CommandBarDedupe`, `CommandBarGlyph`, `TypedURL`, `RelativeTime` | Windows: `WinSuggestLoader` repeats the Mac's loader on FoundationNetworking; move the loader to CraCore. Missing: the theme-following glow and scope bounce, ⌥Return as a split, `checkForUpdates`. |
| Search suggestions, Site Search with Tab, % tab search, Chromium's engines | ✅ [#9] [#13] | `SearchEngines.swift` | `SearchSuggestions`, `SiteSearch`, `TabSearchScope` | Windows reads Cra's engine setting; the Mac also reads Chromium's engine list (SQLite). |
| Shortcuts in `keybindings.json`, Settings ▸ Shortcuts | ✅ [#15] | `KeyBindings.swift`, `ShortcutsPane.swift` | `KeyBindingDefaults`, `KeyBindings`, `KeyChord`, `KeyChord+Windows` | Windows' table is `KeyBindingDefaults.windowsShortcuts`; a command joins it when Windows performs it (`parity.py report` lists the rest, each named in its feature's row). |
| Recent-tab switcher on ⌃Tab (`recentTab`, `recentTabBackward`) | ❌ | `TabSwitcher.swift`, `TabSwitcherView.swift` | `SidebarStore` | Ctrl+Tab cycles sidebar order on Windows until this lands. |
| Context menus show shortcut glyphs | 🟡 | `SidebarMenus.swift` | `KeyBindings` | WinUI menu items take KeyboardAcceleratorTextOverride. |

## Split view

| Feature | Windows | Mac code | Shared in CraCore | Notes and next step |
|---|---|---|---|---|
| Up to four panes, dragger, add, close, separate, flip, cycle, split menu | ✅ [#11] | `PaneCardView.swift`, `SplitDraggerHandleView.swift`, `SplitPaneLayout.swift` | `SplitPaneLayout` | |
| Pane controls on focus and hover, focus ring, rename a split, pinned and favorite splits | 🟡 | `PaneCardView.swift`, `SidebarRowViews.swift` | `SidebarStore` | Windows has the layout and the menu; the per-pane bar, ring and rename are missing. |

## Little Windows, Peek and the Library

| Feature | Windows | Mac code | Shared in CraCore | Notes and next step |
|---|---|---|---|---|
| Little Windows (`newLittleWindow`, `promoteLittleWindow`, `closeLittleWindows`), profile chip, ⌥⌘N from any app | 🔜 [#23] | `LittleWindowController.swift`, `GlobalHotkey.swift` | `LittleWindowLayout`, `SpaceWindow`, `GlobalShortcut` | Windows: Ctrl+Alt+N (also from any app, RegisterHotKey, skipped where AltGr+N types a letter), Ctrl+O; the strip, Open in Space and its menu, the profile chip, the command bar, size and cascade, archive on close. The live page moves into the browser window (`cra_browser_set_parent`). Windows keeps its own title bar in the strip's navy. Left: Arc's searchable spaces popup (a menu here), the grow-from-the-pointer animation, "Don't ask again" on the profile change. |
| Peek: card over the page with its own bar, Close, Expand, Add To Split | ❌ | `PeekChrome.swift` | `PeekLayout`, `PeekTrigger`, `PinnedNavigation` | With Little Windows. Layout and trigger are shared. |
| Air Traffic Control: route links from other apps to a space or Little Window | ❌ | `AirTrafficControlView.swift` | `LinkRouting` | Needs Cra to be a registered browser first (System integration). |
| Library in the sidebar (`openLibrary`), swipe or button slides it in | ❌ | `LibraryView.swift` | `LibrarySwipe` | |
| History and archive view (`viewArchive`) | ❌ | `LibraryView.swift` | `SidebarStore` | Archive and reopen already work (Ctrl+Shift+T, the command bar). |
| Now-playing player in the sidebar | ❌ | `NowPlayingTray.swift`, `NowPlaying.swift` | | Windows counterpart for media keys: System Media Transport Controls. |
| Downloads rename card | 🟡 | `DownloadRenameCard.swift` | `TidyDownloads` | The Windows list has open and Show in Folder; the rename card comes with Tidy Downloads. |

## Tabs and memory

| Feature | Windows | Mac code | Shared in CraCore | Notes and next step |
|---|---|---|---|---|
| Auto-archive Today tabs after a set time | ✅ [#14] | `TabsPane.swift` | `SidebarModel` (`AutoArchiveThreshold`) | |
| Tab freezing and sleeping, Tab Cleanup timers, calls stay awake | ❌ | `BrowserManager.swift` | `TabSleepPolicy` | The policy is shared; Windows needs the CEF discard calls and the two Settings ▸ Tabs switches. |
| Mute a tab (`muteTab`), speaker icon, camera and microphone dot | 🟡 | `SidebarRowViews.swift` | `SidebarModel` | The bridge can mute; the sidebar shows no speaker yet. |
| Open links in new tabs in the background | ❌ | `TabsPane.swift` | `LinkMenu` | |
| Background tabs laid out at the pane's size, first seconds of a tab | ❌ | `BrowserManager.swift`, `PageProbe.swift`, `PageScript.swift` | | `PageScript.swift` is Foundation only: move it to CraCore. |

## Media and capture

| Feature | Windows | Mac code | Shared in CraCore | Notes and next step |
|---|---|---|---|---|
| Capture (`capturePage`): copy the page | 🟡 [#17] | `CaptureOverlay.swift`, `ViewSnapshot.swift` | `PageCapture`, `ContentCapture` | Windows copies the visible page or the full page. Missing: Arc's element pick and region drag with copy, save and send (`ContentCapture`). |
| Picture in Picture (`pictureInPicture`), automatic on leaving a video tab or a Meet call (Document Picture in Picture, upstream #198), throw into corners | ❌ | `PictureInPictureChrome.swift`, `PictureInPictureControls.swift` | `PictureInPictureGesture`, `PictureInPictureThrow` | Gestures and throws are shared. |
| Protected media (DRM services in Safari's engine) | ➖ | `PageEngines.swift`, `WebKitBrowser.swift`, `WebKitStores.swift` | `ProtectedMedia` | Mac only (FairPlay in WebKit). On Windows the counterpart is a Widevine-capable CEF build; the per-site choices in `ProtectedMedia` can be reused. |
| Screen sharing with tab audio, web notifications shown and clicked | 🟡 [#17] | `CraCEF.mm` | `PermissionPrompt` | The prompts work on Windows; Chrome's screen picker and notifications opening their page haven't been checked on the PC. |
| Speech recognition on device | ❌ | `CraCEF.mm` | `ChromiumLocale` | The `speech-on-device` CEF patch is Mac only. |

## Profiles, privacy and site data

| Feature | Windows | Mac code | Shared in CraCore | Notes and next step |
|---|---|---|---|---|
| Permission prompts | ✅ [#17] | `CraCEF.mm` | `PermissionPrompt` | |
| Profiles: per-space cookie folders, Set Profile, Change Profile, New Profile, Settings ▸ Profiles | ✅ [#19] | `ProfilesPane.swift`, `ProfileDialogs.swift`, `NewProfileDialog.swift` | `SpaceProfiles`, `DeletedProfiles` | |
| Rebuild profiles from Arc (`rebuildArcProfiles`) | ❌ | `ArcProfileRebuilder.swift` | `ArcProfileRebuild` | Waits for Arc import. |
| Clear Cache, Clear Cookies | ✅ [#17] | `SiteData.swift` | `SiteDataClearing` | |
| Clear Browsing Data (`clearBrowsingData`) | 🟡 | `AppDelegate.swift` | `BrowsingDataClear` | The store side is shared; the command and Chrome's dialog are missing. |
| Ad and tracker blocker | ❌ | `CraContentBlocker.h`, `CraCEF.mm` | | `CraContentBlocker.h` is plain C++ with no Cocoa or CEF: `CraCEFWin.cpp` can include it as is, with the same domain list. |
| Always use secure connections (HTTPS-only), Secure DNS | ❌ | `PrivacyPane.swift`, `SecureDNSSetting.swift` | `SecureDNS` | Both are Chromium prefs; the decisions are shared. |
| Passwords and cookies encrypted with a key of Cra's own | ❌ | `SafeStorage.swift`, `keychain-service-name.patch` | | Windows counterpart: DPAPI, which Chromium uses by default. Confirm the stock CEF build does. |
| Safe Browsing, Web Push | ❌ | `CraCEF.mm`, `safe-browsing-update-interval.patch`, `gcm-enabled.patch` | | Needs Cra's CEF patches on the Windows build (today it uses Spotify's stock build). |
| Passkeys with the platform authenticator | ❌ | `webauthn-keychain-access-group.patch` | | Windows counterpart: Windows Hello, which Chromium uses on Windows. Check it works in CEF. |

## DevTools and Developer Mode

| Feature | Windows | Mac code | Shared in CraCore | Notes and next step |
|---|---|---|---|---|
| DevTools docked in the page's place (`devTools`, `inspectElement`, `jsConsole`), Chrome's dock sides and undocking | ✅ [#20] | `MainWindowController.swift` | `DevToolsToggle` | Moved to CraCore in #20; both apps decide each press with it. |
| Developer Mode for a site (`toggleDeveloperMode`): the striped bar with the full URL edited in place, Copy, Console, Network, Inspect; host and port under the tab's title; the ring round the open tab | ✅ [#22] | `PaneToolbarView.swift`, `SidebarRowViews.swift` | `ToolbarComposition`, `DeveloperBar` (`SpaceTheme.developerBar`, `DeveloperStripes`, `DeveloperTabRing`, `OKLab`) | Windows: Ctrl+Shift+D (the Mac's ⌃D is Pin Tab there). The bar's colours, stripes and ring moved to CraCore in #22 for both apps. Not in a split, as on the Mac; Windows has no normal toolbar yet, so a split pane shows no bar. |
| Performance recorder, Settings ▸ Performance, Export Diagnostics | ❌ | `PerformancePane.swift`, `Perf.swift`, `PerfCEF.swift`, `PerfFiles.swift`, `PerfRecorder.swift`, `PerfSamplers.swift`, `MainLoopObserver.swift`, `HitchMonitor.swift`, `Diagnostics.swift`, `CraLog.swift` | `PerfHistory`, `PerfInsights`, `PerfMetric`, `PerfProcessTable`, `PerfReport`, `PerfSampleStack`, `PerfSession`, `PerfStall`, `PerfState`, `LogHistogram`, `SiteNames`, `DiagnosticsRedaction`, `DisplayDiagnostics` | The recorder's model is shared; samplers are per platform. `CraLog.swift` is Foundation only: move it to CraCore so both apps log the same way. |

## Extensions

| Feature | Windows | Mac code | Shared in CraCore | Notes and next step |
|---|---|---|---|---|
| Install from the Chrome Web Store or a folder, Extensions menu | ❌ | `ExtensionStore.swift`, `ExtensionsMenu.swift`, `ExtensionLaunch.swift` | `ExtensionProfiles`, `ExtensionPagePlacement`, `ExtensionPageRetry` | Phase 2 items 12 and 13. `ExtensionLaunch.swift` is a known exception: move it. |
| Toolbar and pinned buttons, popups, badges, live icons | ❌ | `ExtensionActions.swift`, `ExtensionPopupWindow.swift`, `ExtensionPopupCandidate.swift` | `ExtensionActionState`, `ExtensionBadge`, `PinnedExtensions`, `PinnedExtensionGrid`, `ToolbarExtensionFit`, `DismissingClick`, `FirstClick` | The extension CEF patches (`extension-popup-browser-info.patch` and the others) need the Windows CEF build too. |
| Extension side panels (MetaMask) | ❌ | `ExtensionSidePanel.swift` | `ExtensionSidePanel` | |
| Native messaging hosts (1Password and others) | ❌ | `NativeMessagingHosts.swift`, `ExtensionProtocolReply.swift` | `ExtensionProxyControl` | Windows reads hosts from the registry, not folders. Both files are Foundation only: move the shared part to CraCore. |
| Settings ▸ Extensions | ❌ | `ExtensionsPane.swift` | | |

## Settings

| Feature | Windows | Mac code | Shared in CraCore | Notes and next step |
|---|---|---|---|---|
| Settings window, back and forward, panes listed by `SettingsPane.windowsPanes` | ✅ [#14] | `SettingsWindowController.swift`, `SettingsKit.swift` | `SettingsNavigation`, `SettingsMetrics` | Panes not on Windows yet: `max`, `privacy`, `extensions`, `performance`, `advanced`. |
| General | 🟡 [#14] | `GeneralPane.swift`, `AppIconPicker.swift` | | Windows has Open at login. Missing: default browser, app icon picker (a taskbar icon on Windows). |
| Tabs | ✅ [#14] | `TabsPane.swift` | `SidebarModel` | New Tab placement, single-space header, tab cleanup. Missing rows arrive with their features (links, sleeping, shared favorites). |
| Shortcuts | ✅ [#15] | `ShortcutsPane.swift` | `KeyBindings` | |
| Profiles | ✅ [#19] | `ProfilesPane.swift` | `SpaceProfiles` | |
| Privacy | ❌ | `PrivacyPane.swift` | `SecureDNS` | With the blocker and HTTPS-only. |
| Extensions | ❌ | `ExtensionsPane.swift` | | |
| Advanced: engine, export bookmarks, versions | ❌ | `AdvancedPane.swift`, `SidebarExport.swift` | | The bookmarks-file writer in `SidebarExport.swift` can move to CraCore; the save dialog stays per platform. |
| Max, Performance | ❌ | `MaxPane.swift`, `PerformancePane.swift` | | See Arc Max and DevTools. |

## Import and onboarding

| Feature | Windows | Mac code | Shared in CraCore | Notes and next step |
|---|---|---|---|---|
| Import from Arc and Dia: spaces, pinned, folders, favorites, archive, profiles (`importData`) | ❌ | `Importers.swift`, `DiaSidebar.swift`, `BrowserSources.swift` | `ArcThemeImport`, `ExtensionProfiles` | Phase 2 item 10. CLAUDE.md lists `Services/Import/` as a known exception: the parsers move to CraCore with this PR; only paths (`%LOCALAPPDATA%`) and icons stay per platform. |
| Import from Chrome, Edge, Brave, Opera, Vivaldi, Helium: tabs, bookmarks, history, extensions | ❌ | `ChromiumImporter.swift`, `ExtensionImporter.swift` | | Same move. |
| Passwords and sign-ins | ❌ | `CredentialImport.swift` | | Windows decrypts with DPAPI and AES-GCM (BCrypt) instead of the Keychain. |
| Firefox and Zen | ❌ | `FirefoxImporter.swift`, `ZenImporter.swift` | | Same move. |
| Safari | ➖ | `SafariImporter.swift` | | No Safari on Windows. |
| Onboarding: import, theme colour, address bar placement | ❌ | `ImportFlow.swift`, `ImportFlowArt.swift`, `ImportFlowViews.swift`, `OnboardingSteps.swift` | | Phase 2 item 11, after import. |

## Arc Max (on-device AI)

| Feature | Windows | Mac code | Shared in CraCore | Notes and next step |
|---|---|---|---|---|
| Tidy Tabs | ➖ | `TidyTabsService.swift` | `TidyTabs` | Runs on Apple Intelligence; Cra sends nothing to a server. A Windows counterpart would need an on-device model (Windows AI APIs on Copilot+ PCs); the prompts and parsing in CraCore can be reused. |
| Tidy Tab Titles (and Arc's rules for 52 sites) | ➖ | `TidyTitlesService.swift` | `TidyTitles`, `TidyTitleRules`, `TidyTitleRules+Data` | The rule-based titles need no model and could ship on Windows on their own. |
| Tidy Downloads | ➖ | `TidyDownloadsService.swift` | `TidyDownloads` | As Tidy Tabs. |

## System integration and release

| Feature | Windows | Mac code | Shared in CraCore | Notes and next step |
|---|---|---|---|---|
| Open at login | ✅ [#14] | `SystemIntegration.swift` | | Windows: the Run key. |
| Default browser (`setDefaultBrowser`), opening links from other apps | ❌ | `SystemIntegration.swift` | | Registry registration under Default Apps. Phase 2 item 9. |
| `cra://` scheme for scripting (`cra://open?space=`) | ❌ | `AppDelegate.swift`, `TestGesture.swift` | | |
| Auto-update (`checkForUpdates`), update banner | ❌ | `SoftwareUpdater.swift`, `UpdateBanner.swift`, `UpdaterWindow.swift` | | WinSparkle reads the same appcast. Phase 3. |
| Signed installer | ❌ | | | Authenticode and MSIX or Inno Setup. Phase 3. |
| Custom app icon | ❌ | `AppIconManager.swift` | | |
| Bluetooth device cache for Chromium | ➖ | `ChromiumBluetoothCache.swift` | | Mac only (CoreBluetooth). |
| Chromium follows the system language | ❌ | `AppDelegate.swift` | `ChromiumLocale` | Shared decision; Windows passes the user's UI language. |
| Shortcuts set in the system's keyboard settings work in pages | ➖ | `AppDelegate.swift` | | macOS only. |
| Feature flags | ❌ | `FeatureFlags.swift` | | |
| Persistence of the data folder | ✅ [#5] | `Persistence.swift`, `SidebarStore+App.swift`, `Scheduler.swift` | `JSONStore`, `Scheduling`, `SidebarStore` | `%LOCALAPPDATA%\Cra` holds the same files. Keep both versions of `Persistence.swift` in step: Mac tests compile it with CraCore. |
| Portability helpers, CraCore seen by every Mac file | ✅ [#1] [#16] | `CraCoreExports.swift` | `CGVector+Portable`, `ChromiumLocale` | |

## Moving Mac code into CraCore

Code that decides something without a window, written once for both apps. In order of what
the next Windows PRs need:

1. `FloatingSidebarGeometry.swift` (hidden sidebar): a CLAUDE.md known exception, already
   Foundation only. (`DevToolsToggle` moved in #20.)
2. `Services/Import/` parsers (Import PR): replace `NSImage` with PNG `Data` and the
   `~/Library` paths with a passed-in root, keep the Mac's fixture tests.
3. `GitHubLiveClient.swift`, `PageScript.swift`, `CraLog.swift`, `NativeMessagingHosts.swift`,
   `ExtensionProtocolReply.swift`, `SearchSuggestLoader.swift`: Foundation only today.
4. `EmojiCatalog+Data.swift`: data with no imports, for the space icon picker.
5. The bookmarks writer in `SidebarExport.swift` and the domain list behind `CraContentBlocker.h`
   (a header both C++ bridges can include).

Windows code that repeats Mac logic instead of calling CraCore is a bug to fix the same way.

## Waiting in upstream

Upstream commits after the fork's last sync (dd8ae64, in #23), triaged:

| Commit | What | Windows |
|---|---|---|
| 030f789 | Copy URL is reserved before the page (#194); ⇧⌘V Paste and Match Style reaches Chromium pages (#192) | Nothing to do: every Windows shortcut is taken before the page, and Ctrl+Shift+V is Chromium's own paste as plain text. |
| dd8ae64 | Leaving a Google Meet call's tab opens its Document Picture in Picture window (#198) | With the Picture in Picture row (`BrowserManager.swift`, `PageScript.swift`). |

## Keeping this current

- **Each upstream sync** (CONTRIBUTING's merge before each new PR): run
  `python3 -I Windows/scripts/parity.py report --upstream upstream/main`, add or update a row for
  each new feature, file and command, triage the commits under Waiting in upstream, and move the
  `upstream-reviewed` marker to the newest upstream commit you read. The weekly
  `upstream-drift.yml` puts the same report in its summary.
- **Each Windows PR**: change its rows (status and PR link) in the same PR.
- **CI** (`upstream-drift.yml` on pull requests) runs `parity.py check`: it fails when a Mac
  file, CraCore file, Mac command or Settings pane has no row, or when main has merged upstream
  commits newer than the marker. It warns when `Windows/Sources` changed and this file didn't.

[#1]: https://github.com/vishnu597/cra-windows/pull/1
[#2]: https://github.com/vishnu597/cra-windows/pull/2
[#3]: https://github.com/vishnu597/cra-windows/pull/3
[#5]: https://github.com/vishnu597/cra-windows/pull/5
[#8]: https://github.com/vishnu597/cra-windows/pull/8
[#9]: https://github.com/vishnu597/cra-windows/pull/9
[#10]: https://github.com/vishnu597/cra-windows/pull/10
[#11]: https://github.com/vishnu597/cra-windows/pull/11
[#12]: https://github.com/vishnu597/cra-windows/pull/12
[#13]: https://github.com/vishnu597/cra-windows/pull/13
[#14]: https://github.com/vishnu597/cra-windows/pull/14
[#15]: https://github.com/vishnu597/cra-windows/pull/15
[#16]: https://github.com/vishnu597/cra-windows/pull/16
[#17]: https://github.com/vishnu597/cra-windows/pull/17
[#18]: https://github.com/vishnu597/cra-windows/pull/18
[#19]: https://github.com/vishnu597/cra-windows/pull/19
[#20]: https://github.com/vishnu597/cra-windows/pull/20
[#21]: https://github.com/vishnu597/cra-windows/pull/21
[#22]: https://github.com/vishnu597/cra-windows/pull/22
[#23]: https://github.com/vishnu597/cra-windows/pull/23
