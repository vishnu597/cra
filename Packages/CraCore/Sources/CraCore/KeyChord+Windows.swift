import Foundation

/// KeyChord on Windows. keybindings.json keeps one format: `key` is the same character or
/// special key as on the Mac, and the modifier bits are named after the keys, so on Windows
/// `.control` is Ctrl, `.option` is Alt and `.command` the Windows key.
public extension KeyChord {
    /// F1...F19 as AppKit writes them (NSF1FunctionKey is U+F704).
    static func function(_ n: Int) -> String {
        String(UnicodeScalar(UInt32(0xF703 + n)).map(Character.init) ?? " ")
    }

    /// The function key's number, nil for any other key.
    var functionNumber: Int? {
        guard key.unicodeScalars.count == 1, let v = key.unicodeScalars.first?.value, (0xF704...0xF716).contains(v) else { return nil }
        return Int(v) - 0xF703
    }

    /// How Windows writes it: "Ctrl+Shift+T", in Microsoft's order (Win, Ctrl, Alt, Shift).
    var windowsDisplay: String {
        var parts: [String] = []
        if keys.contains(.command) { parts.append("Win") }
        if keys.contains(.control) { parts.append("Ctrl") }
        if keys.contains(.option) { parts.append("Alt") }
        if keys.contains(.shift) { parts.append("Shift") }
        switch key {
        case Self.tab: parts.append("Tab")
        case Self.left: parts.append("Left")
        case Self.right: parts.append("Right")
        case Self.up: parts.append("Up")
        case Self.down: parts.append("Down")
        case Self.delete: parts.append("Backspace")
        default: parts.append(functionNumber.map { "F\($0)" } ?? key.uppercased())
        }
        return parts.joined(separator: "+")
    }

    /// The keys that are not characters, which a shortcut can use without Ctrl or Alt.
    var isSpecialKey: Bool {
        [Self.tab, Self.left, Self.right, Self.up, Self.down].contains(key) || functionNumber != nil
    }

    // MARK: Virtual keys

    /// Windows virtual-key codes for the punctuation keys, by the US layout's unshifted
    /// character (VK_OEM_*). These are key positions, as the Mac's ANSI key-code fallback.
    private static let oemKeys: [Int32: String] = [
        0xBA: ";", 0xBB: "=", 0xBC: ",", 0xBD: "-", 0xBE: ".", 0xBF: "/", 0xC0: "`",
        0xDB: "[", 0xDC: "\\", 0xDD: "]", 0xDE: "'",
    ]

    /// The chord for a key press on Windows (VK_* code and the modifier keys held), nil for a
    /// key no shortcut uses (a modifier on its own, Escape, Enter...).
    init?(windowsVirtualKey vk: Int32, control: Bool, shift: Bool, alt: Bool, windows: Bool = false) {
        let key: String
        switch vk {
        case 0x41...0x5A, 0x30...0x39: key = String(UnicodeScalar(UInt8(vk))).lowercased()   // A-Z, 0-9
        case 0x60...0x69: key = String(vk - 0x60)                                           // the keypad's digits
        case 0x08: key = Self.delete
        case 0x09: key = Self.tab
        case 0x25: key = Self.left
        case 0x26: key = Self.up
        case 0x27: key = Self.right
        case 0x28: key = Self.down
        case 0x70...0x82: key = Self.function(Int(vk - 0x6F))                                // F1-F19
        default:
            guard let k = Self.oemKeys[vk] else { return nil }
            key = k
        }
        var mods: Modifiers = []
        if control { mods.insert(.control) }
        if shift { mods.insert(.shift) }
        if alt { mods.insert(.option) }
        if windows { mods.insert(.command) }
        self.init(key, mods)
    }

    /// The virtual-key code that types the chord's key (the inverse of
    /// `init(windowsVirtualKey:…)`), for RegisterHotKey; nil for a key it has none for.
    var windowsVirtualKey: Int32? {
        if let n = functionNumber { return Int32(0x6F + n) }
        switch key {
        case Self.delete: return 0x08
        case Self.tab: return 0x09
        case Self.left: return 0x25
        case Self.up: return 0x26
        case Self.right: return 0x27
        case Self.down: return 0x28
        default: break
        }
        guard key.unicodeScalars.count == 1, let v = key.unicodeScalars.first?.value else { return nil }
        switch v {
        case 0x61...0x7A: return Int32(v - 0x20)   // a-z → VK 'A'-'Z'
        case 0x30...0x39: return Int32(v)          // 0-9
        default: return Self.oemKeys.first { $0.value == key }?.key
        }
    }

    /// The chord as Settings ▸ Shortcuts records it on Windows: a letter or digit needs Ctrl,
    /// Alt or the Windows key (Shift alone types), as ⌘, ⌃ or ⌥ on the Mac.
    static func recorded(windowsVirtualKey vk: Int32, control: Bool, shift: Bool, alt: Bool, windows: Bool = false) -> KeyChord? {
        guard let chord = KeyChord(windowsVirtualKey: vk, control: control, shift: shift, alt: alt, windows: windows) else { return nil }
        guard chord.isSpecialKey || !chord.keys.isDisjoint(with: [.control, .option, .command]) else { return nil }
        return chord
    }
}
