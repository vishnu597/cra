import CraCore
import Foundation
import UWP
import WindowsFoundation
import WinUI

/// Arc 1.171's profile dialogs (NewProfileDialog and ChangeProfileDialog on the Mac), on Arc's
/// navy card: "Create a new Profile" (a name, then "Which Spaces should use this Profile?") and
/// Spaces ▸ Change Profile ("Change <space>’s Profile", a picker of Default, the other profiles
/// and New Profile). It floats in a window of its own over the page, as the permission prompt
/// does; Escape is Cancel (or Back) and Return the default button.
@MainActor
final class ProfileDialogView {
    static let width = 450.0

    enum Step {
        case name
        case spaces
        case change(Space)
    }

    /// Create Profile with its name and the ticked spaces.
    var onCreate: (String, Set<UUID>) -> Void = { _, _ in }
    /// Change Profile for the space: nil is Default.
    var onChange: (UUID, UUID?) -> Void = { _, _ in }
    var onCancel: () -> Void = {}
    /// The card's content changed height (DIPs): the window fits it again.
    var onResize: (Double) -> Void = { _ in }

    let root = Grid()
    private let content = StackPanel()
    private var step = Step.name
    private var spaces: [Space] = []
    private var profiles: [BrowserProfile] = []
    private var ticked: Set<UUID> = []
    /// The spaces step's checkboxes, held so their click handlers' weak captures stay alive (a
    /// WinRT control built from Swift is only a wrapper, gone once nothing in Swift holds it).
    private var boxes: [CheckBox] = []
    private let nameField = TextBox()
    /// Change Profile's picker: Default, the profiles, New Profile.
    private let picker = ComboBox()
    private var primary: Button?
    /// The space Change Profile was opened for, kept ticked if it goes on to New Profile.
    private var changing: Space?

    private static let card = UI.brush("#161C2F")
    private static let body = UI.brush("#B8B9C4")
    private static let white = UI.brush(255, 255, 255)
    private static let muted = UI.brush("#8F929E")

    init() {
        root.background = Self.card
        root.requestedTheme = .dark
        root.padding = Thickness(left: 37, top: 30, right: 37, bottom: 24)
        content.orientation = .vertical
        root.children.append(content)
        nameField.placeholderText = "Personal"
        nameField.textChanged.addHandler { [weak self] _, _ in self?.updatePrimary() }
        try? AutomationProperties.setName(nameField, "Profile name")
        try? AutomationProperties.setName(picker, "Profile")
        root.previewKeyDown.addHandler { [weak self] _, args in
            guard let self, let args else { return }
            switch Int32(truncatingIfNeeded: args.key.rawValue) {
            case 0x1B: self.back()  // Escape
            case 0x0D: self.confirm()  // Return
            default: return
            }
            args.handled = true
        }
    }

    /// Create a new Profile, with `ticked` spaces chosen on its second step. Returns the height.
    func showNew(spaces: [Space], ticked: Set<UUID>) -> Double {
        self.spaces = spaces
        self.ticked = ticked
        changing = nil
        nameField.text = ""
        return show(.name)
    }

    /// Change `space`'s Profile. Returns the height.
    func showChange(space: Space, profiles: [BrowserProfile], spaces: [Space]) -> Double {
        self.spaces = spaces
        self.profiles = profiles
        changing = space
        ticked = [space.id]
        nameField.text = ""
        return show(.change(space))
    }

    /// The field or picker takes the keyboard.
    func focus() {
        switch step {
        case .name: _ = try? nameField.focus(.programmatic)
        case .spaces: _ = try? primary?.focus(.programmatic)
        case .change: _ = try? picker.focus(.programmatic)
        }
    }

    private var trimmedName: String { nameField.text.trimmingCharacters(in: .whitespaces) }

    // MARK: Steps

    @discardableResult
    private func show(_ next: Step) -> Double {
        step = next
        content.children.clear()
        primary = nil
        switch next {
        case .name: buildName()
        case .spaces: buildSpaces()
        case .change(let space): buildChange(space)
        }
        updatePrimary()
        try? root.measure(WindowsFoundation.Size(width: Float(Self.width), height: .infinity))
        return Double(root.desiredSize.height).rounded(.up)
    }

    private func buildName() {
        content.children.append(avatar())
        content.children.append(title("Create a new Profile"))
        content.children.append(paragraph("Profiles make your Spaces truly separate — with their own history, saved passwords, extensions, and other browsing data. No more flipping between work and personal accounts!"))
        let ask = paragraph("What do you want to call this Profile?")
        ask.margin = Thickness(left: 0, top: 20, right: 0, bottom: 8)
        content.children.append(ask)
        content.children.append(nameField)
        let note = UI.text("Profiles are not synced between computers.", size: 12, color: Self.muted, trimmed: false)
        note.margin = Thickness(left: 0, top: 10, right: 0, bottom: 0)
        content.children.append(note)
        let next = spaces.isEmpty ? "Create Profile" : "Next"
        content.children.append(buttons(secondary: "Cancel", primary: next))
    }

    private func buildSpaces() {
        content.children.append(title("Which Spaces should use this Profile?"))
        content.children.append(paragraph("These Spaces will start fresh in your brand new Profile — so you’ll have to log back in to websites, re-save your passwords, add extensions, etc. You can always switch back to your previous Profile though if you forgot something!"))
        let list = StackPanel()
        list.orientation = .vertical
        list.margin = Thickness(left: 0, top: 16, right: 0, bottom: 0)
        boxes = []
        for space in spaces {
            let box = CheckBox()
            let label = UI.text("\(space.emoji) \(space.title)", size: 14, color: Self.white)
            box.content = label
            box.isChecked = ticked.contains(space.id)
            box.click.addHandler { [weak self, weak box] _, _ in
                guard let self, let box else { return }
                if box.isChecked == true { self.ticked.insert(space.id) } else { self.ticked.remove(space.id) }
            }
            list.children.append(box)
            boxes.append(box)
        }
        let scroll = ScrollViewer()
        scroll.maxHeight = 220
        scroll.content = list
        content.children.append(scroll)
        content.children.append(buttons(secondary: "Back", primary: "Create Profile"))
    }

    private func buildChange(_ space: Space) {
        content.children.append(avatar(space.emoji))
        content.children.append(title("Change \(space.title)’s Profile"))
        content.children.append(paragraph("Each Profile has different browser data, so you might get logged out of some websites, see different Favorites up top, or need to re-install extensions."))
        let label = paragraph("\(space.title)’s Profile")
        label.margin = Thickness(left: 0, top: 20, right: 0, bottom: 8)
        content.children.append(label)
        picker.items.clear()
        picker.items.append("Default")
        for p in profiles { picker.items.append(p.name) }
        picker.items.append("New Profile")
        let current = space.profileID.flatMap { id in profiles.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        picker.selectedIndex = Int32(current)
        picker.minWidth = 220
        content.children.append(picker)
        content.children.append(buttons(secondary: "Cancel", primary: "Change Profile"))
    }

    // MARK: Actions

    /// A step changed inside the dialog: the window fits its new height and the step takes the
    /// keyboard.
    private func go(_ next: Step) {
        onResize(show(next))
        focus()
    }

    private func back() {
        switch step {
        case .spaces: go(.name)
        case .name where changing != nil: if let space = changing { go(.change(space)) }
        default: onCancel()
        }
    }

    private func confirm() {
        switch step {
        case .name:
            guard !trimmedName.isEmpty else { return }
            if spaces.isEmpty { onCreate(trimmedName, []) } else { go(.spaces) }
        case .spaces:
            onCreate(trimmedName, ticked)
        case .change(let space):
            let i = Int(picker.selectedIndex)
            if i == profiles.count + 1 {
                // New Profile: on to Create a new Profile, with this space ticked.
                go(.name)
            } else if i >= 0 {
                onChange(space.id, i == 0 ? nil : profiles[i - 1].id)
            }
        }
    }

    private func updatePrimary() {
        guard case .name = step else {
            primary?.isEnabled = true
            return
        }
        primary?.isEnabled = !trimmedName.isEmpty
    }

    // MARK: Pieces

    private func title(_ text: String) -> TextBlock {
        let t = UI.text(text, size: 17.5, color: Self.white, trimmed: false)
        t.fontWeight = UWP.FontWeight(weight: 600)
        t.textWrapping = .wrap
        t.margin = Thickness(left: 0, top: 19, right: 0, bottom: 0)
        return t
    }

    private func paragraph(_ text: String) -> TextBlock {
        let t = UI.text(text, size: 14, color: Self.body, trimmed: false)
        t.textWrapping = .wrap
        t.margin = Thickness(left: 0, top: 12, right: 0, bottom: 0)
        return t
    }

    /// Arc's smiley avatar on a blue tile (the space's emoji on Change Profile).
    private func avatar(_ emoji: String? = nil) -> UIElement {
        let tile = Border()
        tile.width = 62
        tile.height = 62
        tile.cornerRadius = CornerRadius(topLeft: 14, topRight: 14, bottomRight: 14, bottomLeft: 14)
        tile.background = UI.brush("#2E36E7")
        tile.horizontalAlignment = .left
        if let emoji, !emoji.isEmpty {
            let mark = UI.text(emoji, size: 28, color: Self.white, trimmed: false)
            mark.horizontalAlignment = .center
            mark.verticalAlignment = .center
            tile.child = mark
        } else {
            let icon = FontIcon()
            icon.glyph = "\u{E77B}"  // Contact
            icon.fontSize = 28
            icon.foreground = Self.white
            tile.child = icon
        }
        return tile
    }

    private func buttons(secondary: String, primary title: String) -> UIElement {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 8
        row.horizontalAlignment = .right
        row.margin = Thickness(left: 0, top: 26, right: 0, bottom: 0)
        let cancel = Button()
        cancel.content = UI.text(secondary, trimmed: false)
        cancel.minWidth = 96
        cancel.clickMode = .press
        cancel.click.addHandler { [weak self] _, _ in self?.back() }
        let ok = Button()
        ok.content = UI.text(title, color: Self.white, trimmed: false)
        ok.minWidth = 120
        // The default button, in Windows' accent colour (WinUI's AccentButtonStyle).
        let accent = WinAppearance.accent
        ok.background = UI.brush(accent.r, accent.g, accent.b)
        _ = ok.resources.insert("ButtonBackgroundPointerOver", UI.brush(accent.r, accent.g, accent.b, alpha: 230))
        _ = ok.resources.insert("ButtonBackgroundPressed", UI.brush(accent.r, accent.g, accent.b, alpha: 205))
        _ = ok.resources.insert("ButtonForegroundPointerOver", Self.white)
        _ = ok.resources.insert("ButtonForegroundPressed", Self.white)
        ok.clickMode = .press
        ok.click.addHandler { [weak self] _, _ in self?.confirm() }
        row.children.append(cancel)
        row.children.append(ok)
        primary = ok
        return row
    }
}
