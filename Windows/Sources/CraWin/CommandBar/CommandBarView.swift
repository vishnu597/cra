import CraCore
import Foundation
import UWP
import WinSDK
import WinUI

/// Arc's ⌘T / ⌘L bar on Windows (Ctrl+T, Ctrl+L): the field with the highlighted row's glyph,
/// the scope's pill and its "Search YouTube  Tab" hint, and up to five rows. CraCore ranks the
/// rows (SuggestionEngine) and decides what the field shows and what Return opens; this is the
/// Mac's CommandBarController and CommandTextField for a XAML TextBox.
@MainActor
final class CommandBarView {
    static let width = 766.0
    static let fieldHeight = 60.0
    static let rowHeight = 50.0
    static func height(forRows n: Int) -> Double {
        fieldHeight + (n == 0 ? 0 : Double(n) * rowHeight + Double(n - 1) * 2 + 20)
    }

    /// Return on a row (or on nothing, with text typed): the row, the text it goes to, the mode.
    var onCommit: (Suggestion?, String, CommandBarMode) -> Void = { _, _, _ in }
    /// Ctrl+Return: the row's page in a background tab, the bar staying open. False when the row
    /// opens no page; Return happens instead.
    var onOpenInBackground: (Suggestion?, String) -> Bool = { _, _ in false }
    var onClose: () -> Void = {}
    /// The rows changed: the window takes the new height (`height(forRows:)`).
    var onResize: (Double) -> Void = { _ in }

    let root = Grid()
    private let engine: SuggestionEngine
    private let store: SidebarStore

    private(set) var isOpen = false
    private(set) var mode: CommandBarMode = .newTab
    /// What was typed (or accepted), not the completion shown after it.
    private(set) var query = ""
    private var result = SuggestionResult()
    private var selectedIndex = 0
    /// Arrowed onto a row other than the top: the field shows that row (fieldText).
    private var previewing = false
    private var allowCompletion = true
    private var scope: CommandBarScope?
    /// What was typed when Tab entered the scope; Backspace puts it back.
    private var scopeTyped = ""
    /// The URL Ctrl+L opened with (the page's), nil for Ctrl+T.
    private var openedPrefill: String?
    private var space: SpaceTheme = SpaceTheme.presets[0]

    // The field, as CommandTextField's coordinator keeps it.
    private var lastTyped = ""
    private var pendingCompletion: String?
    /// The text this code put in the field last: TextChanged comes after the change, for
    /// programmatic ones too, and those are not typing.
    private var setText: String?

    private let field = TextBox()
    private let glyph = FontIcon()
    private let pill = Border()
    private let pillLabel = TextBlock()
    private let hint = StackPanel()
    private let hintLabel = TextBlock()
    private let keycap = Border()
    private let keycapLabel = TextBlock()
    private let divider = Border()
    private let rowsPanel = StackPanel()
    private var rows: [Row] = []

    init(engine: SuggestionEngine, store: SidebarStore) {
        self.engine = engine
        self.store = store
        build()
    }

    // MARK: Open and close

    /// Ctrl+T (`newTab`) or Ctrl+L (`editURL`, `prefill` the page's address).
    func open(mode: CommandBarMode, prefill: String?, theme: SpaceTheme) {
        engine.resetIndex()
        self.mode = mode
        space = theme
        scope = nil
        openedPrefill = prefill
        query = prefill ?? ""
        allowCompletion = false
        selectedIndex = 0
        previewing = false
        pendingCompletion = nil
        lastTyped = query
        result = engine.suggestions(for: query, mode: mode, currentTabID: store.selectedTabID)
        isOpen = true
        applyTheme()
        showText(query, selected: true)
        render()
    }

    /// Gives the field the keyboard (after the window is in front).
    func focusField() {
        _ = try? field.focus(.programmatic)
        if !previewing { try? field.selectAll() }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        scope = nil
        engine.resetIndex()
        onClose()
    }

    // MARK: Typing

    private func textChanged() {
        let text = field.text
        guard isOpen, text != setText else { return }
        setText = nil
        let deleting = text.count < lastTyped.count || (pendingCompletion != nil && text == lastTyped)
        lastTyped = text
        pendingCompletion = nil
        update(query: text, allowCompletion: !deleting)
    }

    private func update(query newQuery: String, allowCompletion: Bool) {
        query = newQuery
        self.allowCompletion = allowCompletion
        selectedIndex = 0
        previewing = false
        if let scope {
            switch scope {
            case .site(let site): result = engine.suggestions(for: newQuery, in: site)
            case .tabs: result = engine.suggestions(for: newQuery, inTabsOf: store.focusedSpaceID, currentTabID: store.selectedTabID)
            }
            render()
            return
        }
        // Asked first: while the answer loads, the previous one keeps its rows.
        let typed = newQuery
        engine.fetchSearchSuggestions(for: typed) { [weak self] in
            guard let self, self.isOpen, self.query == typed else { return }
            self.relist()
        }
        result = engine.suggestions(for: newQuery, mode: mode, currentTabID: store.selectedTabID)
        if !allowCompletion { result.inlineCompletion = nil }
        render()
        applyCompletion()
    }

    /// The search engine answered: list again, keeping the selected row where it still is.
    private func relist() {
        guard scope == nil else { return }
        let selectedID = result.items.indices.contains(selectedIndex) ? result.items[selectedIndex].id : nil
        result = engine.suggestions(for: query, mode: mode, currentTabID: store.selectedTabID)
        if !allowCompletion { result.inlineCompletion = nil }
        if let i = result.items.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = i
        } else {
            selectedIndex = 0
            if previewing { showPreview(nil) }
        }
        render()
    }

    /// The completion after what was typed, selected, so typing on replaces it.
    private func applyCompletion() {
        guard !previewing, allowCompletion, let c = result.inlineCompletion else {
            if result.inlineCompletion == nil { pendingCompletion = nil }
            return
        }
        guard pendingCompletion != c else { return }
        let typed = lastTyped
        guard c.lowercased().hasPrefix(typed.lowercased()), c.count > typed.count else { return }
        let remainder = String(c.dropFirst(typed.count))
        pendingCompletion = c
        setText = typed + remainder
        field.text = typed + remainder
        try? field.select(Int32(typed.utf16.count), Int32(remainder.utf16.count))
        render()
    }

    private var completionSelected: Bool { pendingCompletion != nil && field.selectionLength > 0 }

    /// Puts `text` in the field, all selected (a prefill) or with the caret after it.
    private func showText(_ text: String, selected: Bool) {
        setText = text
        field.text = text
        if selected { try? field.selectAll() } else { try? field.select(Int32(text.utf16.count), 0) }
    }

    /// Shows the arrowed-to row's text, or (nil) puts back what was typed.
    private func showPreview(_ text: String?) {
        let shown = text ?? query
        previewing = text != nil
        lastTyped = shown
        pendingCompletion = nil
        showText(shown, selected: false)
    }

    // MARK: Keys

    private func keyDown(_ args: KeyRoutedEventArgs) {
        let vk = Int32(truncatingIfNeeded: args.key.rawValue)
        let control = GetKeyState(0x11) < 0
        switch vk {
        case 0x28: moveSelection(by: 1)  // Down
        case 0x26: moveSelection(by: -1)  // Up
        case 0x0D:  // Return
            acceptSelectedCompletion()
            if control { commitInBackground() } else { commit() }
        case 0x1B:  // Escape: out of a scope back to how the bar opened, else closed (Arc)
            if scope != nil { open(mode: mode, prefill: openedPrefill, theme: space) } else { close() }
        case 0x09:  // Tab: into the offered scope, else accept the completion; never out of the field
            if !enterScope(), completionSelected { collapseCompletion() }
        case 0x27, 0x23:  // Right, End
            guard completionSelected else { return }
            collapseCompletion()
        case 0x08:  // Backspace
            if scope != nil, field.text.isEmpty {
                leaveScope()
            } else if completionSelected {
                // Removes the completion, keeps what was typed.
                let typed = lastTyped
                pendingCompletion = nil
                showText(typed, selected: false)
                update(query: typed, allowCompletion: false)
            } else {
                return
            }
        default:
            return
        }
        args.handled = true
    }

    private func moveSelection(by delta: Int) {
        guard !result.items.isEmpty else { return }
        let n = result.items.count
        selectedIndex = ((selectedIndex + delta) % n + n) % n
        // The top row is what was typed (with its completion).
        showPreview(selectedIndex == 0 ? nil : result.items[selectedIndex].fieldText(typed: query))
        render()
    }

    /// The completion becomes typed text, the caret after it.
    private func collapseCompletion() {
        let text = field.text
        try? field.select(Int32(text.utf16.count), 0)
        lastTyped = text
        pendingCompletion = nil
        update(query: text, allowCompletion: false)
    }

    /// Return with the completion selected goes to the completed text, unless an open tab
    /// supplied it: then Return switches to that tab (Arc 1.171), as CommandTextField does.
    private func acceptSelectedCompletion() {
        guard completionSelected else { return }
        if result.inlineCompletion == pendingCompletion, result.items.first?.tabID != nil { return }
        lastTyped = field.text
        update(query: field.text, allowCompletion: false)
    }

    private func enterScope() -> Bool {
        guard scope == nil, !previewing, let offered = result.scope else { return false }
        scopeTyped = query
        scope = offered
        pushText("")
        return true
    }

    private func leaveScope() {
        guard scope != nil else { return }
        scope = nil
        pushText(scopeTyped)
    }

    private func pushText(_ text: String) {
        lastTyped = text
        pendingCompletion = nil
        showText(text, selected: false)
        update(query: text, allowCompletion: false)
    }

    // MARK: Commit

    private func commit() {
        guard let (row, typed) = result.commit(at: selectedIndex, typed: query, scope: scope) else { return }
        close()
        onCommit(row, typed, mode)
    }

    private func commitInBackground() {
        guard let (row, typed) = result.commit(at: selectedIndex, typed: query, scope: scope) else { return }
        if onOpenInBackground(row, typed) { return }
        close()
        onCommit(row, typed, mode)
    }

    private func commit(row index: Int) {
        guard result.items.indices.contains(index) else { return }
        let row = result.items[index]
        close()
        onCommit(row, query, mode)
    }

    // MARK: Drawing

    private var dark: Bool { space.isDark }
    private var ink: Brush { dark ? UI.brush(255, 255, 255) : UI.brush(20, 20, 24) }
    private var secondaryInk: Brush { dark ? UI.brush(255, 255, 255, alpha: 140) : UI.brush(20, 20, 24, alpha: 140) }

    /// The selected row's tint: a site's brand colour in its scope, else the space's colour.
    private var highlight: Brush {
        if case .site(let site)? = scope { return UI.brush(site.color, alpha: 150) }
        return UI.brush(space.accent ?? space.colors.first ?? "#5C6BC0", alpha: dark ? 140 : 110)
    }

    private func build() {
        for height in [UI.pixels(Self.fieldHeight), UI.auto, UI.star] { root.rowDefinitions.append(UI.row(height)) }

        let top = Grid()
        for width in [UI.pixels(52), UI.auto, UI.star, UI.auto] { top.columnDefinitions.append(UI.column(width)) }
        glyph.fontSize = 18
        glyph.horizontalAlignment = .center
        glyph.verticalAlignment = .center
        pill.cornerRadius = CornerRadius(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6)
        pill.padding = Thickness(left: 8, top: 3, right: 8, bottom: 3)
        pill.margin = Thickness(left: 0, top: 0, right: 8, bottom: 0)
        pill.verticalAlignment = .center
        pillLabel.fontSize = 13
        pillLabel.fontWeight = UWP.FontWeight(weight: 600)
        pillLabel.foreground = UI.brush(255, 255, 255)
        pill.child = pillLabel

        field.fontSize = 18
        field.verticalAlignment = .center
        field.borderThickness = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        field.background = UI.clear
        field.isSpellCheckEnabled = false
        field.isTextPredictionEnabled = false
        // No box around the text, focused or hovered: the bar is the box.
        for key in ["TextControlBackgroundFocused", "TextControlBackgroundPointerOver", "TextControlBorderBrushFocused",
                    "TextControlBorderBrushPointerOver", "TextControlBackground", "TextControlBorderBrush"] {
            _ = field.resources.insert(key, UI.clear)
        }
        field.textChanged.addHandler { [weak self] _, _ in self?.textChanged() }
        field.previewKeyDown.addHandler { [weak self] _, args in
            guard let self, let args else { return }
            self.keyDown(args)
        }

        hint.orientation = .horizontal
        hint.spacing = 8
        hint.verticalAlignment = .center
        hint.margin = Thickness(left: 8, top: 0, right: 16, bottom: 0)
        hintLabel.fontSize = 13
        hintLabel.fontWeight = UWP.FontWeight(weight: 600)
        hintLabel.verticalAlignment = .center
        keycap.cornerRadius = CornerRadius(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6)
        keycap.padding = Thickness(left: 7, top: 2, right: 7, bottom: 2)
        keycapLabel.text = "Tab"
        keycapLabel.fontSize = 13
        keycapLabel.fontWeight = UWP.FontWeight(weight: 600)
        keycap.child = keycapLabel
        hint.children.append(hintLabel)
        hint.children.append(keycap)

        let parts: [FrameworkElement] = [glyph, pill, field, hint]
        for (i, part) in parts.enumerated() {
            top.children.append(part)
            try? Grid.setColumn(part, Int32(i))
        }

        divider.height = 1
        rowsPanel.orientation = .vertical
        rowsPanel.spacing = 2
        rowsPanel.padding = Thickness(left: 10, top: 10, right: 10, bottom: 10)
        for i in 0..<SuggestionEngine.maxRows {
            let row = Row()
            row.root.pointerPressed.addHandler { [weak self] _, _ in self?.commit(row: i) }
            row.root.pointerEntered.addHandler { [weak self] _, _ in
                guard let self, self.selectedIndex != i, self.result.items.indices.contains(i) else { return }
                self.selectedIndex = i
                self.render()
            }
            rows.append(row)
            rowsPanel.children.append(row.root)
        }

        let sections: [FrameworkElement] = [top, divider, rowsPanel]
        for (i, part) in sections.enumerated() {
            root.children.append(part)
            try? Grid.setRow(part, Int32(i))
        }
    }

    private func applyTheme() {
        root.requestedTheme = dark ? .dark : .light
        root.background = dark ? UI.brush(32, 32, 36) : UI.brush(249, 249, 251)
        field.foreground = ink
        glyph.foreground = secondaryInk
        divider.background = dark ? UI.brush(255, 255, 255, alpha: 20) : UI.brush(0, 0, 0, alpha: 20)
        hintLabel.foreground = dark ? UI.brush(255, 255, 255, alpha: 85) : UI.brush(0, 0, 0, alpha: 85)
        keycapLabel.foreground = dark ? UI.brush(255, 255, 255, alpha: 170) : UI.brush(0, 0, 0, alpha: 170)
        keycap.background = dark ? UI.brush(255, 255, 255, alpha: 12) : UI.brush(0, 0, 0, alpha: 10)
    }

    private func render() {
        let items = result.items
        field.placeholderText = scope != nil ? "Search…" : mode == .newTab ? "Search or enter URL…" : "Edit URL or search…"
        pill.visibility = scope == nil ? .collapsed : .visible
        if let scope {
            pillLabel.text = scope.name
            if case .site(let site) = scope { pill.background = UI.brush(site.color) } else {
                pill.background = UI.brush(space.accent ?? space.colors.first ?? "#5C6BC0")
            }
        }
        let offered = scope == nil && !previewing ? result.scope : nil
        hint.visibility = offered == nil ? .collapsed : .visible
        if let offered { hintLabel.text = "Search \(offered.name)" }
        glyph.glyph = WinGlyph.code(leadingSymbol())
        divider.visibility = items.isEmpty ? .collapsed : .visible
        rowsPanel.visibility = items.isEmpty ? .collapsed : .visible
        let tint = highlight
        for (i, row) in rows.enumerated() {
            guard i < items.count else {
                row.root.visibility = .collapsed
                continue
            }
            row.root.visibility = .visible
            row.show(items[i], selected: i == selectedIndex, tint: tint, ink: ink, secondary: secondaryInk)
        }
        onResize(Self.height(forRows: items.count))
    }

    /// The glyph before the text (CommandBarGlyph on the Mac, without favicons yet): what Return
    /// does, the highlighted row's symbol; a magnifier before anything is typed, a globe on Ctrl+L.
    private func leadingSymbol() -> String {
        if scope != nil { return "magnifyingglass" }
        let untouched = !previewing && (query.isEmpty || query == openedPrefill)
        if untouched { return mode == .editURL && openedPrefill != nil ? "globe" : "magnifyingglass" }
        guard result.items.indices.contains(selectedIndex) else { return "magnifyingglass" }
        return WinGlyph.symbol(for: result.items[selectedIndex])
    }

    /// One row: glyph, title, " — " and the subtitle, and what Return does at the end.
    @MainActor
    final class Row {
        let root = Border()
        private let grid = Grid()
        private let icon = FontIcon()
        private let title = TextBlock()
        private let subtitle = TextBlock()
        private let trailing = TextBlock()

        init() {
            root.height = CommandBarView.rowHeight
            root.cornerRadius = CornerRadius(topLeft: 8, topRight: 8, bottomRight: 8, bottomLeft: 8)
            root.padding = Thickness(left: 12, top: 0, right: 14, bottom: 0)
            root.background = UI.clear
            for width in [UI.pixels(32), UI.auto, UI.star, UI.auto] { grid.columnDefinitions.append(UI.column(width)) }
            icon.fontSize = 16
            icon.verticalAlignment = .center
            icon.horizontalAlignment = .left
            title.fontSize = 14
            title.fontWeight = UWP.FontWeight(weight: 600)
            title.textTrimming = .characterEllipsis
            title.verticalAlignment = .center
            title.maxWidth = 420
            subtitle.fontSize = 13
            subtitle.textTrimming = .characterEllipsis
            subtitle.verticalAlignment = .center
            trailing.fontSize = 13
            trailing.verticalAlignment = .center
            trailing.margin = Thickness(left: 12, top: 0, right: 0, bottom: 0)
            let parts: [FrameworkElement] = [icon, title, subtitle, trailing]
            for (i, part) in parts.enumerated() {
                grid.children.append(part)
                try? Grid.setColumn(part, Int32(i))
            }
            root.child = grid
        }

        func show(_ s: Suggestion, selected: Bool, tint: Brush, ink: Brush, secondary: Brush) {
            root.background = selected ? tint : UI.clear
            icon.glyph = WinGlyph.code(WinGlyph.symbol(for: s))
            icon.foreground = selected ? ink : secondary
            title.text = s.title
            title.foreground = ink
            subtitle.text = s.subtitle.isEmpty ? "" : "  —  \(s.subtitle)"
            subtitle.foreground = secondary
            trailing.text = s.trailing.map { s.tabID != nil ? "\($0)  →" : $0 } ?? ""
            trailing.foreground = selected ? ink : secondary
        }
    }
}
