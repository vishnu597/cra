#if canImport(CoreGraphics)
import CoreGraphics
#endif
import CraCore
import Foundation
import Testing

/// The Settings window's sidebar and its back/forward pill (Dia 1.54.2).
@MainActor
struct SettingsNavigationTests {
    @Test func opensOnGeneral() {
        let nav = SettingsNavigation()
        #expect(nav.pane == .general && nav.back.isEmpty && nav.forward.isEmpty && !nav.isOpen)
        #expect(SettingsNavigation(pane: .tabs).pane == .tabs)
    }

    @Test func showingAPaneRemembersTheOneBefore() {
        let nav = SettingsNavigation()
        nav.show(.tabs)
        nav.show(.privacy)
        #expect(nav.pane == .privacy && nav.back == [.general, .tabs])
        nav.show(.privacy)
        #expect(nav.back == [.general, .tabs], "the pane already shown adds nothing")
    }

    @Test func backAndForwardWalkTheHistory() {
        let nav = SettingsNavigation()
        nav.show(.tabs)
        nav.show(.advanced)
        nav.goBack()
        #expect(nav.pane == .tabs && nav.forward == [.advanced])
        nav.goBack()
        #expect(nav.pane == .general && nav.back.isEmpty && nav.forward == [.advanced, .tabs])
        nav.goBack()
        #expect(nav.pane == .general, "nothing further back")
        nav.goForward()
        #expect(nav.pane == .tabs && nav.back == [.general])
        nav.show(.profiles)
        #expect(nav.forward.isEmpty, "a new pane drops what was ahead")
        nav.goForward()
        #expect(nav.pane == .profiles)
    }

    @Test func panesHaveTitlesInDiasOrder() {
        #expect(SettingsPane.allCases.map(\.title) == ["General", "Tabs", "Max", "Privacy", "Profiles", "Extensions", "Shortcuts",
                                                       "Performance", "Advanced"])
        #expect(SettingsPane.tabs.id == "tabs")
        #expect(SettingsPane.windowsPanes.allSatisfy { SettingsPane.allCases.contains($0) })
        let order = SettingsPane.windowsPanes.compactMap { SettingsPane.allCases.firstIndex(of: $0) }
        #expect(order == order.sorted(), "in the Mac's order")
        #expect(SettingsPane.windowsPanes == [.general, .tabs, .profiles, .shortcuts])
    }

    /// Dia's measurements: the content column fits beside the sidebar, the form's controls start
    /// after its labels, and cards fit their rows.
    @Test func diasGeometryAddsUp() {
        let content = SettingsMetrics.windowSize.width - SettingsMetrics.sidebarWidth
        #expect(SettingsMetrics.windowSize == CGSize(width: 778, height: 509) && content == 574)
        #expect(SettingsMetrics.formControlX > SettingsMetrics.formLabelWidth && SettingsMetrics.formControlX < content)
        #expect(SettingsMetrics.navPillSize.height < SettingsMetrics.toolbarHeight)
        #expect(SettingsMetrics.paneInset * 2 < content && SettingsMetrics.paneTop > 0 && SettingsMetrics.formTop > 0)
        #expect(SettingsMetrics.cardRowInset * 2 < SettingsMetrics.cardRowHeight && SettingsMetrics.cardCorner > 0)
        #expect(SettingsMetrics.formGroupSpacing > 0)
        // Shortcuts: the list leaves room for the detail column beside it.
        #expect(SettingsMetrics.shortcutsListWidth + SettingsMetrics.shortcutsInset * 2 < content - 200)
        #expect(SettingsMetrics.shortcutsRowHeight == 36)
    }
}
