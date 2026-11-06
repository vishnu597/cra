import Foundation

// In a file of its own, so PeekLayout.swift compiles alone (scripts/test-peek-dim-panel.sh) while
// this reads the toolbar's and themes' colours (ToolbarColor, HexColor, RGB).
extension PeekLayout {
    /// The Peek card's bar in the page's colour (PaneToolbarView's for a page card): the colour the
    /// page reported, else white; dark ink on a light bar (luminance over 0.6), Arc's sand on a dark one.
    public struct BarColors: Equatable, Sendable {
        public var fill: RGB
        public var light: Bool
        /// The address.
        public var ink: RGB
        public var inkAlpha: Double
        /// The buttons and the path after the host.
        public var dimInk: RGB
        public var dimInkAlpha: Double
        /// A button under the pointer: white at this alpha over the bar.
        public static let hoverAlpha = 0.1

        public init(reported: String?) {
            let hex = ToolbarColor.hex(reported: reported, remembered: nil)
            let c = hex.flatMap(HexColor.components)
            fill = c.map { RGB($0.r, $0.g, $0.b) } ?? .white
            light = (hex.flatMap(HexColor.luminance) ?? 1) > 0.6
            if light {
                (ink, inkAlpha, dimInk, dimInkAlpha) = (.black, 0.8, .black, 0.6)
            } else {
                (ink, inkAlpha) = (RGB(0xE4 / 255.0, 0xE0 / 255.0, 0xD4 / 255.0), 1)
                (dimInk, dimInkAlpha) = (RGB(0xF0 / 255.0, 0xE6 / 255.0, 0xCC / 255.0), 0.9)
            }
        }
    }
}
