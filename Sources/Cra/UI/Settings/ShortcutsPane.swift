import AppKit
import SwiftUI

/// Dia's Shortcuts pane: a search field with filter and more buttons, a 272 pt list card of
/// actions grouped under their menu titles (36 pt rows, shortcut right-aligned), and a detail
/// column with the action's title, description and a black full-width shortcut field.
struct ShortcutsPane: View {
    @Environment(KeyBindingRegistry.self) private var bindings
    @State private var query = ""
    @State private var selectedID: String?
    @State private var customizedOnly = false
    @State private var conflictingOnly = false

    /// Dia's selected shortcut row (sampled 95,144,229 in dark mode; it is not the accent colour).
    private static let selectionFill = Color(.sRGB, red: 95 / 255, green: 144 / 255, blue: 229 / 255, opacity: 1)
    private static let listWidth = SettingsMetrics.shortcutsListWidth
    private static let rowHeight = SettingsMetrics.shortcutsRowHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                SettingsSearchField(text: $query)
                    .frame(height: 26)
                Menu {
                    Toggle("Customized Shortcuts", isOn: $customizedOnly)
                    Toggle("Conflicting Shortcuts", isOn: $conflictingOnly)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 26, height: 26)
                Menu {
                    Button("Reset All Shortcuts") { bindings.resetOverrides() }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 26, height: 26)
            }
            .padding(.horizontal, 19)
            .padding(.top, 19)
            HStack(alignment: .top, spacing: 15) {
                list
                detail
            }
            .padding(.leading, 19)
            .padding(.trailing, 20.5)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: List

    private var visible: [ShortcutsList.Group] {
        ShortcutsList.groups(in: bindings, query: query, customizedOnly: customizedOnly, conflictingOnly: conflictingOnly)
    }

    private var list: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(visible, id: \.title) { group in
                    Text(group.title)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .bottomLeading)
                        .padding(.bottom, 4)
                    ForEach(group.actions) { a in
                        SettingsCardDivider()
                        row(a)
                    }
                }
            }
        }
        .frame(width: Self.listWidth)
        .frame(maxHeight: .infinity)
        // Dia's list card is the window colour with a 1 pt white-6% outline (not the filled card).
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.cardCorner, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }

    private func row(_ a: KeyAction) -> some View {
        let selected = a.id == selectedID
        return Button { selectedID = a.id } label: {
            HStack(spacing: 8) {
                Text(a.name).font(.system(size: 13)).foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 8)
                Text(a.shortcuts.map(\.display).joined(separator: "  "))
                    .font(.system(size: 13)).foregroundStyle(selected ? Color.white : Color.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background(selected ? Self.selectionFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let a = selectedID.flatMap({ bindings.action($0) }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Text(a.name).font(.system(size: 22, weight: .bold))
                    Spacer()
                    Menu {
                        Button("Reset to Default") { bindings.resetShortcuts(for: a.id) }.disabled(!bindings.isOverridden(a.id))
                        Button("Remove Shortcut") { bindings.setShortcuts([], for: a.id) }.disabled(a.shortcuts.isEmpty)
                    } label: {
                        Image(systemName: "gearshape.fill").font(.system(size: 16)).foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                Text(ShortcutDescriptions.text(for: a))
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ShortcutRecorder(action: a)
                if let note = ShortcutsList.conflictNote(bindings.conflicts(of: a)) {
                    Text(note)
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Perform common actions in Cra faster and from anywhere.")
                Text("Select an action to customize its keyboard shortcut.")
            }
            .font(.system(size: 15)).foregroundStyle(.secondary)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Dia's shortcut field: a black 29 pt capsule-cornered bar showing the keys, 15 pt white.
/// Click it, then press the new keys; Esc cancels, ⌫ removes the shortcut.
struct ShortcutRecorder: View {
    let action: KeyAction
    @Environment(KeyBindingRegistry.self) private var bindings
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press keys…" : (action.shortcuts.isEmpty ? "None" : action.shortcuts.map(\.display).joined(separator: "  ")))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(recording ? Color.accentColor : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 29)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(recording ? Color.accentColor : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click, then press the new shortcut. Esc cancels, ⌫ removes it.")
        .onChange(of: action.id) { _, _ in stop() }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            handle(e)
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    private func handle(_ e: NSEvent) {
        if e.keyCode == 53 { stop(); return }                               // esc
        if e.keyCode == 51 || e.keyCode == 117 { bindings.setShortcuts([], for: action.id); stop(); return }  // ⌫ / ⌦
        guard let s = Shortcut.from(event: e) else { return }
        bindings.setShortcuts([s], for: action.id)
        stop()
    }
}

/// NSSearchField, so the field matches Dia's standard search field.
struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = "Search"
        f.delegate = context.coordinator
        f.controlSize = .regular
        f.font = .systemFont(ofSize: 13)
        return f
    }

    func updateNSView(_ v: NSSearchField, context: Context) {
        if v.stringValue != text { v.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSSearchField else { return }
            text.wrappedValue = f.stringValue
        }
    }
}
