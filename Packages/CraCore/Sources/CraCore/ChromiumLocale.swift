import Foundation

/// Chromium's application locale (`CefSettings.locale`, `--lang`), picked the way Chrome and
/// Arc pick it on macOS: the first macOS language the browser has a translation for, matched by
/// macOS itself (Chrome's `OverrideLocaleWithCocoaLocale` reads its bundle's
/// `preferredLocalizations`, and Arc's bundle carries one `.lproj` per Chromium locale).
///
/// It decides which voice speaks an utterance that has no `lang` (#167), what language
/// Chromium's own pages, dialogs and menus are in, how pages format dates by default, and a new
/// profile's Accept-Language. Without it CEF forces en-US whatever macOS is set to.
public enum ChromiumLocale {
    /// `available` is the framework's localization folder names ("en", "en_GB", "zh_CN",
    /// "af_FEMININE"), `preferredLanguages` the user's macOS languages, most wanted first
    /// ("zh-Hans-CN"). Nil when the framework lists no locales, which leaves CEF's en-US.
    public static func pick(available: [String], preferredLanguages: [String]) -> String? {
        // Chromium 156 ships gendered variants of each locale; they aren't separate languages.
        let candidates = available
            .filter { !["_FEMININE", "_MASCULINE", "_NEUTER"].contains(where: $0.hasSuffix) && $0 != "Base" }
            .map { $0.replacingOccurrences(of: "_", with: "-") }
        guard !candidates.isEmpty else { return nil }
        #if canImport(Darwin)
        guard let match = Bundle.preferredLocalizations(from: candidates, forPreferences: preferredLanguages).first else { return nil }
        #else
        // swift-corelibs-foundation doesn't match localizations (it answers the first one).
        let match = portableMatch(candidates, preferredLanguages)
        #endif
        // On disk Chromium's en-US is just "en" (crbug.com/25578); Chrome maps it back.
        return match == "en" ? "en-US" : match
    }

    /// What macOS's `preferredLocalizations` answers for Chromium's locale list, for the
    /// platforms whose Foundation can't: the first preferred language with a translation,
    /// through CLDR's regional parents (en-AU is en-GB, es-MX is es-419, zh-Hant-HK is zh-TW),
    /// else English.
    public static func portableMatch(_ candidates: [String], _ preferred: [String]) -> String {
        let have = Set(candidates)
        for tag in preferred {
            if let m = localization(for: tag, in: have) { return m }
        }
        return have.contains("en") ? "en" : candidates[0]
    }

    /// Regions whose English is American English (CLDR's en-001 covers the rest).
    private static let americanEnglish: Set<String> = ["US", "AS", "GU", "MH", "MP", "PR", "UM", "VI"]

    private static func localization(for tag: String, in have: Set<String>) -> String? {
        let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard var lang = parts.first?.lowercased(), !lang.isEmpty else { return nil }
        let script = parts.dropFirst().first { $0.count == 4 }?.capitalized
        let region = parts.dropFirst().first { $0.count == 2 || ($0.count == 3 && $0.allSatisfy(\.isNumber)) }?.uppercased()
        lang = ["iw": "he", "in": "id", "tl": "fil", "no": "nb", "nn": "nb"][lang] ?? lang
        var tries: [String] = []
        switch lang {
        case "zh":
            let traditional = script == "Hant" || (script == nil && ["TW", "HK", "MO"].contains(region ?? ""))
            tries = [traditional ? "zh-TW" : "zh-CN"]
        case "en":
            if let r = region { tries.append("en-\(r)") }
            tries.append(region.map { americanEnglish.contains($0) } ?? true ? "en" : "en-GB")
        case "es":
            if let r = region { tries.append("es-\(r)") }
            if let r = region, r != "ES", r != "GQ" { tries.append("es-419") }
        case "pt":
            tries.append(region.map { $0 == "BR" } ?? true ? "pt-BR" : "pt-PT")
        default:
            if let r = region { tries.append("\(lang)-\(r)") }
        }
        tries.append(lang)
        if let hit = tries.first(where: have.contains) { return hit }
        return have.sorted().first { $0.hasPrefix(lang + "-") }
    }
}
