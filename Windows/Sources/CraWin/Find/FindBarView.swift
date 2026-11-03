import CraCore
import Foundation
import UWP
import WinSDK
import WinUI

/// Find in page, top right over the page: glyph, field, "2/7", previous, next, close. The
/// Mac's FindBarView; it floats in its own window (FloatingWindow), as FindBarPanel does.
@MainActor
final class FindBarView {
    /// CraMetrics.findBarSize and findBarInset, in DIPs.
    static let width = 300.0
    static let height = 38.0
    static let inset = 10.0

    /// The query and the direction: typing searches forward, Return and the arrows step.
    var onFind: (String, Bool) -> Void = { _, _ in }
    var onClose: () -> Void = {}

    let root = Grid()
    /// What was typed; kept while the bar is hidden, as on the Mac.
    private(set) var query = ""
    private var matches: Int?
    private var active = 0
    private var dark = true

    private let glyph = FontIcon()
    private let field = TextBox()
    private let count = TextBlock()
    private var icons: [FontIcon] = []

    init() {
        build()
        apply(dark: true)
    }

    /// The field takes the keyboard, its text selected (Ctrl+F again selects it too).
    func focusField() {
        _ = try? field.focus(.programmatic)
        try? field.selectAll()
    }

    /// Chromium's answer; -1 leaves a value as it was (CEF reports them separately).
    func report(matches count: Int, active activeMatch: Int) {
        if count >= 0 { matches = count }
        if activeMatch >= 0 { active = activeMatch }
        showCount()
    }

    /// Hidden: the count goes until the page answers again.
    func reset() {
        matches = nil
        showCount()
    }

    func apply(dark: Bool) {
        self.dark = dark
        root.requestedTheme = dark ? .dark : .light
        root.background = dark ? UI.brush(44, 44, 48) : UI.brush(252, 252, 253)
        let ink = dark ? UI.brush(255, 255, 255) : UI.brush(20, 20, 24)
        let secondary = dark ? UI.brush(255, 255, 255, alpha: 140) : UI.brush(20, 20, 24, alpha: 140)
        field.foreground = ink
        glyph.foreground = secondary
        count.foreground = secondary
        for icon in icons { icon.foreground = ink }
    }

    private func showCount() {
        let label = FindInPage.countLabel(query: query, matches: matches, active: active)
        count.text = label ?? ""
        count.visibility = label == nil ? .collapsed : .visible
    }

    private func build() {
        // padding 10, glyph, 6, field (flexible), 6, count, 6, ▲, 6, ▼, 6, ✕, padding 10.
        for width in [UI.pixels(30), UI.star, UI.auto, UI.auto, UI.auto, UI.auto] { root.columnDefinitions.append(UI.column(width)) }
        root.padding = Thickness(left: 0, top: 0, right: 6, bottom: 0)

        glyph.glyph = "\u{E721}"
        glyph.fontSize = 13
        glyph.horizontalAlignment = .right
        glyph.verticalAlignment = .center

        field.fontSize = 13
        field.placeholderText = "Find in page"
        field.verticalAlignment = .center
        field.minHeight = 0
        field.padding = Thickness(left: 6, top: 4, right: 4, bottom: 4)
        field.borderThickness = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        field.background = UI.clear
        field.isSpellCheckEnabled = false
        field.isTextPredictionEnabled = false
        for key in ["TextControlBackgroundFocused", "TextControlBackgroundPointerOver", "TextControlBorderBrushFocused",
                    "TextControlBorderBrushPointerOver", "TextControlBackground", "TextControlBorderBrush"] {
            _ = field.resources.insert(key, UI.clear)
        }
        // Every change, typed or pasted, searches (SwiftUI's .onChange on the Mac).
        field.textChanged.addHandler { [weak self] _, _ in
            guard let self, self.field.text != self.query else { return }
            self.query = self.field.text
            self.showCount()
            self.onFind(self.query, true)
        }
        field.previewKeyDown.addHandler { [weak self] _, args in
            guard let self, let args else { return }
            let vk = Int32(truncatingIfNeeded: args.key.rawValue)
            let shift = GetKeyState(0x10) < 0, control = GetKeyState(0x11) < 0
            switch vk {
            case 0x0D: self.onFind(self.query, !shift)  // Return, Shift+Return
            case 0x72: self.onFind(self.query, !shift)  // F3
            case 0x47 where control: self.onFind(self.query, !shift)  // Ctrl+G
            case 0x46 where control: try? self.field.selectAll()  // Ctrl+F
            case 0x1B: self.onClose()  // Escape
            default: return
            }
            args.handled = true
        }

        count.fontSize = 11
        count.verticalAlignment = .center
        count.margin = Thickness(left: 6, top: 0, right: 6, bottom: 0)

        let parts: [FrameworkElement] = [glyph, field, count]
        for (i, part) in parts.enumerated() {
            root.children.append(part)
            try? Grid.setColumn(part, Int32(i))
        }
        let actions: [(String, String, @MainActor () -> Void)] = [
            ("\u{E70E}", "Previous", { [weak self] in self.map { $0.onFind($0.query, false) } }),
            ("\u{E70D}", "Next", { [weak self] in self.map { $0.onFind($0.query, true) } }),
            ("\u{E711}", "Close", { [weak self] in self?.onClose() }),
        ]
        for (i, (code, tip, run)) in actions.enumerated() {
            let icon = FontIcon()
            icon.glyph = code
            icon.fontSize = 11
            icons.append(icon)
            let button = UI.button(icon, padding: Thickness(left: 6, top: 6, right: 6, bottom: 6), run)
            button.verticalAlignment = .center
            try? ToolTipService.setToolTip(button, tip)
            root.children.append(button)
            try? Grid.setColumn(button, Int32(3 + i))
        }
        showCount()
    }
}
