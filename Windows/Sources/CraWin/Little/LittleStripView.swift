import CraCore
import Foundation
import UWP
import WinSDK
import WinUI

/// The Little Window's navy strip (the Mac's LittleToolbarView, Arc's Little Arc): one
/// full-width pill with the page's host, which opens the command bar, the profile chip and the
/// copy-link button at its end, then the split "Open in <Space> Ctrl+O | ⌄" button. CraCore's
/// LittleWindowLayout has its measurements and colours. HostWindow shows it in its strip over the
/// page.
@MainActor
final class LittleStripView {
    var onOpenCommandBar: () -> Void = {}
    var onCopyURL: () -> Void = {}
    /// "Open in <Space>": the page goes into the space named (nothing without a page, as on the
    /// Mac; never disabled, which WinUI draws as a grey block).
    var onPromote: () -> Void = {}
    /// The chevron: the other spaces.
    var onMoreSpaces: () -> Void = {}
    var onProfileMenu: () -> Void = {}
    /// A key the strip doesn't use itself (it has the keyboard after a click): Cra's shortcuts.
    var onKey: (KeyPress) -> Bool = { _ in false }

    let root = Grid()
    private let pill = Grid()
    private var pillButton: Button!
    private let urlLabel = TextBlock()
    private let search = FontIcon()
    private var link: Button!
    private var profileChip: Button!
    private let profileLabel = TextBlock()
    private let openLabel = TextBlock()
    private let spaceLabel = TextBlock()
    private let badgeLabel = TextBlock()
    private var openButton: Button!
    private var chevron: Button!

    private typealias L = LittleWindowLayout

    init() {
        build()
    }

    /// The page's address, the space "Open in" names, and the page's profile (nil hides the
    /// chip: Arc shows it only once there is a profile besides Default).
    func show(url: String, space: Space, profile: String?) {
        urlLabel.text = url.isEmpty ? "" : SuggestionEngine.humanURL(url)
        try? ToolTipService.setToolTip(pillButton, url.isEmpty ? "Search or Enter URL…" : url)
        profileChip.visibility = profile == nil ? .collapsed : .visible
        profileLabel.text = profile ?? ""
        try? AutomationProperties.setName(profileChip, "Profile: \(profile ?? "Default")")
        spaceLabel.text = space.title
        spaceLabel.foreground = brush(L.spaceNameColor(space.theme))
        let key = WinKeyBindings.shared.action("promoteLittleWindow")?.primary?.windowsDisplay
        badgeLabel.text = key ?? ""
        badgeLabel.visibility = key == nil ? .collapsed : .visible
        let tip = "Open this page in \(space.title) as a tab" + (key.map { " (\($0))" } ?? "")
        try? ToolTipService.setToolTip(openButton, tip)
        try? AutomationProperties.setName(openButton, "Open in \(space.title)")
    }

    // MARK: Layout

    private func build() {
        root.height = Double(L.barHeight)
        root.background = brush(L.Palette.bar)
        root.requestedTheme = .dark
        // 7 in, the pill, 10, the button, 7 from the edge; both 30 high, 8 from the top.
        for width in [UI.pixels(Double(L.rightMargin)), UI.star, UI.pixels(Double(L.pillGap)), UI.auto, UI.pixels(Double(L.rightMargin))] {
            root.columnDefinitions.append(UI.column(width))
        }
        buildPill()
        root.children.append(pill)
        try? Grid.setColumn(pill, 1)
        let open = buildOpenButton()
        root.children.append(open)
        try? Grid.setColumn(open, 3)

        // Cra's shortcuts while the strip has the keyboard (the page reports its own).
        root.keyDown.addHandler { [weak self] _, args in
            guard let self, let args, !args.handled else { return }
            let key = KeyPress(keyCode: Int32(truncatingIfNeeded: args.key.rawValue), control: GetKeyState(0x11) < 0,
                               shift: GetKeyState(0x10) < 0, alt: GetKeyState(0x12) < 0)
            if self.onKey(key) { args.handled = true }
        }
    }

    /// The pill: a magnifier, the host centred, then the profile chip and the copy-link button
    /// over its end (Arc's puzzle piece waits for extensions).
    private func buildPill() {
        pill.height = Double(L.controlHeight)
        pill.verticalAlignment = .center

        let inside = Grid()
        inside.columnDefinitions.append(UI.column(UI.pixels(34)))
        inside.columnDefinitions.append(UI.column(UI.star))
        inside.columnDefinitions.append(UI.column(UI.pixels(34)))
        search.glyph = "\u{E721}"  // Search
        search.fontSize = 12
        search.foreground = brush(L.Palette.icon)
        search.horizontalAlignment = .center
        search.verticalAlignment = .center
        inside.children.append(search)
        urlLabel.fontSize = 13
        urlLabel.foreground = brush(L.Palette.text)
        urlLabel.textTrimming = .characterEllipsis
        urlLabel.textAlignment = .center
        urlLabel.horizontalAlignment = .center
        urlLabel.verticalAlignment = .center
        // Clear of the chip and the link button, as the Mac keeps it 80 pt from each end.
        urlLabel.margin = Thickness(left: 46, top: 0, right: 46, bottom: 0)
        inside.children.append(urlLabel)
        try? Grid.setColumn(urlLabel, 0)
        try? Grid.setColumnSpan(urlLabel, 3)
        inside.horizontalAlignment = .stretch
        inside.verticalAlignment = .stretch

        pillButton = UI.button(inside, fill: brush(L.Palette.pill), padding: Thickness(left: 0, top: 0, right: 0, bottom: 0)) { [weak self] in
            self?.onOpenCommandBar()
        }
        pillButton.horizontalAlignment = .stretch
        pillButton.verticalAlignment = .stretch
        pillButton.horizontalContentAlignment = .stretch
        pillButton.verticalContentAlignment = .stretch
        round(pillButton, Double(L.pillCornerRadius))
        hover(pillButton, fill: L.Palette.pillHover, ink: L.Palette.text)
        try? AutomationProperties.setName(pillButton, "Address")
        pill.children.append(pillButton)

        let end = StackPanel()
        end.orientation = .horizontal
        end.spacing = 5
        end.horizontalAlignment = .right
        end.verticalAlignment = .center
        end.margin = Thickness(left: 0, top: 0, right: 2, bottom: 0)

        // Arc's ProfileIndicatorView: a face, the name, a chevron, on white 12 %.
        let chip = StackPanel()
        chip.orientation = .horizontal
        chip.spacing = 4
        let face = FontIcon()
        face.glyph = "\u{E77B}"  // Contact
        face.fontSize = 11
        face.foreground = brush(L.Palette.text)
        chip.children.append(face)
        profileLabel.fontSize = 11
        profileLabel.fontWeight = UWP.FontWeight(weight: 500)
        profileLabel.foreground = brush(L.Palette.text)
        profileLabel.verticalAlignment = .center
        chip.children.append(profileLabel)
        let chipChevron = FontIcon()
        chipChevron.glyph = "\u{E70D}"  // ChevronDown
        chipChevron.fontSize = 8
        chipChevron.foreground = brush(L.Palette.text)
        chip.children.append(chipChevron)
        profileChip = UI.button(chip, fill: UI.brush(255, 255, 255, alpha: 31), padding: Thickness(left: 6, top: 0, right: 6, bottom: 0)) {
            [weak self] in self?.onProfileMenu()
        }
        profileChip.height = 22
        round(profileChip, 11)
        _ = profileChip.resources.insert("ButtonBackgroundPointerOver", UI.brush(255, 255, 255, alpha: 46))
        _ = profileChip.resources.insert("ButtonBackgroundPressed", UI.brush(255, 255, 255, alpha: 56))
        profileChip.visibility = .collapsed
        end.children.append(profileChip)

        let linkGlyph = FontIcon()
        linkGlyph.glyph = WinGlyph.code("link")
        linkGlyph.fontSize = 13
        linkGlyph.foreground = brush(L.Palette.icon)
        link = UI.button(linkGlyph, padding: Thickness(left: 0, top: 0, right: 0, bottom: 0)) { [weak self] in self?.onCopyURL() }
        link.width = Double(L.iconSize)
        link.height = Double(L.iconSize)
        round(link, 6)
        hover(link, fill: L.Palette.iconHover, ink: L.Palette.iconHot)
        let copyKey = WinKeyBindings.shared.action("copyURL")?.primary.map { " (\($0.windowsDisplay))" } ?? ""
        try? ToolTipService.setToolTip(link, "Copy URL" + copyKey)
        try? AutomationProperties.setName(link, "Copy URL")
        end.children.append(link)

        pill.children.append(end)
    }

    /// Arc's split button: "Open in <Space>" and the key on the left part, a rule, the chevron.
    private func buildOpenButton() -> Border {
        let frame = Border()
        frame.height = Double(L.controlHeight)
        frame.verticalAlignment = .center
        frame.background = brush(L.Palette.button)
        frame.borderBrush = brush(L.Palette.buttonBorder)
        frame.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        let r = Double(L.buttonCornerRadius)
        frame.cornerRadius = CornerRadius(topLeft: r, topRight: r, bottomRight: r, bottomLeft: r)

        let parts = Grid()
        for width in [UI.auto, UI.pixels(1), UI.pixels(Double(L.chevronWidth) - 1)] { parts.columnDefinitions.append(UI.column(width)) }

        let label = StackPanel()
        label.orientation = .horizontal
        label.verticalAlignment = .center
        openLabel.text = "Open in "
        openLabel.fontSize = 13
        openLabel.fontWeight = UWP.FontWeight(weight: 500)
        openLabel.foreground = brush(L.Palette.label)
        openLabel.verticalAlignment = .center
        label.children.append(openLabel)
        spaceLabel.fontSize = 13
        spaceLabel.fontWeight = UWP.FontWeight(weight: 700)
        spaceLabel.verticalAlignment = .center
        spaceLabel.maxWidth = 180
        spaceLabel.textTrimming = .characterEllipsis
        label.children.append(spaceLabel)
        let badge = Border()
        badge.background = brush(L.Palette.badge)
        badge.cornerRadius = CornerRadius(topLeft: 4, topRight: 4, bottomRight: 4, bottomLeft: 4)
        badge.padding = Thickness(left: 5, top: 1, right: 5, bottom: 1)
        badge.margin = Thickness(left: 6, top: 0, right: 0, bottom: 0)
        badge.verticalAlignment = .center
        badgeLabel.fontSize = 11
        badgeLabel.fontWeight = UWP.FontWeight(weight: 500)
        badgeLabel.foreground = brush(L.Palette.badgeText)
        badge.child = badgeLabel
        label.children.append(badge)
        openButton = UI.button(label, padding: Thickness(left: 10, top: 0, right: 8, bottom: 0)) { [weak self] in self?.onPromote() }
        openButton.verticalAlignment = .stretch
        openButton.cornerRadius = CornerRadius(topLeft: r - 1, topRight: 0, bottomRight: 0, bottomLeft: r - 1)
        hover(openButton, fill: L.Palette.buttonHover, ink: L.Palette.label)
        parts.children.append(openButton)

        let rule = Border()
        rule.background = brush(L.Palette.buttonBorder)
        parts.children.append(rule)
        try? Grid.setColumn(rule, 1)

        let chevronGlyph = FontIcon()
        chevronGlyph.glyph = "\u{E70D}"  // ChevronDown
        chevronGlyph.fontSize = 10
        chevronGlyph.foreground = brush(L.Palette.label)
        chevron = UI.button(chevronGlyph, padding: Thickness(left: 0, top: 0, right: 0, bottom: 0)) { [weak self] in self?.onMoreSpaces() }
        chevron.horizontalAlignment = .stretch
        chevron.verticalAlignment = .stretch
        chevron.cornerRadius = CornerRadius(topLeft: 0, topRight: r - 1, bottomRight: r - 1, bottomLeft: 0)
        hover(chevron, fill: L.Palette.buttonHover, ink: L.Palette.label)
        try? ToolTipService.setToolTip(chevron, "More Spaces")
        try? AutomationProperties.setName(chevron, "More Spaces")
        parts.children.append(chevron)
        try? Grid.setColumn(chevron, 2)

        frame.child = parts
        return frame
    }

    // MARK: Helpers

    private func brush(_ c: (UInt8, UInt8, UInt8)) -> SolidColorBrush { UI.brush(c.0, c.1, c.2) }

    private func brush(_ c: RGB) -> SolidColorBrush {
        UI.brush(UInt8((c.r * 255).rounded()), UInt8((c.g * 255).rounded()), UInt8((c.b * 255).rounded()))
    }

    private func round(_ b: Button, _ r: Double) {
        b.cornerRadius = CornerRadius(topLeft: r, topRight: r, bottomRight: r, bottomLeft: r)
    }

    /// The hover and press fill, keeping the content's own colour (WinUI's default turns it white).
    private func hover(_ b: Button, fill: (UInt8, UInt8, UInt8), ink: (UInt8, UInt8, UInt8)) {
        _ = b.resources.insert("ButtonBackgroundPointerOver", brush(fill))
        _ = b.resources.insert("ButtonBackgroundPressed", brush(fill))
        _ = b.resources.insert("ButtonForegroundPointerOver", brush(ink))
        _ = b.resources.insert("ButtonForegroundPressed", brush(ink))
    }
}
