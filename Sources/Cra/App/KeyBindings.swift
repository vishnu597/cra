import AppKit

/// A keyboard shortcut: CraCore's KeyChord (the keybindings.json format), read from and
/// matched against AppKit key events here.
typealias Shortcut = KeyChord

extension Shortcut {
    init(_ key: String, _ mods: NSEvent.ModifierFlags) {
        self.init(key: key, modifiers: mods.intersection(.deviceIndependentFlagsMask).rawValue)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// Shift turns "[" into "{" in charactersIgnoringModifiers; undo that.
    /// ⇧Tab arrives as backtab (U+0019), the Delete key as U+007F.
    private static let unshift: [String: String] = ["\u{19}": Shortcut.tab, "\u{7F}": Shortcut.delete, "{": "[", "}": "]", "<": ",", ">": ".", "?": "/", "+": "=", "_": "-", "~": "`", ":": ";", "\"": "'", "|": "\\"]

    /// Physical-key fallbacks so ⌘[ / ⌘] work on layouts (Danish, German...)
    /// where those characters live on other keys. Key codes are ANSI positions.
    private static let keyCodeFor: [String: UInt16] = ["[": 33, "]": 30, "=": 24, "-": 27, ",": 43, ".": 47, "/": 44, ";": 41, "'": 39, "`": 50, "\\": 42]

    func matches(_ event: NSEvent) -> Bool {
        // charactersIgnoringModifiers throws on flagsChanged events, which
        // Chromium forwards as raw key-downs for modifier keys.
        guard event.type == .keyDown else { return false }
        let evFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard evFlags == flags.intersection([.command, .shift, .option, .control]) else { return false }
        guard var chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return false }
        chars = chars.lowercased()
        if let u = Self.unshift[chars] { chars = u }
        if chars == key { return true }
        if let code = Self.keyCodeFor[key], event.keyCode == code { return true }
        return false
    }

    /// Build a shortcut from a recorded key press (nil for bare letters without ⌘/⌃/⌥).
    static func from(event e: NSEvent) -> Shortcut? {
        guard e.type == .keyDown, var chars = e.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        chars = chars.lowercased()
        if let u = unshift[chars] { chars = u }
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

    /// First action whose shortcut matches the key event.
    func action(for event: NSEvent) -> KeyAction? {
        for a in actions where a.shortcuts.contains(where: { $0.matches(event) }) { return a }
        return nil
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
