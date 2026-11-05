import CraCEFWin
import Foundation

/// The clipboard, Windows' Share window and the Save dialog (CraCEFWin.h, MARK: Shell): what
/// NSPasteboard, NSSharingServicePicker and NSSavePanel do on the Mac.
@MainActor
enum WinShell {
    @discardableResult
    static func copy(_ text: String) -> Bool {
        text.withCString { cra_clipboard_set_text($0) } != 0
    }

    /// An image, as PNG and as a bitmap.
    @discardableResult
    static func copy(png: Data) -> Bool {
        png.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            return cra_clipboard_set_png(base, raw.count) != 0
        }
    }

    /// Windows' Share window for a link, over the window `owner`.
    @discardableResult
    static func share(url: String, title: String, owner: UInt) -> Bool {
        url.withCString { u in title.withCString { t in cra_share_link(owner, u, t) } } != 0
    }

    /// A native menu at the pointer: `items` with nil for a separator. The chosen one's index.
    static func popupMenu(owner: UInt, _ items: [String?]) -> Int? {
        let copies: [UnsafeMutablePointer<CChar>?] = items.map { item in
            guard let item else { return nil }
            let utf8 = item.utf8CString
            let copy = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count)
            for (i, c) in utf8.enumerated() { copy[i] = c }
            return copy
        }
        defer { copies.forEach { $0?.deallocate() } }
        let pointers = copies.map { $0.map { UnsafePointer($0) } }
        let chosen = pointers.withUnsafeBufferPointer { cra_popup_menu(owner, $0.baseAddress, $0.count) }
        return chosen > 0 ? Int(chosen) - 1 : nil
    }

    /// Windows' Save dialog for a PNG, opening in Downloads; the chosen path, nil if cancelled.
    static func savePNG(owner: UInt, title: String, fileName: String) -> String? {
        let capacity = 4096
        var buffer = [CChar](repeating: 0, count: capacity)
        let chosen = title.withCString { t in
            fileName.withCString { f in cra_save_png_dialog(owner, t, f, &buffer, capacity) }
        }
        guard chosen != 0 else { return nil }
        return String(cString: buffer)
    }
}
