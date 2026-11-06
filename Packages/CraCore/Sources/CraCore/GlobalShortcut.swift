import Foundation

/// A shortcut that works while another app is in front: Arc's "Open Little Arc when I press ⌥⌘N"
/// (globalLittleBrowserHotkeyEnabled, GitHub #195). macOS takes it from every app, so only a chord
/// with ⌘, ⌃ or ⌥ qualifies: a lone key or ⇧ and a key would stop that key typing anywhere.
public enum GlobalShortcut {
    /// Carbon's modifier bits for RegisterEventHotKey (cmdKey, shiftKey, optionKey, controlKey).
    public static let carbonCommand: UInt32 = 1 << 8
    public static let carbonShift: UInt32 = 1 << 9
    public static let carbonOption: UInt32 = 1 << 11
    public static let carbonControl: UInt32 = 1 << 12

    /// The chord to register, or nil when there is none to take from other apps.
    public static func registrable(_ chords: [KeyChord], enabled: Bool) -> KeyChord? {
        guard enabled else { return nil }
        return chords.first { chord in
            !chord.key.isEmpty && !chord.keys.intersection([.command, .control, .option]).isEmpty
        }
    }

    /// RegisterHotKey's modifier bits on Windows (MOD_ALT, MOD_CONTROL, MOD_SHIFT, MOD_WIN), and
    /// MOD_NOREPEAT so holding the keys doesn't open one window after another.
    public static let windowsAlt: UInt32 = 0x1, windowsControl: UInt32 = 0x2, windowsShift: UInt32 = 0x4
    public static let windowsWin: UInt32 = 0x8, windowsNoRepeat: UInt32 = 0x4000

    /// KeyChord.Modifiers as Windows' (KeyChord+Windows: `.control` is Ctrl, `.option` Alt,
    /// `.command` the Windows key).
    public static func windowsModifiers(_ modifiers: KeyChord.Modifiers) -> UInt32 {
        var out = windowsNoRepeat
        if modifiers.contains(.control) { out |= windowsControl }
        if modifiers.contains(.option) { out |= windowsAlt }
        if modifiers.contains(.shift) { out |= windowsShift }
        if modifiers.contains(.command) { out |= windowsWin }
        return out
    }

    /// NSEvent-style modifier bits (KeyChord.Modifiers) as Carbon's.
    public static func carbonModifiers(_ modifiers: KeyChord.Modifiers) -> UInt32 {
        var out: UInt32 = 0
        if modifiers.contains(.command) { out |= carbonCommand }
        if modifiers.contains(.shift) { out |= carbonShift }
        if modifiers.contains(.option) { out |= carbonOption }
        if modifiers.contains(.control) { out |= carbonControl }
        return out
    }
}
