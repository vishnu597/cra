import AppKit

/// A keyboard shortcut: CraCore's KeyChord (the keybindings.json format), read from and
/// matched against AppKit key events here.
typealias Shortcut = KeyChord

extension Shortcut {
    init(_ key: String, _ mods: NSEvent.ModifierFlags) {
        self.init(key: key, modifiers: mods.intersection(.deviceIndependentFlagsMask).rawValue)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// The key press an event is, for CraCore's matching (KeyChord.match). Nil for anything but a
    /// key-down: charactersIgnoringModifiers throws on flagsChanged events, which Chromium
    /// forwards as raw key-downs for modifier keys.
    static func press(_ event: NSEvent) -> KeyChord.Press? {
        guard event.type == .keyDown, let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
        return KeyChord.Press(characters: chars, keyCode: event.keyCode,
                              modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
    }

    @MainActor func matches(_ event: NSEvent) -> Bool {
        guard let press = Self.press(event) else { return false }
        return match(press, typable: KeyboardLayoutCharacters.types) != nil
    }

    /// Build a shortcut from a recorded key press (nil for bare letters without ⌘/⌃/⌥).
    static func from(event e: NSEvent) -> Shortcut? {
        guard let chars = press(e)?.key else { return nil }
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let special = [tab, left, right, up, down].contains(chars) || (chars.unicodeScalars.first.map { $0.value >= 0xF704 && $0.value <= 0xF71F } ?? false)
        guard special || !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        return Shortcut(chars, flags)
    }
}

/// The Mac's registry: KeyBindingDefaults.mac with keybindings.json in the data folder, matched
/// against AppKit key events here.
extension KeyBindingRegistry {
    /// The app's one registry (AppDelegate.bindings), for the context menus' shortcut glyphs.
    static let shared = KeyBindingRegistry()

    convenience init() {
        self.init(defaults: KeyBindingDefaults.mac, file: JSONStore("keybindings.json"))
    }

    /// The action a key press runs: the first one whose shortcut it types, else the first one
    /// whose key sits where the press's does (KeyChord.first).
    func action(for event: NSEvent) -> KeyAction? {
        guard let press = Shortcut.press(event) else { return nil }
        return KeyChord.first(in: actions, chords: \.shortcuts, press: press, typable: KeyboardLayoutCharacters.types)
    }
}

extension NSMenuItem {
    /// Shows a command's shortcut on the right of a context-menu row, as the menu bar does,
    /// following the user's overrides. Shortcut.key is already unshifted ("r" for ⇧⌘R), which
    /// is what keyEquivalent wants.
    @MainActor func showShortcut(of id: String) {
        guard let s = KeyBindingRegistry.shared.action(id)?.primary else { return }
        keyEquivalent = s.key
        keyEquivalentModifierMask = s.flags
    }
}

extension KeyBindingRegistry {
    /// What the command bar offers (SuggestionEngine), in menu order, with the user's shortcuts.
    var commandBarCommands: [CommandBarCommand] { barCommands(display: \.display) }
}
