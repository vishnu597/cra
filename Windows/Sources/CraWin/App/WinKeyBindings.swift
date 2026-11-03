import CraCore
import Foundation

/// The app's one key binding registry: Windows' table (KeyBindingDefaults.windows) with the
/// user's keys from keybindings.json in the data folder. Shortcuts, the command bar's rows and
/// Settings ▸ Shortcuts all read it.
@MainActor
enum WinKeyBindings {
    static let shared = KeyBindingRegistry(defaults: KeyBindingDefaults.windows,
                                           file: JSONStore("keybindings.json", in: WinPaths.supportDir))
}
