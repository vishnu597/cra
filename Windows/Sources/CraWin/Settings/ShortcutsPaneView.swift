import CraCore
import Foundation
import UWP
import WinSDK
import WinUI

/// Dia's Shortcuts pane (ShortcutsPane on the Mac): a search field with filter and more
/// buttons, a 272 DIP list card of actions under their menu titles (36 DIP rows, keys at the
/// right), and a detail column with the action's title, description and a black full-width
/// shortcut field. Click the field, then press the new keys; Esc cancels, Backspace or Delete
/// removes the shortcut.
@MainActor
final class ShortcutsPaneView {
    let root = Grid()
    private let bindings: KeyBindingRegistry
    private let palette: SettingsPalette
    private let search = TextBox()
    private let customizedItem = ToggleMenuFlyoutItem()
    private let conflictingItem = ToggleMenuFlyoutItem()
    private let rows = StackPanel()

    private let detail = StackPanel()
    private let empty = StackPanel()
    private let titleText = UI.text("", size: 22, trimmed: false)
    private let descriptionText = UI.text("", size: 15, trimmed: false)
    private let recorderText = UI.text("", size: 15, trimmed: false)
    private var recorder: Button!
    private let conflictText = UI.text("", size: 11, trimmed: false)
    private let resetItem = MenuFlyoutItem()
    private let removeItem = MenuFlyoutItem()

    private var selectedID: String?
    private var recording = false

    /// Dia's selected shortcut row (sampled 95,144,229 in dark mode; it is not the accent colour).
    private static let selectionFill = UI.brush(95, 144, 229)
    private static let warning = UI.brush(255, 149, 0)
    private static let searchHeight: Double = 32
    private static let gap: Double = 14
    private static let bottom: Double = 20

    init(bindings: KeyBindingRegistry, palette: SettingsPalette) {
        self.bindings = bindings
        self.palette = palette
        let inset = Double(SettingsMetrics.shortcutsInset)
        root.margin = Thickness(left: inset, top: inset, right: 20.5, bottom: Self.bottom)
        root.rowDefinitions.append(UI.row(UI.auto))
        root.rowDefinitions.append(UI.row(UI.auto))
        let top = makeSearchRow()
        root.children.append(top)
        let body = Grid()
        body.margin = Thickness(left: 0, top: Self.gap, right: 0, bottom: 0)
        body.columnDefinitions.append(UI.column(UI.pixels(Double(SettingsMetrics.shortcutsListWidth))))
        body.columnDefinitions.append(UI.column(UI.pixels(15)))
        body.columnDefinitions.append(UI.column(UI.star))
        let list = makeList()
        body.children.append(list)
        let right = makeDetail()
        body.children.append(right)
        try? Grid.setColumn(right, 2)
        root.children.append(body)
        try? Grid.setRow(body, 1)
        render()
    }

    // MARK: Layout

    private func makeSearchRow() -> UIElement {
        let row = Grid()
        row.columnSpacing = 6
        row.columnDefinitions.append(UI.column(UI.star))
        row.columnDefinitions.append(UI.column(UI.auto))
        row.columnDefinitions.append(UI.column(UI.auto))
        search.placeholderText = "Search"
        search.height = Self.searchHeight
        search.isSpellCheckEnabled = false
        search.textChanged.addHandler { [weak self] _, _ in self?.render() }
        try? AutomationProperties.setName(search, "Search shortcuts")
        row.children.append(search)

        let filter = MenuFlyout()
        customizedItem.text = "Customized Shortcuts"
        conflictingItem.text = "Conflicting Shortcuts"
        for item in [customizedItem, conflictingItem] {
            item.click.addHandler { [weak self] _, _ in self?.render() }
            filter.items.append(item)
        }
        let more = MenuFlyout()
        more.items.append(UI.menuItem("Reset All Shortcuts") { [weak self] in self?.bindings.resetOverrides() })
        for (i, (glyph, menu, name)) in [("\u{E71C}", filter, "Filter"), ("\u{E712}", more, "More")].enumerated() {
            let icon = FontIcon()
            icon.glyph = glyph
            icon.fontSize = 13
            icon.foreground = palette.text
            let button = UI.button(icon, padding: Thickness(left: 0, top: 0, right: 0, bottom: 0)) {}
            button.clickMode = .release
            button.width = Self.searchHeight
            button.height = Self.searchHeight
            button.flyout = menu
            try? ToolTipService.setToolTip(button, name)
            try? AutomationProperties.setName(button, name)
            row.children.append(button)
            try? Grid.setColumn(button, Int32(i + 1))
        }
        return row
    }

    /// Dia's list card is the window colour with a hairline outline (not the filled card).
    private func makeList() -> UIElement {
        let card = Border()
        let corner = Double(SettingsMetrics.cardCorner)
        card.cornerRadius = CornerRadius(topLeft: corner, topRight: corner, bottomRight: corner, bottomLeft: corner)
        card.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        card.borderBrush = palette.hairline
        // The window doesn't resize: the card reaches the pane's bottom inset.
        card.height = Double(SettingsMetrics.windowSize.height - SettingsMetrics.toolbarHeight - SettingsMetrics.shortcutsInset)
            - Self.searchHeight - Self.gap - Self.bottom
        let scroll = ScrollViewer()
        scroll.horizontalScrollBarVisibility = .disabled
        scroll.verticalScrollBarVisibility = .auto
        rows.orientation = .vertical
        scroll.content = rows
        card.child = scroll
        return card
    }

    private func makeDetail() -> FrameworkElement {
        let column = Grid()
        detail.orientation = .vertical
        detail.spacing = 14

        let header = Grid()
        header.columnDefinitions.append(UI.column(UI.star))
        header.columnDefinitions.append(UI.column(UI.auto))
        titleText.fontWeight = UWP.FontWeight(weight: 700)
        titleText.foreground = palette.text
        titleText.textWrapping = .wrap
        header.children.append(titleText)
        let gear = FontIcon()
        gear.glyph = "\u{E713}"
        gear.fontSize = 16
        gear.foreground = palette.secondaryText
        let gearButton = UI.button(gear, padding: Thickness(left: 6, top: 4, right: 6, bottom: 4)) {}
        gearButton.clickMode = .release
        gearButton.verticalAlignment = .top
        let menu = MenuFlyout()
        resetItem.text = "Reset to Default"
        resetItem.click.addHandler { [weak self] _, _ in
            guard let self, let id = self.selectedID else { return }
            self.bindings.resetShortcuts(for: id)
        }
        removeItem.text = "Remove Shortcut"
        removeItem.click.addHandler { [weak self] _, _ in
            guard let self, let id = self.selectedID else { return }
            self.bindings.setShortcuts([], for: id)
        }
        menu.items.append(resetItem)
        menu.items.append(removeItem)
        gearButton.flyout = menu
        try? ToolTipService.setToolTip(gearButton, "Shortcut options")
        try? AutomationProperties.setName(gearButton, "Shortcut options")
        header.children.append(gearButton)
        try? Grid.setColumn(gearButton, 1)
        detail.children.append(header)

        descriptionText.foreground = palette.secondaryText
        descriptionText.textWrapping = .wrap
        detail.children.append(descriptionText)

        recorderText.fontWeight = UWP.FontWeight(weight: 600)
        recorderText.horizontalAlignment = .center
        recorder = UI.button(recorderText, fill: UI.brush(0, 0, 0), padding: Thickness(left: 8, top: 0, right: 8, bottom: 0)) { [weak self] in
            guard let self else { return }
            self.recording ? self.stopRecording() : self.startRecording()
        }
        recorder.height = 29
        // Stays black under the pointer (WinUI's hover fill would hide the white keys).
        _ = recorder.resources.insert("ButtonBackgroundPointerOver", UI.brush(28, 28, 28))
        _ = recorder.resources.insert("ButtonBackgroundPressed", UI.brush(40, 40, 40))
        recorder.horizontalAlignment = .stretch
        recorder.horizontalContentAlignment = .center
        recorder.cornerRadius = CornerRadius(topLeft: 8, topRight: 8, bottomRight: 8, bottomLeft: 8)
        recorder.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        try? ToolTipService.setToolTip(recorder, "Click, then press the new shortcut. Esc cancels, Backspace removes it.")
        try? AutomationProperties.setName(recorder, "Shortcut")
        recorder.previewKeyDown.addHandler { [weak self] _, args in
            guard let self, let args, self.recording else { return }
            args.handled = true
            self.record(Int32(truncatingIfNeeded: args.key.rawValue))
        }
        recorder.lostFocus.addHandler { [weak self] _, _ in self?.stopRecording() }
        detail.children.append(recorder)

        conflictText.foreground = Self.warning
        conflictText.textWrapping = .wrap
        detail.children.append(conflictText)

        empty.orientation = .vertical
        empty.spacing = 14
        empty.margin = Thickness(left: 0, top: 14, right: 0, bottom: 0)
        for line in ["Perform common actions in Cra faster and from anywhere.", "Select an action to customize its keyboard shortcut."] {
            let t = UI.text(line, size: 15, color: palette.secondaryText, trimmed: false)
            t.textWrapping = .wrap
            empty.children.append(t)
        }
        column.children.append(detail)
        column.children.append(empty)
        return column
    }

    // MARK: Drawing

    /// The list and the detail for the current bindings, search and selection. Called whenever
    /// the bindings change (SettingsWindow's refresh tracks what this reads).
    func render() {
        let groups = ShortcutsList.groups(in: bindings, query: search.text, customizedOnly: customizedItem.isChecked,
                                          conflictingOnly: conflictingItem.isChecked)
        rows.children.clear()
        for group in groups {
            let title = UI.text(group.title, size: 11, color: palette.secondaryText)
            title.fontWeight = UWP.FontWeight(weight: 600)
            title.verticalAlignment = .bottom
            title.margin = Thickness(left: 10, top: 0, right: 0, bottom: 4)
            let header = Border()
            header.height = Double(SettingsMetrics.shortcutsRowHeight)
            header.child = title
            rows.children.append(header)
            for action in group.actions {
                let line = Border()
                line.height = 1
                line.background = palette.hairline
                rows.children.append(line)
                rows.children.append(row(action))
            }
        }
        renderDetail()
    }

    private func row(_ action: KeyAction) -> Button {
        let selected = action.id == selectedID
        let content = Grid()
        content.columnSpacing = 8
        content.columnDefinitions.append(UI.column(UI.star))
        content.columnDefinitions.append(UI.column(UI.auto))
        let name = UI.text(action.name, color: selected ? palette.onAccent : palette.text)
        name.verticalAlignment = .center
        content.children.append(name)
        let keys = UI.text(action.shortcuts.map(\.windowsDisplay).joined(separator: "  "),
                           color: selected ? palette.onAccent : palette.secondaryText)
        keys.verticalAlignment = .center
        content.children.append(keys)
        try? Grid.setColumn(keys, 1)
        let button = UI.button(content, fill: selected ? Self.selectionFill : nil,
                               padding: Thickness(left: 10, top: 0, right: 10, bottom: 0)) { [weak self] in
            guard let self else { return }
            self.stopRecording()
            self.selectedID = action.id
            self.render()
        }
        if selected {
            _ = button.resources.insert("ButtonBackgroundPointerOver", Self.selectionFill)
            _ = button.resources.insert("ButtonBackgroundPressed", Self.selectionFill)
        }
        button.height = Double(SettingsMetrics.shortcutsRowHeight)
        button.horizontalAlignment = .stretch
        button.horizontalContentAlignment = .stretch
        button.cornerRadius = CornerRadius(topLeft: 0, topRight: 0, bottomRight: 0, bottomLeft: 0)
        try? AutomationProperties.setName(button, action.name)
        return button
    }

    private func renderDetail() {
        guard let action = selectedID.flatMap({ bindings.action($0) }) else {
            detail.visibility = .collapsed
            empty.visibility = .visible
            return
        }
        detail.visibility = .visible
        empty.visibility = .collapsed
        titleText.text = action.name
        descriptionText.text = ShortcutDescriptions.text(for: action)
        resetItem.isEnabled = bindings.isOverridden(action.id)
        removeItem.isEnabled = !action.shortcuts.isEmpty
        recorderText.text = recording ? "Press keys…" : action.shortcuts.isEmpty ? "None" : action.shortcuts.map(\.windowsDisplay).joined(separator: "  ")
        recorderText.foreground = recording ? palette.accent : palette.onAccent
        recorder.borderBrush = recording ? palette.accent : UI.clear
        let note = ShortcutsList.conflictNote(bindings.conflicts(of: action))
        conflictText.text = note ?? ""
        conflictText.visibility = note == nil ? .collapsed : .visible
    }

    // MARK: Recording

    private func startRecording() {
        recording = true
        _ = try? recorder.focus(.programmatic)
        renderDetail()
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        renderDetail()
    }

    /// A key while recording: Esc cancels, Backspace or Delete alone removes the shortcut, a
    /// modifier on its own waits for the rest, anything else becomes the shortcut.
    private func record(_ vk: Int32) {
        guard let id = selectedID else { return stopRecording() }
        let control = Self.isDown(0x11), shift = Self.isDown(0x10), alt = Self.isDown(0x12)
        let windows = Self.isDown(0x5B) || Self.isDown(0x5C)
        let bare = !control && !alt && !shift && !windows
        switch vk {
        case 0x1B: stopRecording()                                                 // Esc
        case 0x08 where bare, 0x2E where bare:                                     // Backspace, Delete
            recording = false
            bindings.setShortcuts([], for: id)
            renderDetail()
        default:
            guard let chord = KeyChord.recorded(windowsVirtualKey: vk, control: control, shift: shift, alt: alt, windows: windows) else { return }
            recording = false
            bindings.setShortcuts([chord], for: id)
            renderDetail()
        }
    }

    private static func isDown(_ virtualKey: Int32) -> Bool { GetKeyState(virtualKey) < 0 }
}
