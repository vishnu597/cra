import CraCore
import Foundation
import UWP
import WinAppSDK
import WindowsFoundation
import WinUI

/// Arc's toast (the Mac's ShinyToast): a short confirmation at the top right of the page,
/// "Copied Current URL" or "Screenshot Copied to Clipboard" with a Save button, in the space's
/// colours (CraCore's ToastStyle). It floats in a window of its own that never takes the
/// keyboard, and goes 4.85 s after the last message, or once the pointer leaves it.
@MainActor
final class ToastView {
    struct Action {
        let title: String
        let run: @MainActor () -> Void
    }

    private let root = Border()
    /// Chromium's classic scrollbar on Windows, in DIPs.
    private static let scrollbar = 15.0

    private let label = TextBlock()
    private let buttonLabel = TextBlock()
    private var button: Button!
    private var action: Action?
    private var window: FloatingWindow?
    private var timer: WinAppSDK.DispatcherQueueTimer?
    /// The page's frame on screen in physical pixels, and the scale: where the toast goes.
    private let page: () -> (left: Int32, top: Int32, right: Int32, scale: Double)?

    init(owner: HostWindow, page: @escaping () -> (left: Int32, top: Int32, right: Int32, scale: Double)?) {
        self.page = page
        build()
        do {
            window = try FloatingWindow(owner: owner, content: root)
            window?.onClose = { [weak self] in self?.hide() }
        } catch {
            print("The toast's window could not be made: \(error)")
        }
    }

    var isShown: Bool { window?.isVisible == true }

    func show(_ text: String, action: Action? = nil, theme: SpaceTheme) {
        guard let window, let page = page() else { return }
        self.action = action
        let colors = ToastStyle.colors(theme)
        func brush(_ c: RGB, alpha: UInt8 = 255) -> SolidColorBrush {
            UI.brush(UInt8((c.r * 255).rounded()), UInt8((c.g * 255).rounded()), UInt8((c.b * 255).rounded()), alpha: alpha)
        }
        // The Mac's vertical gradient, as its middle.
        root.background = brush(colors.top.mixed(with: colors.bottom, 0.5))
        root.borderBrush = brush(colors.outline)
        label.text = text
        label.foreground = brush(colors.text)
        buttonLabel.foreground = brush(colors.text)
        button.background = brush(colors.text, alpha: 40)
        _ = button.resources.insert("ButtonBackgroundPointerOver", brush(colors.text, alpha: 60))
        _ = button.resources.insert("ButtonBackgroundPressed", brush(colors.text, alpha: 80))
        buttonLabel.text = action?.title ?? ""
        button.visibility = action == nil ? .collapsed : .visible

        // Its text's width decides its own: 12 either side, then the button and 8 around it.
        let infinite = WindowsFoundation.Size(width: .infinity, height: .infinity)
        try? label.measure(infinite)
        var width = Double(label.desiredSize.width).rounded(.up) + 2 * Double(ToastStyle.padding)
        if action != nil {
            try? button.measure(infinite)
            width += Double(button.desiredSize.width).rounded(.up) + Double(ToastStyle.buttonGap)
                - Double(ToastStyle.padding) + Double(ToastStyle.height - ToastStyle.buttonHeight) / 2
        }
        let scale = page.scale
        let w = Int32((width * scale).rounded()), h = Int32((Double(ToastStyle.height) * scale).rounded())
        // Clear of Chromium's scrollbar, which on Windows takes room at the page's edge (the
        // Mac's overlays it).
        let inset = Double(ToastStyle.trailingInset) + Self.scrollbar
        let x = page.right - Int32((inset * scale).rounded()) - w
        let y = page.top + Int32((Double(ToastStyle.topInset) * scale).rounded())
        window.place(origin: PointInt32(x: max(page.left, x), y: y), size: SizeInt32(width: w, height: h))
        window.showInactive()
        restartTimer()
    }

    func hide() {
        try? timer?.stop()
        timer = nil
        action = nil
        window?.hide()
    }

    private func restartTimer(after seconds: TimeInterval = ToastStyle.visibleFor) {
        try? timer?.stop()
        timer = try? WinAppSDK.DispatcherQueue.getForCurrentThread()?.createTimer()
        timer?.interval = TimeSpan(duration: Int64(seconds * 10_000_000))
        timer?.isRepeating = false
        // A pointer on its way to the button keeps it up.
        timer?.tick.addHandler { [weak self] _, _ in
            guard let self else { return }
            if self.window?.hasPointer == true { self.restartTimer(after: 1) } else { self.hide() }
        }
        try? timer?.start()
    }

    private func build() {
        root.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        root.cornerRadius = CornerRadius(topLeft: Double(ToastStyle.cornerRadius), topRight: Double(ToastStyle.cornerRadius),
                                         bottomRight: Double(ToastStyle.cornerRadius), bottomLeft: Double(ToastStyle.cornerRadius))
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = Double(ToastStyle.buttonGap)
        row.verticalAlignment = .center
        row.horizontalAlignment = .center
        label.fontSize = Double(ToastStyle.fontSize)
        label.fontWeight = UWP.FontWeight(weight: 500)
        label.verticalAlignment = .center
        row.children.append(label)
        buttonLabel.fontSize = Double(ToastStyle.buttonFontSize)
        buttonLabel.fontWeight = UWP.FontWeight(weight: 600)
        button = UI.button(buttonLabel, padding: Thickness(left: Double(ToastStyle.buttonPadding), top: 0,
                                                           right: Double(ToastStyle.buttonPadding), bottom: 0)) { [weak self] in
            guard let self, let action = self.action else { return }
            self.hide()
            action.run()
        }
        let capsule = Double(ToastStyle.buttonHeight) / 2
        button.height = Double(ToastStyle.buttonHeight)
        button.cornerRadius = CornerRadius(topLeft: capsule, topRight: capsule, bottomRight: capsule, bottomLeft: capsule)
        button.verticalAlignment = .center
        row.children.append(button)
        root.child = row
    }
}
