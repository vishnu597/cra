import CraCore
import Testing

/// Arc's toast colours, from the space's (ShinyToast on the Mac, ToastView on Windows).
struct ToastStyleTests {
    private func close(_ a: RGB, _ b: RGB) -> Bool {
        abs(a.r - b.r) < 0.001 && abs(a.g - b.g) < 0.001 && abs(a.b - b.b) < 0.001
    }

    @Test func darkSpace() {
        let c = ToastStyle.colors(SpaceTheme(colors: ["#3366CC"], intensity: 1, noise: 0, appearance: "dark"))
        #expect(close(c.top, RGB(0.096, 0.197333, 0.4)))
        #expect(c.text == .white)
        // Darker toward the bottom, darkest at the outline.
        #expect(c.top.b > c.bottom.b && c.bottom.b > c.outline.b)
    }

    @Test func lightSpace() {
        let c = ToastStyle.colors(SpaceTheme(colors: ["#3366CC"], intensity: 1, noise: 0, appearance: "light"))
        #expect(close(c.top, RGB(0.7209, 0.777267, 0.89)))
        #expect(c.text == .black)
        #expect(c.top.b > c.bottom.b && c.bottom.b > c.outline.b)
    }

    /// No colours: a grey toast.
    @Test func noColours() {
        let c = ToastStyle.colors(SpaceTheme(colors: [], intensity: 1, noise: 0, appearance: "dark"))
        #expect(close(c.top, RGB(0.4, 0.4, 0.4)))
        #expect(close(c.outline, RGB(0.24, 0.24, 0.24)))
    }

    /// The mean of the space's colours decides the hue.
    @Test func meanOfColours() {
        let c = ToastStyle.colors(SpaceTheme(colors: ["#FF0000", "#0000FF"], intensity: 1, noise: 0, appearance: "light"))
        #expect(abs(c.top.r - c.top.b) < 0.001)
        #expect(c.top.g < c.top.r)
    }

    @Test func metrics() {
        #expect(ToastStyle.height == 42)
        #expect(ToastStyle.visibleFor == 4.85)
        #expect(ToastStyle.buttonHeight < ToastStyle.height)
    }
}
