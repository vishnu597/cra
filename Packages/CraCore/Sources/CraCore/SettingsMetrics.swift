// CGFloat and CGSize come from Foundation off Apple platforms (Windows, Linux).
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Geometry of Dia 1.54.2's Settings window, measured from window captures and the
/// accessibility tree (docs/arc-reverse-engineering.md "Dia Settings window"). Points on the
/// Mac, DIPs on Windows.
public enum SettingsMetrics {
    public static let windowSize = CGSize(width: 778, height: 509)
    public static let sidebarWidth: CGFloat = 204
    public static let toolbarHeight: CGFloat = 52
    public static let navPillSize = CGSize(width: 69, height: 38)
    /// Card panes: cards sit 21 pt from the content edges, 20 pt below the toolbar.
    public static let paneInset: CGFloat = 21
    public static let paneTop: CGFloat = 20
    public static let cardCorner: CGFloat = 12
    public static let cardRowInset: CGFloat = 10
    public static let cardRowHeight: CGFloat = 43
    /// Form panes (Tabs, Advanced): labels end 178.5 pt into the content, controls start at 202.
    public static let formLabelWidth: CGFloat = 178.5
    public static let formControlX: CGFloat = 202
    public static let formTop: CGFloat = 31
    public static let formGroupSpacing: CGFloat = 14
}
