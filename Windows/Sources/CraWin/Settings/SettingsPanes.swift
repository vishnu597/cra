import CraCore
import Foundation
import UWP
import WinUI

/// A pane's XAML and how to put its controls in step with the settings again.
@MainActor
struct SettingsPaneContent {
    let element: UIElement
    let sync: () -> Void
}

/// The panes the Windows app has so far (SettingsPane.windowsPanes), with the Mac's wording.
/// Rows wait for their feature: Tabs has no Links group until Little Windows and Peek, General no
/// default browser until Cra can be one.
@MainActor
enum SettingsPanes {
    // MARK: General

    /// Dia's card idiom (GeneralPane on the Mac): a "System" card with Cra's place in Windows.
    static func general(palette: SettingsPalette) -> SettingsPaneContent {
        let stack = StackPanel()
        stack.orientation = .vertical
        stack.margin = Thickness(left: Double(SettingsMetrics.paneInset), top: Double(SettingsMetrics.paneTop),
                                 right: Double(SettingsMetrics.paneInset), bottom: 20)
        stack.children.append(header("System", palette: palette))

        let footnote = UI.text("", size: 11, color: palette.error, trimmed: false)
        footnote.textWrapping = .wrap
        footnote.margin = Thickness(left: Double(SettingsMetrics.cardRowInset), top: 6, right: 0, bottom: 0)
        footnote.visibility = .collapsed

        let toggle = ToggleSwitch()
        toggle.onContent = ""
        toggle.offContent = ""
        toggle.minWidth = 0
        toggle.isOn = LaunchAtLogin.isEnabled
        toggle.toggled.addHandler { [weak toggle] _, _ in
            guard let toggle else { return }
            let want = toggle.isOn
            guard want != LaunchAtLogin.isEnabled else { return }
            let error = LaunchAtLogin.set(want)
            footnote.text = error ?? ""
            footnote.visibility = error == nil ? .collapsed : .visible
            // Back to what Windows has (toggled again, which then finds nothing to do).
            if error != nil { toggle.isOn = LaunchAtLogin.isEnabled }
        }
        try? AutomationProperties.setName(toggle, "Open Cra at login")
        stack.children.append(card([cardRow("Open Cra at login", trailing: toggle, palette: palette)], palette: palette))
        stack.children.append(footnote)
        // Task Manager can turn it off while the window is open.
        return SettingsPaneContent(element: stack) {
            let on = LaunchAtLogin.isEnabled
            if toggle.isOn != on { toggle.isOn = on }
        }
    }

    // MARK: Tabs

    /// Dia's two-column form (TabsPane on the Mac): a label per group, checkboxes beside it.
    static func tabs(store: SidebarStore, palette: SettingsPalette) -> SettingsPaneContent {
        var syncs: [() -> Void] = []
        func checkbox(_ title: String, _ key: WritableKeyPath<AppSettings, Bool>) -> CheckBox {
            let box = CheckBox()
            let label = UI.text(title, trimmed: false)
            label.textWrapping = .wrap
            box.content = label
            box.isChecked = store.settings[keyPath: key]
            box.click.addHandler { [weak box] _, _ in
                guard let box else { return }
                let on = box.isChecked == true
                if store.settings[keyPath: key] != on { store.settings[keyPath: key] = on }
            }
            syncs.append {
                let on = store.settings[keyPath: key]
                if box.isChecked != on { box.isChecked = on }
            }
            return box
        }

        let form = Form(palette: palette)
        form.group("General:", [
            checkbox("Add new tabs to the top", \.newTabsAtTop),
            checkbox("Show the New Tab button above tabs", \.newTabButtonAtTop),
        ])
        // Arc's single-space mode ("Hide Space Header" on the space's menu), for people who
        // don't use spaces.
        form.group("Spaces:", [
            checkbox("Show the space header with only one space", \.showSpaceHeaderOnSingleSpace),
            note("Off hides the space’s name and its icon at the bottom of the sidebar while you have one space.", palette: palette),
        ])

        let cleanup = StackPanel()
        cleanup.orientation = .horizontal
        cleanup.spacing = 6
        cleanup.children.append(checkbox("Archive tabs I haven’t used in:", \.autoArchiveEnabled))
        let thresholds = AutoArchiveThreshold.allCases
        let duration = ComboBox()
        duration.verticalAlignment = .center
        for t in thresholds { duration.items.append(t.label) }
        duration.selectedIndex = Int32(thresholds.firstIndex(of: store.settings.autoArchive) ?? 0)
        duration.isEnabled = store.settings.autoArchiveEnabled
        duration.selectionChanged.addHandler { [weak duration] _, _ in
            guard let duration else { return }
            let i = Int(duration.selectedIndex)
            guard thresholds.indices.contains(i), store.settings.autoArchive != thresholds[i] else { return }
            store.settings.autoArchive = thresholds[i]
        }
        try? AutomationProperties.setName(duration, "Archive tabs after")
        syncs.append {
            let i = Int32(thresholds.firstIndex(of: store.settings.autoArchive) ?? 0)
            if duration.selectedIndex != i { duration.selectedIndex = i }
            duration.isEnabled = store.settings.autoArchiveEnabled
        }
        cleanup.children.append(duration)
        form.group("Tab Cleanup:", [cleanup])

        return SettingsPaneContent(element: form.grid) { for sync in syncs { sync() } }
    }

    // MARK: Pieces

    /// Labels end 178.5 DIPs in and controls start at 202, as in Dia's form panes.
    @MainActor
    private final class Form {
        let grid = Grid()
        private let palette: SettingsPalette
        private var rows: Int32 = 0

        init(palette: SettingsPalette) {
            self.palette = palette
            grid.margin = Thickness(left: 0, top: Double(SettingsMetrics.formTop), right: Double(SettingsMetrics.paneInset), bottom: 20)
            grid.rowSpacing = Double(SettingsMetrics.formGroupSpacing)
            grid.columnDefinitions.append(UI.column(UI.pixels(Double(SettingsMetrics.formLabelWidth))))
            grid.columnDefinitions.append(UI.column(UI.pixels(Double(SettingsMetrics.formControlX - SettingsMetrics.formLabelWidth))))
            grid.columnDefinitions.append(UI.column(UI.star))
        }

        func group(_ label: String, _ controls: [UIElement]) {
            grid.rowDefinitions.append(UI.row(UI.auto))
            let title = UI.text(label, color: palette.text, trimmed: false)
            title.horizontalAlignment = .right
            title.verticalAlignment = .top
            // On the first checkbox's text line (a CheckBox is 32 DIPs tall).
            title.margin = Thickness(left: 0, top: 6, right: 0, bottom: 0)
            grid.children.append(title)
            try? Grid.setRow(title, rows)
            let stack = StackPanel()
            stack.orientation = .vertical
            for control in controls { stack.children.append(control) }
            grid.children.append(stack)
            try? Grid.setRow(stack, rows)
            try? Grid.setColumn(stack, 2)
            rows += 1
        }
    }

    private static func header(_ title: String, palette: SettingsPalette) -> TextBlock {
        let t = UI.text(title, size: 13, color: palette.text, trimmed: false)
        t.fontWeight = UWP.FontWeight(weight: 600)
        t.margin = Thickness(left: Double(SettingsMetrics.cardRowInset), top: 0, right: 0, bottom: 8)
        return t
    }

    private static func note(_ text: String, palette: SettingsPalette) -> TextBlock {
        let t = UI.text(text, size: 11, color: palette.secondaryText, trimmed: false)
        t.textWrapping = .wrap
        t.margin = Thickness(left: 28, top: 0, right: 0, bottom: 0)
        return t
    }

    /// Rounded card behind grouped rows, with a hairline between them.
    private static func card(_ rows: [UIElement], palette: SettingsPalette) -> Border {
        let stack = StackPanel()
        stack.orientation = .vertical
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let line = Border()
                line.height = 1
                line.background = palette.hairline
                line.margin = Thickness(left: Double(SettingsMetrics.cardRowInset), top: 0, right: Double(SettingsMetrics.cardRowInset), bottom: 0)
                stack.children.append(line)
            }
            stack.children.append(row)
        }
        let border = Border()
        let corner = Double(SettingsMetrics.cardCorner)
        border.cornerRadius = CornerRadius(topLeft: corner, topRight: corner, bottomRight: corner, bottomLeft: corner)
        border.background = palette.card
        border.child = stack
        return border
    }

    /// Label on the left, control on the right, 43 DIPs tall.
    private static func cardRow(_ title: String, trailing: FrameworkElement, palette: SettingsPalette) -> Grid {
        let row = Grid()
        row.minHeight = Double(SettingsMetrics.cardRowHeight)
        row.padding = Thickness(left: Double(SettingsMetrics.cardRowInset), top: 0, right: Double(SettingsMetrics.cardRowInset), bottom: 0)
        row.columnDefinitions.append(UI.column(UI.star))
        row.columnDefinitions.append(UI.column(UI.auto))
        let label = UI.text(title, color: palette.text)
        label.verticalAlignment = .center
        row.children.append(label)
        trailing.verticalAlignment = .center
        row.children.append(trailing)
        try? Grid.setColumn(trailing, 1)
        return row
    }
}
