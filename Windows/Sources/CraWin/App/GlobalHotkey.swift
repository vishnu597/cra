import CraCore
import Foundation
import WinSDK

/// New Little Window's key from any app (GlobalHotkey on the Mac, Arc's "Open Little Arc when I
/// press ⌥⌘N", GitHub #195): RegisterHotKey for the UI thread, whose WM_HOTKEY MessageLoop hands
/// over. Settings ▸ Tabs turns it off; CraCore's GlobalShortcut decides which chord qualifies.
@MainActor
final class GlobalHotkey {
    private static let id: Int32 = 1
    private var registered: KeyChord?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        MessageLoop.onHotKey = { id in
            guard id == Self.id else { return }
            onMain { action() }
        }
    }

    /// Takes `chord` from every app (nil gives it back). A chord that types a character on the
    /// keyboard layout in use (AltGr+N is ń on Polish keyboards, and AltGr is Ctrl+Alt to
    /// Windows) is left to type.
    func set(_ chord: KeyChord?) {
        let chord = chord.flatMap { WinKeyboard.typesCharacter($0, layoutOf: GetForegroundWindow()) ? nil : $0 }
        guard chord != registered else { return }
        if registered != nil {
            _ = UnregisterHotKey(nil, Self.id)
            registered = nil
        }
        guard let chord, let vk = chord.windowsVirtualKey else { return }
        _ = RegisterHotKey(nil, Self.id, UINT(GlobalShortcut.windowsModifiers(chord.keys)), UINT(vk))
        registered = chord
    }
}

/// What the keyboard layout makes of a key.
enum WinKeyboard {
    /// Whether `chord`'s keys type a character rather than being a shortcut: Ctrl+Alt is AltGr,
    /// which types on many layouts (Polish AltGr+N is ń, German AltGr+Q is @). `window`'s thread
    /// gives the layout; nil means this thread's.
    static func typesCharacter(_ chord: KeyChord, layoutOf window: HWND? = nil) -> Bool {
        guard chord.keys.contains(.control), chord.keys.contains(.option), !chord.keys.contains(.command),
              let vk = chord.windowsVirtualKey else { return false }
        let thread = window.map { GetWindowThreadProcessId($0, nil) } ?? 0
        let layout = GetKeyboardLayout(thread)
        var state = [UInt8](repeating: 0, count: 256)
        state[0x11] = 0x80  // VK_CONTROL
        state[0x12] = 0x80  // VK_MENU
        if chord.keys.contains(.shift) { state[0x10] = 0x80 }
        let scan = MapVirtualKeyExW(UINT(vk), 0, layout)  // MAPVK_VK_TO_VSC
        var buffer = [WCHAR](repeating: 0, count: 8)
        // Flag 4: leave the keyboard's dead-key state alone.
        let n = ToUnicodeEx(UINT(vk), scan, &state, &buffer, Int32(buffer.count), 4, layout)
        // A dead key (-1) types too, with the next key.
        return n != 0 && !(n > 0 && buffer[0] < 0x20)
    }

    /// The same for a key press a page or XAML reports.
    static func typesCharacter(_ key: KeyPress) -> Bool {
        guard key.control, key.alt,
              let chord = KeyChord(windowsVirtualKey: key.keyCode, control: true, shift: key.shift, alt: true) else { return false }
        return typesCharacter(chord)
    }
}
