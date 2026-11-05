import Foundation
import Observation

/// The panes in Dia's Settings sidebar (Dia 1.54.2: Account, Tabs, Privacy, Profiles, Skills,
/// Apps, Shortcuts, Advanced). Cra has no account or AI skills/apps; General
/// (system integration) and Extensions take rows instead. Each app draws the panes it has
/// (the Mac all of them; Windows `windowsPanes` so far) and gives them its own glyphs.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general, tabs, max, privacy, profiles, extensions, shortcuts, performance, advanced
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: return "General"
        case .tabs: return "Tabs"
        case .max: return "Max"
        case .privacy: return "Privacy"
        case .profiles: return "Profiles"
        case .extensions: return "Extensions"
        case .shortcuts: return "Shortcuts"
        case .performance: return "Performance"
        case .advanced: return "Advanced"
        }
    }

    /// What the Windows app's Settings window lists: the panes whose features it has, in the
    /// Mac's order. More join as the port gets them (docs/windows.md).
    public static let windowsPanes: [SettingsPane] = [.general, .tabs, .profiles, .shortcuts]
}

/// Selected pane plus the back/forward history behind the toolbar pill.
@MainActor
@Observable
public final class SettingsNavigation {
    public private(set) var pane: SettingsPane
    public private(set) var back: [SettingsPane] = []
    public private(set) var forward: [SettingsPane] = []
    /// The window is on screen: panes that refresh (Performance) stop while it is closed or covered.
    public var isOpen = false

    public init(pane: SettingsPane = .general) {
        self.pane = pane
    }

    public func show(_ p: SettingsPane) {
        guard p != pane else { return }
        back.append(pane)
        forward = []
        pane = p
    }

    public func goBack() {
        guard let p = back.popLast() else { return }
        forward.append(pane)
        pane = p
    }

    public func goForward() {
        guard let p = forward.popLast() else { return }
        back.append(pane)
        pane = p
    }
}
