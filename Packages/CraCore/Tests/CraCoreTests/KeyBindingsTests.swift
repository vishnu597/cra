import CraCore
import Foundation
import Testing

@MainActor
struct KeyBindingsTests {
    private static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cra-keybindings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func registry(_ defaults: [KeyAction] = KeyBindingDefaults.mac, in dir: URL) -> KeyBindingRegistry {
        KeyBindingRegistry(defaults: defaults, file: JSONStore("keybindings.json", in: dir))
    }

    private static func chord(_ key: String, _ mods: KeyChord.Modifiers) -> KeyChord { KeyChord(key, mods) }

    // MARK: Defaults

    @Test func actionIdsAreUnique() {
        for table in [KeyBindingDefaults.mac, KeyBindingDefaults.windows] {
            #expect(Set(table.map(\.id)).count == table.count)
        }
    }

    /// Arc's keys on the Mac, kept as they were when the table lived in the app.
    @Test func macKeepsArcsKeys() {
        let mac = Dictionary(uniqueKeysWithValues: KeyBindingDefaults.mac.map { ($0.id, $0) })
        #expect(mac["newTab"]?.shortcuts == [Self.chord("t", .command)])
        #expect(mac["zoomIn"]?.shortcuts == [Self.chord("=", .command), Self.chord("=", [.command, .shift])])
        #expect(mac["recentTab"]?.shortcuts == [Self.chord(KeyChord.tab, .control)])
        #expect(mac["space3"]?.shortcuts == [Self.chord("3", .control)])
        #expect(mac["moveTabToSpace9"]?.shortcuts == [Self.chord("9", [.command, .control])])
        #expect(mac["clearBrowsingData"]?.symbol == "trash")
        #expect(mac["newWindow"]?.inCommandBar == false)
        // 72 commands (Language Settings came with #209, Blank Window with #220) and 27 numbered ones.
        #expect(KeyBindingDefaults.mac.count == 72 + 27)
    }

    /// Windows' table names only actions the Mac has, in the Mac's order, and its keys don't
    /// collide or use the Windows key.
    @Test func windowsTableFollowsTheMacs() {
        let macIDs = KeyBindingDefaults.mac.map(\.id)
        #expect(Set(KeyBindingDefaults.windowsShortcuts.keys).isSubset(of: Set(macIDs)))
        #expect(KeyBindingDefaults.windows.count == KeyBindingDefaults.windowsShortcuts.count)
        #expect(KeyBindingDefaults.windows.map(\.id) == macIDs.filter { KeyBindingDefaults.windowsShortcuts[$0] != nil })
        let chords = KeyBindingDefaults.windows.flatMap(\.shortcuts)
        #expect(Set(chords).count == chords.count)
        #expect(!chords.contains { $0.keys.contains(.command) })
        let win = Dictionary(uniqueKeysWithValues: KeyBindingDefaults.windows.map { ($0.id, $0) })
        #expect(win["newTab"]?.name == "New Tab…" && win["newTab"]?.triggers == ["new tab"])
        #expect(win["goBack"]?.shortcuts == [Self.chord(KeyChord.left, .option)])
        #expect(win["reload"]?.shortcuts.map(\.windowsDisplay) == ["Ctrl+R", "F5"])
        #expect(win["item9"]?.primary?.windowsDisplay == "Ctrl+9")
        #expect(win["space3"]?.primary?.windowsDisplay == "Alt+3")
        #expect(win["nextSpace"]?.primary?.windowsDisplay == "Ctrl+Alt+Right")
        #expect(win["copyURL"]?.primary?.windowsDisplay == "Ctrl+Shift+C")
        #expect(win["copyURLMarkdown"]?.primary?.windowsDisplay == "Ctrl+Alt+Shift+C")
        #expect(win["capturePage"]?.primary?.windowsDisplay == "Ctrl+Shift+2")
        #expect(win["newIncognitoWindow"]?.primary?.windowsDisplay == "Ctrl+Shift+N")
        #expect(win["closeWindow"]?.primary?.windowsDisplay == "Ctrl+Shift+W")
        #expect(win["clearCookies"]?.shortcuts == [])
        #expect(win["changeProfile"]?.shortcuts == [] && win["changeProfile"]?.inCommandBar == true)
        #expect(win["devTools"]?.shortcuts.map(\.windowsDisplay) == ["Ctrl+Shift+I", "F12"])
        #expect(win["jsConsole"]?.primary?.windowsDisplay == "Ctrl+Shift+J")
        #expect(win["toggleDeveloperMode"]?.primary?.windowsDisplay == "Ctrl+Shift+D")
        #expect(win["inspectElement"]?.shortcuts == [])
    }

    @Test func everyActionHasADescription() {
        for a in KeyBindingDefaults.mac where !a.id.hasPrefix("item") && !a.id.hasPrefix("space") && !a.id.hasPrefix("moveTabToSpace") {
            #expect(ShortcutDescriptions.text(for: a) != a.name + ".", "\(a.id)")
        }
        let mac = Dictionary(uniqueKeysWithValues: KeyBindingDefaults.mac.map { ($0.id, $0) })
        #expect(ShortcutDescriptions.text(for: mac["item2"]!) == "Switch to the 2. tab in the sidebar.")
        #expect(ShortcutDescriptions.text(for: mac["space4"]!) == "Switch to the 4. space.")
        #expect(ShortcutDescriptions.text(for: mac["moveTabToSpace5"]!).hasPrefix("Move the current tab"))
        #expect(ShortcutDescriptions.text(for: KeyAction(id: "x", name: "Something", section: .none, shortcuts: [])) == "Something.")
    }

    // MARK: Registry

    @Test func overridesFromTheFileApply() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"newTab":[{"key":"y","modifiers":1048576}],"gone":[]}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("keybindings.json"))
        let r = Self.registry(in: dir)
        #expect(r.action("newTab")?.shortcuts == [Self.chord("y", .command)])
        #expect(r.isOverridden("newTab") && !r.isOverridden("closeTab"))
        #expect(r.action("gone") == nil)
        #expect(r.action(matching: Self.chord("y", .command))?.id == "newTab")
        #expect(r.action(matching: Self.chord("t", .command)) == nil)
    }

    @Test func settingResettingAndSaving() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("keybindings.json")
        try Data(#"{"gone":[{"key":"q","modifiers":262144}]}"#.utf8).write(to: file)
        let r = Self.registry(KeyBindingDefaults.windows, in: dir)
        let alt = Self.chord("n", .option)
        r.setShortcuts([alt], for: "newTab")
        #expect(r.action("newTab")?.shortcuts == [alt])
        #expect(r.isOverridden("newTab"))
        // Saved after JSONStore's short debounce, with the override this table lacks.
        var saved: [String: [KeyChord]] = [:]
        for _ in 0..<40 where saved["newTab"] == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            saved = (try? JSONDecoder().decode([String: [KeyChord]].self, from: Data(contentsOf: file))) ?? [:]
        }
        #expect(saved["newTab"] == [alt] && saved["gone"] == [Self.chord("q", .control)])

        r.setShortcuts([], for: "closeTab")
        #expect(r.action("closeTab")?.shortcuts == [])
        r.resetShortcuts(for: "closeTab")
        #expect(r.action("closeTab")?.shortcuts == [Self.chord("w", .control)])
        #expect(!r.isOverridden("closeTab"))

        r.resetOverrides()
        #expect(r.actions == KeyBindingDefaults.windows)
        #expect(try JSONDecoder().decode([String: [KeyChord]].self, from: Data(contentsOf: file)).isEmpty)
    }

    /// Caps Lock and the function-key bit don't keep a key from matching.
    @Test func matchingLooksAtTheFourKeys() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Self.registry(KeyBindingDefaults.windows, in: dir)
        #expect(r.action(matching: KeyChord(key: "t", modifiers: KeyChord.Modifiers.control.rawValue | 0x10000))?.id == "newTab")
        #expect(r.action(matching: Self.chord("t", [.control, .shift]))?.id == "reopenClosedTab")
        #expect(r.action(matching: Self.chord(KeyChord.function(5), []))?.id == "reload")
        #expect(r.action(matching: Self.chord(KeyChord.function(5), .control))?.id == "hardReload")
        #expect(r.action(matching: Self.chord("t", [])) == nil)
    }

    @Test func conflictsAndTheirNote() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Self.registry(KeyBindingDefaults.windows, in: dir)
        #expect(r.conflicts(of: r.action("newTab")!).isEmpty)
        #expect(r.conflicts(of: r.action("separateFromSplit")!).isEmpty)
        #expect(ShortcutsList.conflictNote([]) == nil)
        r.setShortcuts([Self.chord("t", .control)], for: "find")
        #expect(r.conflicts(of: r.action("find")!).map(\.id) == ["newTab"])
        #expect(ShortcutsList.conflictNote(r.conflicts(of: r.action("find")!)) == "This shortcut conflicts with another shortcut: New Tab…")
        r.setShortcuts([Self.chord("t", .control)], for: "settings")
        #expect(ShortcutsList.conflictNote(r.conflicts(of: r.action("find")!))
            == "This shortcut conflicts with other shortcuts: New Tab…, Settings…")
    }

    @Test func commandBarCommandsWriteThePlatformsKeys() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let win = Self.registry(KeyBindingDefaults.windows, in: dir).barCommands(display: \.windowsDisplay)
        #expect(!win.contains { $0.id == "findNext" || $0.id == "item1" })
        #expect(win.first { $0.id == "settings" } == CommandBarCommand(id: "settings", name: "Settings…", triggers: ["preferences", "settings"], shortcut: "Ctrl+,"))
        #expect(win.first { $0.id == "separateFromSplit" }?.shortcut == nil)
        let mac = Self.registry(in: dir).barCommands(display: \.display)
        #expect(mac.first { $0.id == "clearCache" } == CommandBarCommand(id: "clearCache", name: "Clear Cache and Refresh", symbol: "trash"))
        #expect(mac.first { $0.id == "newTab" }?.shortcut == "⌘T")
    }

    // MARK: Shortcuts pane

    @Test func listGroupsByMenuAndFilters() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Self.registry(KeyBindingDefaults.windows, in: dir)
        let all = ShortcutsList.groups(in: r, query: "")
        #expect(all.map(\.title) == ["Cra", "File", "Edit", "View", "Spaces", "Tabs", "Archive", "Window"])  // Window: the Little Window actions
        #expect(all.reduce(0) { $0 + $1.actions.count } == KeyBindingDefaults.windows.count)
        #expect(ShortcutsList.groups(in: r, query: "  SPLIT ").flatMap(\.actions).map(\.id)
            == ["addSplitView", "closeSplitPane", "separateFromSplit", "flipSplitOrientation", "nextSplitPane", "previousSplitPane"])
        #expect(ShortcutsList.groups(in: r, query: "nothing like this").isEmpty)
        #expect(ShortcutsList.groups(in: r, query: "", customizedOnly: true).isEmpty)
        #expect(ShortcutsList.groups(in: r, query: "", conflictingOnly: true).isEmpty)
        r.setShortcuts([Self.chord("t", .control)], for: "find")
        #expect(ShortcutsList.groups(in: r, query: "", customizedOnly: true) == [ShortcutsList.Group(title: "Edit", actions: [r.action("find")!])])
        #expect(ShortcutsList.groups(in: r, query: "", conflictingOnly: true).flatMap(\.actions).map(\.id) == ["newTab", "find"])
    }

    // MARK: Windows keys

    @Test(arguments: [
        (KeyChord("t", .control), "Ctrl+T"),
        (KeyChord("t", [.control, .shift]), "Ctrl+Shift+T"),
        (KeyChord(KeyChord.left, [.control, .option]), "Ctrl+Alt+Left"),
        (KeyChord(KeyChord.right, .option), "Alt+Right"),
        (KeyChord(KeyChord.up, [.command, .control, .option, .shift]), "Win+Ctrl+Alt+Shift+Up"),
        (KeyChord(KeyChord.down, []), "Down"),
        (KeyChord(KeyChord.tab, .control), "Ctrl+Tab"),
        (KeyChord(KeyChord.delete, [.control, .shift]), "Ctrl+Shift+Backspace"),
        (KeyChord(KeyChord.function(5), .control), "Ctrl+F5"),
        (KeyChord(KeyChord.function(12), []), "F12"),
        (KeyChord("=", [.control, .shift]), "Ctrl+Shift+="),
        (KeyChord(",", .control), "Ctrl+,"),
        (KeyChord(key: "d", modifiers: KeyChord.Modifiers.control.rawValue | 0x10000), "Ctrl+D"),
    ])
    func windowsDisplay(chord: KeyChord, shown: String) {
        #expect(chord.windowsDisplay == shown)
    }

    @Test func functionKeysAreAppKits() {
        #expect(KeyChord.function(1).unicodeScalars.map(\.value) == [0xF704])
        #expect(KeyChord.function(19).unicodeScalars.map(\.value) == [0xF716])
        #expect(KeyChord(KeyChord.function(3), []).functionNumber == 3)
        #expect(KeyChord("a", []).functionNumber == nil)
        #expect(KeyChord(KeyChord.left, []).functionNumber == nil)
        #expect(KeyChord(KeyChord.function(3), []).display == KeyChord.function(3))
    }

    @Test(arguments: [
        (Int32(0x54), false, false, false, KeyChord("t", [])),                         // T
        (0x54, true, true, false, KeyChord("t", [.control, .shift])),
        (0x31, true, false, false, KeyChord("1", .control)),                          // 1
        (0x63, true, false, false, KeyChord("3", .control)),                          // the keypad's 3
        (0xBB, true, true, false, KeyChord("=", [.control, .shift])),                 // VK_OEM_PLUS
        (0xBD, true, false, false, KeyChord("-", .control)),
        (0xBC, true, false, false, KeyChord(",", .control)),
        (0xBE, false, false, true, KeyChord(".", .option)),
        (0xBF, true, false, false, KeyChord("/", .control)),
        (0xBA, true, false, false, KeyChord(";", .control)),
        (0xDE, true, false, false, KeyChord("'", .control)),
        (0xC0, true, false, false, KeyChord("`", .control)),
        (0xDB, true, false, false, KeyChord("[", .control)),
        (0xDC, true, false, false, KeyChord("\\", .control)),
        (0xDD, true, false, false, KeyChord("]", .control)),
        (0x09, true, true, false, KeyChord(KeyChord.tab, [.control, .shift])),
        (0x25, false, false, true, KeyChord(KeyChord.left, .option)),
        (0x26, true, false, true, KeyChord(KeyChord.up, [.control, .option])),
        (0x27, false, false, true, KeyChord(KeyChord.right, .option)),
        (0x28, false, false, false, KeyChord(KeyChord.down, [])),
        (0x08, true, true, false, KeyChord(KeyChord.delete, [.control, .shift])),
        (0x70, false, false, false, KeyChord(KeyChord.function(1), [])),               // F1
        (0x74, true, false, false, KeyChord(KeyChord.function(5), .control)),         // F5
    ])
    func virtualKeys(vk: Int32, control: Bool, shift: Bool, alt: Bool, chord: KeyChord) {
        #expect(KeyChord(windowsVirtualKey: vk, control: control, shift: shift, alt: alt) == chord)
    }

    @Test func keysNoShortcutUses() {
        for vk: Int32 in [0x10, 0x11, 0x12, 0x1B, 0x0D, 0x20, 0x5B, 0xFF] {   // Shift, Ctrl, Alt, Esc, Enter, Space, Win
            #expect(KeyChord(windowsVirtualKey: vk, control: true, shift: false, alt: false) == nil)
        }
        #expect(KeyChord(windowsVirtualKey: 0x54, control: false, shift: false, alt: false, windows: true) == KeyChord("t", .command))
    }

    /// Recording: a character needs Ctrl, Alt or Win; Tab, the arrows and F-keys don't.
    @Test func recordingNeedsAModifierForCharacters() {
        #expect(KeyChord.recorded(windowsVirtualKey: 0x54, control: false, shift: false, alt: false) == nil)
        #expect(KeyChord.recorded(windowsVirtualKey: 0x54, control: false, shift: true, alt: false) == nil)
        #expect(KeyChord.recorded(windowsVirtualKey: 0x54, control: true, shift: false, alt: false) == KeyChord("t", .control))
        #expect(KeyChord.recorded(windowsVirtualKey: 0x54, control: false, shift: false, alt: true) == KeyChord("t", .option))
        #expect(KeyChord.recorded(windowsVirtualKey: 0x54, control: false, shift: false, alt: false, windows: true) == KeyChord("t", .command))
        #expect(KeyChord.recorded(windowsVirtualKey: 0x72, control: false, shift: false, alt: false) == KeyChord(KeyChord.function(3), []))
        #expect(KeyChord.recorded(windowsVirtualKey: 0x25, control: false, shift: true, alt: false) == KeyChord(KeyChord.left, .shift))
        #expect(KeyChord.recorded(windowsVirtualKey: 0x09, control: false, shift: false, alt: false) == KeyChord(KeyChord.tab, []))
        #expect(KeyChord.recorded(windowsVirtualKey: 0x1B, control: true, shift: false, alt: false) == nil)
        #expect(KeyChord(KeyChord.right, []).isSpecialKey && !KeyChord(KeyChord.delete, []).isSpecialKey)
    }
}
