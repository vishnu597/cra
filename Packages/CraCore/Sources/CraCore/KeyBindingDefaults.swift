import Foundation

/// The actions and their default shortcuts on each platform.
public enum KeyBindingDefaults {
    // Arc's defaults, read from Arc 1.168's menu bar on this Mac (see
    // docs/arc-reverse-engineering.md, "Key bindings"). Items Cra doesn't
    // have (Little Arc, Easels, Split View, Capture) are left out.
    public static let mac: [KeyAction] = {
        let cmd: KeyChord.Modifiers = .command
        let cmdShift: KeyChord.Modifiers = [.command, .shift]
        let cmdOpt: KeyChord.Modifiers = [.command, .option]
        let cmdOptShift: KeyChord.Modifiers = [.command, .option, .shift]
        var list: [KeyAction] = [
            // File
            KeyAction(id: "newTab", name: "New Tab…", section: .file, shortcuts: [KeyChord("t", cmd)], triggers: ["new tab"]),
            KeyAction(id: "newWindow", name: "New Window", section: .file, shortcuts: [KeyChord("n", cmd)], inCommandBar: false),
            KeyAction(id: "newIncognitoWindow", name: "New Incognito Window", section: .file, shortcuts: [KeyChord("n", cmdShift)],
                      triggers: ["incognito", "private"]),
            // Arc: File ▸ New Little Arc Window ⌥⌘N.
            KeyAction(id: "newLittleWindow", name: "New Little Window", section: .file, shortcuts: [KeyChord("n", cmdOpt)], triggers: ["little window", "little arc"]),
            KeyAction(id: "reopenClosedTab", name: "Restore Last Closed Tab", section: .file, shortcuts: [KeyChord("t", cmdShift)], triggers: ["reopen", "undo close", "restore"]),
            KeyAction(id: "editURL", name: "Open Command Bar", section: .file, shortcuts: [KeyChord("l", cmd)], triggers: ["url", "address", "command bar"]),
            KeyAction(id: "newFolder", name: "New Folder", section: .file, shortcuts: [], triggers: ["folder"]),
            KeyAction(id: "newGitHubLiveFolder", name: "New GitHub Live Folder", section: .file, shortcuts: [],
                      triggers: ["live folder", "pull requests", "github"]),
            KeyAction(id: "newSpace", name: "New Space…", section: .file, shortcuts: [], triggers: ["space"]),
            KeyAction(id: "closeWindow", name: "Close Window", section: .file, shortcuts: [KeyChord("w", cmdShift)], inCommandBar: false),
            KeyAction(id: "closeTab", name: "Close Tab", section: .file, shortcuts: [KeyChord("w", cmd)], triggers: ["close", "archive tab"]),
            KeyAction(id: "capturePage", name: "Capture…", section: .file, shortcuts: [KeyChord("2", cmdShift)], triggers: ["capture", "screenshot"]),
            KeyAction(id: "print", name: "Print", section: .file, shortcuts: [KeyChord("p", cmd)]),
            // Edit
            KeyAction(id: "copyURL", name: "Copy URL", section: .edit, shortcuts: [KeyChord("c", cmdShift)], triggers: ["copy link"]),
            KeyAction(id: "copyURLMarkdown", name: "Copy URL as Markdown", section: .edit, shortcuts: [KeyChord("c", cmdOptShift)], triggers: ["markdown"]),
            KeyAction(id: "find", name: "Find…", section: .edit, shortcuts: [KeyChord("f", cmd)], triggers: ["find", "search page"]),
            KeyAction(id: "findNext", name: "Find Next", section: .edit, shortcuts: [KeyChord("g", cmd)], inCommandBar: false),
            KeyAction(id: "findPrevious", name: "Find Previous", section: .edit, shortcuts: [KeyChord("g", cmdShift)], inCommandBar: false),
            // View
            KeyAction(id: "toggleSidebar", name: "Hide Sidebar", section: .view, shortcuts: [KeyChord("s", cmd)], triggers: ["sidebar", "hide sidebar", "show sidebar"]),
            KeyAction(id: "toggleToolbar", name: "Hide Toolbar", section: .view, shortcuts: [KeyChord("d", cmdShift)], triggers: ["toolbar"]),
            KeyAction(id: "stop", name: "Stop Loading", section: .view, shortcuts: [KeyChord(".", cmd)], inCommandBar: false),
            KeyAction(id: "reload", name: "Refresh the Page", section: .view, shortcuts: [KeyChord("r", cmd)], triggers: ["refresh", "reload"]),
            KeyAction(id: "hardReload", name: "Force Refresh the Page", section: .view, shortcuts: [KeyChord("r", cmdShift)]),
            // Arc's command bar (1.171): "clear" lists both, cache first, with a trash glyph.
            KeyAction(id: "clearCache", name: "Clear Cache and Refresh", section: .view, shortcuts: [], symbol: "trash"),
            KeyAction(id: "clearCookies", name: "Clear Cookies and Refresh", section: .view, shortcuts: [], symbol: "trash"),
            // Arc: View ▸ Developer ▸ "Turn on/off Developer Mode for this site" (⌃D).
            KeyAction(id: "toggleDeveloperMode", name: "Toggle Developer Mode for this Site", section: .view, shortcuts: [KeyChord("d", .control)], triggers: ["developer mode", "dev mode"]),
            KeyAction(id: "resetZoom", name: "Zoom to Actual Size", section: .view, shortcuts: [KeyChord("0", cmd)], triggers: ["reset zoom"]),
            KeyAction(id: "zoomIn", name: "Zoom In", section: .view, shortcuts: [KeyChord("=", cmd), KeyChord("=", cmdShift)]),
            KeyAction(id: "zoomOut", name: "Zoom Out", section: .view, shortcuts: [KeyChord("-", cmd)]),
            KeyAction(id: "viewSource", name: "View Source", section: .view, shortcuts: [KeyChord("u", cmdOpt)]),
            KeyAction(id: "devTools", name: "Developer Tools", section: .view, shortcuts: [KeyChord("i", cmdOpt)], triggers: ["devtools", "inspect", "console"]),
            KeyAction(id: "inspectElement", name: "Inspect Elements", section: .view, shortcuts: [KeyChord("c", cmdOpt)], inCommandBar: false),
            KeyAction(id: "jsConsole", name: "JavaScript Console", section: .view, shortcuts: [KeyChord("j", cmdOpt)], inCommandBar: false),
            // Arc: Extensions ▸ Picture in Picture (no shortcut); "Open Picture in Picture" in the command bar.
            KeyAction(id: "pictureInPicture", name: "Picture in Picture", section: .view, shortcuts: [], triggers: ["pip", "picture in picture", "pop out", "popout", "video"]),
            // Arc: View ▸ Add Split View ⌃⇧=, Close this Split Pane ⌃⇧-, Separate Page from Split View, Expand Current Split.
            KeyAction(id: "addSplitView", name: "Add Split View", section: .view, shortcuts: [KeyChord("=", [.control, .shift])], triggers: ["split", "split view", "add split"]),
            KeyAction(id: "closeSplitPane", name: "Close this Split Pane", section: .view, shortcuts: [KeyChord("-", [.control, .shift])], triggers: ["close split", "close pane"]),
            KeyAction(id: "separateFromSplit", name: "Separate Page from Split View", section: .view, shortcuts: [], triggers: ["separate", "unsplit"]),
            KeyAction(id: "flipSplitOrientation", name: "Flip Split View Orientation", section: .view, shortcuts: [], triggers: ["vertical split", "horizontal split", "flip split"]),
            KeyAction(id: "nextSplitPane", name: "Switch to Next Split View", section: .view, shortcuts: [], inCommandBar: false),
            KeyAction(id: "previousSplitPane", name: "Switch to Previous Split View", section: .view, shortcuts: [], inCommandBar: false),
            // Spaces
            KeyAction(id: "nextSpace", name: "Next Space", section: .spaces, shortcuts: [KeyChord(KeyChord.right, cmdOpt)], inCommandBar: false),
            KeyAction(id: "previousSpace", name: "Previous Space", section: .spaces, shortcuts: [KeyChord(KeyChord.left, cmdOpt)], inCommandBar: false),
            KeyAction(id: "editSpace", name: "Edit Space…", section: .spaces, shortcuts: [], triggers: ["theme", "color", "emoji", "edit space"]),
            KeyAction(id: "changeProfile", name: "Change Profile", section: .spaces, shortcuts: [], triggers: ["profile", "change profile", "set profile"]),
            KeyAction(id: "deleteSpace", name: "Delete Space…", section: .spaces, shortcuts: [], triggers: ["delete space", "remove space"]),
            KeyAction(id: "manageSpaces", name: "Manage Spaces…", section: .spaces, shortcuts: [], triggers: ["manage spaces", "reorder spaces"]),
            // Tabs
            KeyAction(id: "pinTab", name: "Pin/Unpin Tab", section: .tabs, shortcuts: [KeyChord("d", cmd)], triggers: ["pin", "unpin"]),
            KeyAction(id: "nextTab", name: "Next Tab", section: .tabs, shortcuts: [KeyChord(KeyChord.down, cmdOpt)], inCommandBar: false),
            KeyAction(id: "previousTab", name: "Previous Tab", section: .tabs, shortcuts: [KeyChord(KeyChord.up, cmdOpt)], inCommandBar: false),
            KeyAction(id: "recentTab", name: "Next Recent Tab", section: .tabs, shortcuts: [KeyChord(KeyChord.tab, .control)], inCommandBar: false),
            KeyAction(id: "recentTabBackward", name: "Previous Recent Tab", section: .tabs, shortcuts: [KeyChord(KeyChord.tab, [.control, .shift])], inCommandBar: false),
            KeyAction(id: "clearToday", name: "Clear Today", section: .tabs, shortcuts: [KeyChord("k", cmdShift)], triggers: ["clear", "tidy"]),
            KeyAction(id: "favoriteTab", name: "Add to Favorites", section: .tabs, shortcuts: [], triggers: ["favorite", "top app"]),
            KeyAction(id: "renameTab", name: "Rename Tab…", section: .tabs, shortcuts: [], triggers: ["rename"]),
            KeyAction(id: "duplicateTab", name: "Duplicate Tab", section: .tabs, shortcuts: [], triggers: ["duplicate"]),
            KeyAction(id: "resetTab", name: "Reset Pinned Tab", section: .tabs, shortcuts: [], triggers: ["reset", "home"]),
            KeyAction(id: "muteTab", name: "Mute / Unmute Tab", section: .tabs, shortcuts: [], triggers: ["mute"]),
            // Archive
            KeyAction(id: "goBack", name: "Go Back", section: .archive, shortcuts: [KeyChord("[", cmd), KeyChord(KeyChord.left, cmd)]),
            KeyAction(id: "goForward", name: "Go Forward", section: .archive, shortcuts: [KeyChord("]", cmd), KeyChord(KeyChord.right, cmd)]),
            KeyAction(id: "viewArchive", name: "View History", section: .archive, shortcuts: [KeyChord("y", cmd)], triggers: ["archive", "history", "closed tabs"]),
            // Window
            KeyAction(id: "openLibrary", name: "Open Library…", section: .window, shortcuts: [KeyChord("l", cmdShift)], triggers: ["library"]),
            KeyAction(id: "viewDownloads", name: "View Downloads…", section: .window, shortcuts: [KeyChord("j", cmdShift)], triggers: ["downloads"]),
            // Arc's Little Arc "Open in Space" button (LittleBrowserMoveButton) and "Close Little Arc Windows".
            KeyAction(id: "promoteLittleWindow", name: "Open Little Window in Space", section: .window, shortcuts: [KeyChord("o", cmd)], inCommandBar: false),
            KeyAction(id: "closeLittleWindows", name: "Close Little Windows", section: .window, shortcuts: [], triggers: ["close little"]),
            // App
            KeyAction(id: "settings", name: "Settings…", section: .app, shortcuts: [KeyChord(",", cmd)], triggers: ["preferences", "settings"]),
            // Arc's app menu shows ⌘♡ beside it, a glyph no key types (see buildMenus).
            KeyAction(id: "setDefaultBrowser", name: "Set as Default Browser", section: .app, shortcuts: [], triggers: ["default browser"]),
            KeyAction(id: "importData", name: "Import from Arc or Dia…", section: .app, shortcuts: [], triggers: ["import", "arc", "dia"]),
            KeyAction(id: "rebuildArcProfiles", name: "Rebuild Profiles from Arc…", section: .app, shortcuts: [], triggers: ["profiles", "arc profiles"]),
            // Chrome's app menu item and key; Arc has neither, only Settings ▸ Profiles ▸ Clear Browsing Data.
            KeyAction(id: "clearBrowsingData", name: "Clear Browsing Data…", section: .app, shortcuts: [KeyChord(KeyChord.delete, cmdShift)],
                      triggers: ["clear history", "delete history", "clear browsing data", "delete browsing data"], symbol: "trash"),
            KeyAction(id: "checkForUpdates", name: "Check for Updates…", section: .app, shortcuts: [],
                      triggers: ["update", "upgrade", "new version"], symbol: "arrow.down.circle"),
        ]
        for n in 1...9 {
            list.append(KeyAction(id: "item\(n)", name: "Go to Tab \(n)", section: .tabs,
                                  shortcuts: [KeyChord("\(n)", cmd)], triggers: ["\(n). tab", "\(n). item"], inCommandBar: false))
            list.append(KeyAction(id: "space\(n)", name: "Go to Space \(n)", section: .spaces,
                                  shortcuts: [KeyChord("\(n)", .control)], inCommandBar: false))
        }
        // Arc has no default for this (its command bar's "Move to Today in <space>" has no key);
        // ⌃⌘N adds ⌘ to Go to Space N (#86). Neither Arc nor macOS binds ⌃⌘1–9.
        for n in 1...9 {
            list.append(KeyAction(id: "moveTabToSpace\(n)", name: "Move Tab to Space \(n)", section: .spaces,
                                  shortcuts: [KeyChord("\(n)", [.command, .control])], inCommandBar: false))
        }
        return list
    }()

    /// Windows' table: the Mac's actions the Windows app has so far, in the Mac's order, with
    /// Windows' keys. On Windows a chord's `.control` bit is Ctrl and `.option` is Alt (the keys
    /// the bits are named after); `.command` would be the Windows key, which no default uses.
    /// ⌘ becomes Ctrl, and where that collides or Windows has its own convention the key is
    /// Chrome's on Windows: Alt+Left and Right go back and forward, Ctrl+Tab cycles tabs in
    /// sidebar order (Windows has no tab switcher yet), F3 and F5 keep their meaning.
    public static let windows: [KeyAction] = mac.compactMap { action in
        windowsShortcuts[action.id].map { keys in
            var a = action
            a.shortcuts = keys
            return a
        }
    }

    /// Action id to Windows' default shortcuts. An action joins when the Windows app performs it.
    public static let windowsShortcuts: [String: [KeyChord]] = {
        let ctrl: KeyChord.Modifiers = .control
        let ctrlShift: KeyChord.Modifiers = [.control, .shift]
        let ctrlAlt: KeyChord.Modifiers = [.control, .option]
        let alt: KeyChord.Modifiers = .option
        var table: [String: [KeyChord]] = [
            "newTab": [KeyChord("t", ctrl)],
            "reopenClosedTab": [KeyChord("t", ctrlShift)],
            "editURL": [KeyChord("l", ctrl)],
            "closeTab": [KeyChord("w", ctrl)],
            "capturePage": [KeyChord("2", ctrlShift)],
            "copyURL": [KeyChord("c", ctrlShift)],
            "copyURLMarkdown": [KeyChord("c", [.control, .option, .shift])],
            "find": [KeyChord("f", ctrl)],
            "findNext": [KeyChord("g", ctrl), KeyChord(KeyChord.function(3), [])],
            "findPrevious": [KeyChord("g", ctrlShift), KeyChord(KeyChord.function(3), .shift)],
            "reload": [KeyChord("r", ctrl), KeyChord(KeyChord.function(5), [])],
            "hardReload": [KeyChord("r", ctrlShift), KeyChord(KeyChord.function(5), ctrl)],
            "addSplitView": [KeyChord("=", ctrlShift)],
            "closeSplitPane": [KeyChord("-", ctrlShift)],
            "separateFromSplit": [],
            "flipSplitOrientation": [],
            "nextSplitPane": [],
            "previousSplitPane": [],
            "nextSpace": [KeyChord(KeyChord.right, ctrlAlt)],
            "previousSpace": [KeyChord(KeyChord.left, ctrlAlt)],
            "pinTab": [KeyChord("d", ctrl)],
            "nextTab": [KeyChord(KeyChord.tab, ctrl)],
            "previousTab": [KeyChord(KeyChord.tab, ctrlShift)],
            "goBack": [KeyChord(KeyChord.left, alt)],
            "goForward": [KeyChord(KeyChord.right, alt)],
            "settings": [KeyChord(",", ctrl)],
            "clearCache": [],
            "clearCookies": [],
        ]
        for n in 1...9 { table["item\(n)"] = [KeyChord("\(n)", ctrl)] }
        return table
    }()
}

/// One-line descriptions for the Shortcuts pane's detail column (Dia: "Create a new tab.").
public enum ShortcutDescriptions {
    public static func text(for a: KeyAction) -> String {
        if let t = table[a.id] { return t }
        if a.id.hasPrefix("item"), let n = a.id.dropFirst(4).first { return "Switch to the \(n). tab in the sidebar." }
        if a.id.hasPrefix("space"), let n = a.id.dropFirst(5).first { return "Switch to the \(n). space." }
        if a.id.hasPrefix("moveTabToSpace"), let n = a.id.dropFirst(14).first { return "Move the current tab, or a Little Window's page, to the \(n). space and switch to it." }
        return a.name + "."
    }

    private static let table: [String: String] = [
        "newTab": "Create a new tab.",
        "newWindow": "Open a new window.",
        "newIncognitoWindow": "Open a window that keeps no history, cookies or tabs once closed.",
        "newLittleWindow": "Open a small, disposable window for a quick look.",
        "reopenClosedTab": "Bring back the tab you closed last.",
        "editURL": "Open the command bar to search or enter a URL.",
        "newFolder": "Create a folder in the sidebar.",
        "newGitHubLiveFolder": "Add a folder that fills itself with your open pull requests and review requests.",
        "newSpace": "Create a new space.",
        "closeWindow": "Close the current window.",
        "closeTab": "Close the current tab.",
        "capturePage": "Take a screenshot of the page.",
        "print": "Print the page.",
        "copyURL": "Copy the page’s URL.",
        "copyURLMarkdown": "Copy the page’s title and URL as a Markdown link.",
        "find": "Search for text on the page.",
        "findNext": "Jump to the next match.",
        "findPrevious": "Jump to the previous match.",
        "toggleSidebar": "Show or hide the sidebar.",
        "toggleToolbar": "Show or hide the toolbar above the page.",
        "stop": "Stop loading the page.",
        "reload": "Reload the page.",
        "hardReload": "Reload the page, ignoring cached content.",
        "clearCache": "Clear the browser cache and reload the page.",
        "clearCookies": "Clear this site’s cookies and reload the page.",
        "toggleDeveloperMode": "Show the full URL and developer tools for this site.",
        "resetZoom": "Return the page to its actual size.",
        "zoomIn": "Make the page larger.",
        "zoomOut": "Make the page smaller.",
        "viewSource": "Show the page’s source.",
        "devTools": "Open the developer tools.",
        "inspectElement": "Open the developer tools on the Elements panel.",
        "jsConsole": "Open the developer tools on the Console panel.",
        "pictureInPicture": "Pop the playing video out into a floating window.",
        "addSplitView": "Open another page beside this one.",
        "closeSplitPane": "Close the focused split pane.",
        "separateFromSplit": "Move the page out of the split view into its own tab.",
        "flipSplitOrientation": "Switch the split view between side by side and stacked.",
        "nextSplitPane": "Focus the next split pane.",
        "previousSplitPane": "Focus the previous split pane.",
        "nextSpace": "Switch to the next space.",
        "previousSpace": "Switch to the previous space.",
        "editSpace": "Change the space’s name, emoji and theme.",
        "changeProfile": "Pick the profile the space’s sign-ins, cookies and extensions come from.",
        "deleteSpace": "Delete the current space.",
        "manageSpaces": "Open the Library’s Spaces page: every space side by side, to reorder or edit them.",
        "pinTab": "Pin the tab or unpin it.",
        "nextTab": "Switch to the next tab.",
        "previousTab": "Switch to the previous tab.",
        "recentTab": "Open the tab switcher and cycle through recent tabs, like ⌘Tab for apps.",
        "recentTabBackward": "Cycle backwards through recent tabs in the tab switcher.",
        "clearToday": "Archive all of today’s tabs.",
        "favoriteTab": "Add the tab to the favorites grid.",
        "renameTab": "Give the tab a name of your own.",
        "duplicateTab": "Open a copy of the tab.",
        "resetTab": "Return a pinned tab to its original URL.",
        "muteTab": "Mute or unmute the tab.",
        "goBack": "Go back a page.",
        "goForward": "Go forward a page.",
        "viewArchive": "Open the archive of closed tabs.",
        "openLibrary": "Open the Library.",
        "viewDownloads": "Show your downloads.",
        "promoteLittleWindow": "Move the Little Window’s page into a space.",
        "closeLittleWindows": "Close all Little Windows.",
        "settings": "Open Settings.",
        "setDefaultBrowser": "Make Cra the default browser.",
        "importData": "Bring tabs, spaces and extensions over from Arc or Dia.",
        "rebuildArcProfiles": "Put spaces imported from Arc back on their Arc profiles, with their sign-ins and extensions.",
        "clearBrowsingData": "Delete history, cookies and cached files with Chrome’s dialog.",
        "checkForUpdates": "Look for a newer version of Cra.",
    ]
}
