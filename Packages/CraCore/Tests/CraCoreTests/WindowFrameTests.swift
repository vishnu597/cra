import CraCore
import Foundation
import Testing

struct WindowFrameTests {
    @Test func readsAndWritesAppKitsSpelling() {
        let f = WindowFrame(string: "{{120, 80}, {1280, 820}}")
        #expect(f == WindowFrame(x: 120, y: 80, width: 1280, height: 820))
        #expect(f?.string == "{{120, 80}, {1280, 820}}")
        #expect(WindowFrame(x: -1920, y: 0.5, width: 800, height: 600).string == "{{-1920, 0.5}, {800, 600}}")
        // The Mac's own strings read the same way.
        #expect(WindowFrame(string: "{{22.5, -40}, {1100.25, 700}}") == WindowFrame(x: 22.5, y: -40, width: 1100.25, height: 700))
    }

    @Test func nonsenseIsNil() {
        for s in ["", "{{1, 2}, {3}}", "{{a, b}, {c, d}}", "{{0, 0}, {0, 600}}", "{{0, 0}, {800, -1}}", "{{1, 2}, {3, 4}, {5, 6}}"] {
            #expect(WindowFrame(string: s) == nil, "\(s)")
        }
    }

    @Test func aNewWindowCascades() {
        let area = WindowFrame(x: 0, y: 0, width: 1920, height: 1040)
        let f = WindowFrame(x: 100, y: 100, width: 1280, height: 820)
        #expect(f.cascaded(step: 22, within: area) == WindowFrame(x: 122, y: 122, width: 1280, height: 820))
        // Off the bottom right: back to the top left of the work area.
        let low = WindowFrame(x: 600, y: 200, width: 1280, height: 820)
        #expect(low.cascaded(step: 22, within: area) == WindowFrame(x: 22, y: 22, width: 1280, height: 820))
        // Bigger than the screen: shrunk to fit.
        let huge = WindowFrame(x: 0, y: 0, width: 2560, height: 1440)
        #expect(huge.cascaded(step: 22, within: area) == WindowFrame(x: 22, y: 22, width: 1898, height: 1018))
        // A second monitor to the left keeps its own coordinates.
        let left = WindowFrame(x: -1920, y: 0, width: 1920, height: 1040)
        #expect(WindowFrame(x: -1800, y: 50, width: 1000, height: 700).cascaded(step: 22, within: left)
            == WindowFrame(x: -1778, y: 72, width: 1000, height: 700))
    }

    @Test func aFrameOnAMonitorThatIsGoneIsNotReachable() {
        let primary = WindowFrame(x: 0, y: 0, width: 1920, height: 1040)
        #expect(WindowFrame(x: 100, y: 100, width: 1280, height: 820).isReachable(in: [primary]))
        #expect(!WindowFrame(x: -1800, y: 100, width: 1280, height: 820).isReachable(in: [primary]))
        // Mostly off the right edge, but its title bar still shows.
        #expect(WindowFrame(x: 1800, y: 100, width: 1280, height: 820).isReachable(in: [primary]))
        #expect(!WindowFrame(x: 1900, y: 100, width: 1280, height: 820).isReachable(in: [primary]))
        // Title bar above the top or below the bottom of every work area.
        #expect(!WindowFrame(x: 100, y: -200, width: 1280, height: 820).isReachable(in: [primary]))
        #expect(!WindowFrame(x: 100, y: 1030, width: 1280, height: 820).isReachable(in: [primary]))
        #expect(WindowFrame(x: -1800, y: 100, width: 1280, height: 820).isReachable(in: [primary, WindowFrame(x: -1920, y: 0, width: 1920, height: 1080)]))
    }
}
