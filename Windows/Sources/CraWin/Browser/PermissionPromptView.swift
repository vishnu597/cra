import CraCore
import Foundation
import UWP
import WindowsFoundation
import WinUI

/// A page's permission request (the Mac's sheet in BrowserManager): CraCore's PermissionPrompt
/// question, "mail.google.com wants to show notifications" (the site named as Chrome names
/// it), with Allow and Block. It floats in a window of its own at the top of the page, as the Mac's sheet drops from the window's top;
/// requests from several pages wait their turn.
@MainActor
final class PermissionPromptView {
    static let width = 400.0

    var onAnswer: (Bool) -> Void = { _ in }

    let root = Grid()
    private let message = TextBlock()
    private var allow: Button!
    private var block: Button!

    init() {
        build()
    }

    /// Shows `origin`'s question for `kinds` (CraCEFWin's bits) and returns the height it
    /// needs in DIPs at `width`.
    func show(origin: String, kinds: UInt, dark: Bool) -> Double {
        message.text = PermissionPrompt.message(origin: PermissionPrompt.displayOrigin(origin), kinds: kinds)
        root.requestedTheme = dark ? .dark : .light
        root.background = dark ? UI.brush(44, 44, 48) : UI.brush(252, 252, 253)
        message.foreground = dark ? UI.brush(255, 255, 255) : UI.brush(20, 20, 24)
        try? root.measure(WindowsFoundation.Size(width: Float(Self.width), height: .infinity))
        return max(96, Double(root.desiredSize.height).rounded(.up))
    }

    /// Allow takes the keyboard: Return allows, Escape blocks.
    func focus() {
        _ = try? allow.focus(.programmatic)
    }

    private func build() {
        root.padding = Thickness(left: 20, top: 18, right: 20, bottom: 16)
        root.rowDefinitions.append(UI.row(UI.auto))
        root.rowDefinitions.append(UI.row(UI.auto))
        message.fontSize = 14
        message.fontWeight = UWP.FontWeight(weight: 600)
        message.textWrapping = .wrap
        message.maxWidth = Self.width - 40
        root.children.append(message)
        try? Grid.setRow(message, 0)

        let answers = StackPanel()
        answers.orientation = .horizontal
        answers.spacing = 8
        answers.horizontalAlignment = .right
        answers.margin = Thickness(left: 0, top: 16, right: 0, bottom: 0)
        allow = Button()
        allow.content = UI.text("Allow", color: UI.brush(255, 255, 255), trimmed: false)
        allow.minWidth = 88
        // The default button, in Windows' accent colour (WinUI's AccentButtonStyle).
        let accent = WinAppearance.accent
        allow.background = UI.brush(accent.r, accent.g, accent.b)
        _ = allow.resources.insert("ButtonBackgroundPointerOver", UI.brush(accent.r, accent.g, accent.b, alpha: 230))
        _ = allow.resources.insert("ButtonBackgroundPressed", UI.brush(accent.r, accent.g, accent.b, alpha: 205))
        _ = allow.resources.insert("ButtonForegroundPointerOver", UI.brush(255, 255, 255))
        _ = allow.resources.insert("ButtonForegroundPressed", UI.brush(255, 255, 255))
        allow.clickMode = .press
        allow.click.addHandler { [weak self] _, _ in self?.onAnswer(true) }
        block = Button()
        block.content = UI.text("Block", trimmed: false)
        block.minWidth = 88
        block.clickMode = .press
        block.click.addHandler { [weak self] _, _ in self?.onAnswer(false) }
        answers.children.append(allow)
        answers.children.append(block)
        root.children.append(answers)
        try? Grid.setRow(answers, 1)

        root.previewKeyDown.addHandler { [weak self] _, args in
            guard let self, let args else { return }
            switch Int32(truncatingIfNeeded: args.key.rawValue) {
            case 0x1B: self.onAnswer(false)  // Escape
            case 0x0D: self.onAnswer(true)  // Return
            default: return
            }
            args.handled = true
        }
    }
}
