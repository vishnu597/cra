import Foundation
import WinSDK

/// Values under HKEY_CURRENT_USER: launch at login, the light/dark setting and the accent colour.
enum WinRegistry {
    /// HKEY_CURRENT_USER, a macro Swift can't see: (HKEY)(ULONG_PTR)(LONG)0x80000001.
    private static let currentUser = HKEY(bitPattern: Int(Int32(bitPattern: 0x8000_0001)))
    // RRF_RT_REG_SZ, RRF_RT_REG_BINARY, RRF_RT_REG_DWORD; REG_SZ; ERROR_FILE_NOT_FOUND.
    private static let typeString: DWORD = 0x02, typeBinary: DWORD = 0x08, typeDWORD: DWORD = 0x10
    private static let regSZ: DWORD = 1
    private static let notFound: LSTATUS = 2

    static func string(_ key: String, _ name: String) -> String? {
        guard let bytes = read(key, name, type: typeString), bytes.count >= 2 else { return nil }
        let units = stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        return String(decoding: units.prefix { $0 != 0 }, as: UTF16.self)
    }

    static func dword(_ key: String, _ name: String) -> UInt32? {
        guard let bytes = read(key, name, type: typeDWORD), bytes.count >= 4 else { return nil }
        return bytes.prefix(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    static func binary(_ key: String, _ name: String) -> [UInt8]? {
        read(key, name, type: typeBinary)
    }

    /// Writes a REG_SZ value, making the key if it isn't there.
    static func setString(_ key: String, _ name: String, _ value: String) -> Bool {
        let data = Array(value.utf16) + [0]
        return key.withCString(encodedAs: UTF16.self) { k in
            name.withCString(encodedAs: UTF16.self) { n in
                data.withUnsafeBytes { raw in
                    RegSetKeyValueW(currentUser, k, n, regSZ, raw.baseAddress, DWORD(raw.count)) == 0
                }
            }
        }
    }

    /// Deletes a value; true when it is gone, whether or not it was there.
    static func delete(_ key: String, _ name: String) -> Bool {
        key.withCString(encodedAs: UTF16.self) { k in
            name.withCString(encodedAs: UTF16.self) { n in
                let status = RegDeleteKeyValueW(currentUser, k, n)
                return status == 0 || status == notFound
            }
        }
    }

    private static func read(_ key: String, _ name: String, type: DWORD) -> [UInt8]? {
        key.withCString(encodedAs: UTF16.self) { k in
            name.withCString(encodedAs: UTF16.self) { n -> [UInt8]? in
                var size: DWORD = 0
                guard RegGetValueW(currentUser, k, n, type, nil, nil, &size) == 0 else { return nil }
                var bytes = [UInt8](repeating: 0, count: Int(size))
                guard size > 0 else { return bytes }
                let status = bytes.withUnsafeMutableBytes { RegGetValueW(currentUser, k, n, type, nil, $0.baseAddress, &size) }
                guard status == 0 else { return nil }
                return Array(bytes.prefix(Int(size)))
            }
        }
    }
}

/// The light/dark setting and the accent colour, as Windows' own Settings app shows them.
enum WinAppearance {
    private static let personalize = #"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"#

    /// Settings ▸ Personalization ▸ Colors ▸ "Choose your app mode": Dark.
    static var isDark: Bool { WinRegistry.dword(personalize, "AppsUseLightTheme") == 0 }

    /// The accent colour (DWM keeps it as 0xAABBGGRR); Windows 11's default blue without one.
    static var accent: (r: UInt8, g: UInt8, b: UInt8) {
        guard let v = WinRegistry.dword(#"Software\Microsoft\Windows\DWM"#, "AccentColor") else { return (0, 103, 192) }
        return (UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF))
    }
}

/// Settings ▸ General ▸ "Open Cra at login": a value in the user's Run key, as installers write
/// it. Task Manager's Startup apps page turns one off without deleting it, by a flag under
/// StartupApproved; turning it on here clears that.
enum LaunchAtLogin {
    private static let run = #"Software\Microsoft\Windows\CurrentVersion\Run"#
    private static let approved = #"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"#
    private static let name = "Cra"

    static var isEnabled: Bool {
        guard WinRegistry.string(run, name) != nil else { return false }
        // The flag's first byte: even (2, 6) on, odd (3, 7) turned off in Task Manager.
        return (WinRegistry.binary(approved, name)?.first).map { $0 & 1 == 0 } ?? true
    }

    /// Turns it on or off; nil when that worked, else what to tell the user.
    static func set(_ on: Bool) -> String? {
        if on {
            guard let exe = executablePath, WinRegistry.setString(run, name, "\"\(exe)\"") else {
                return "Cra could not be set to open at login."
            }
            _ = WinRegistry.delete(approved, name)
        } else if !WinRegistry.delete(run, name) {
            return "Cra could not be removed from the apps that open at login."
        }
        return nil
    }

    /// Cra.exe's full path (the command line may hold a relative one).
    private static var executablePath: String? {
        var buffer = [WCHAR](repeating: 0, count: 32_768)
        let count = Int(GetModuleFileNameW(nil, &buffer, DWORD(buffer.count)))
        guard count > 0, count < buffer.count else { return nil }
        return String(decoding: buffer.prefix(count), as: UTF16.self)
    }
}
