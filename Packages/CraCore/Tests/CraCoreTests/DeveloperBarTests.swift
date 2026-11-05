import CraCore
import Testing

/// Arc's Developer Mode bar colours and stripes (GitHub #42, #88), shared by the Mac's
/// PaneToolbarView and Windows' DeveloperBarView. Expected values worked out separately in
/// Python from the same OKLab formulas.
struct DeveloperBarTests {
    private func close(_ c: RGB, _ r: Double, _ g: Double, _ b: Double) -> Bool {
        abs(c.r * 255 - r) < 1 && abs(c.g * 255 - g) < 1 && abs(c.b * 255 - b) < 1
    }

    @Test func jyskLandsWhereArcWasMeasured() {
        let jysk = SpaceTheme(colors: ["#010220"], intensity: 1, noise: 0, appearance: "dark")
        let bar = jysk.developerBar, secondary = jysk.developerSecondary
        #expect(close(bar, 44, 72, 206), "the bar: Arc's focus colour over black (44/72/206)")
        #expect(close(secondary, 107, 145, 255), "the dividers' colour at OKLab L 0.68")
        let ink = jysk.developerInk
        #expect(close(ink, 240.2, 242.2, 251.5), "near white with 7 % of the bar")
    }

    @Test func theAccentWinsAndGreysStayGrey() {
        let accented = SpaceTheme(colors: ["#808080"], intensity: 1, noise: 0, appearance: "dark", accent: "#010220")
        let bar = accented.developerBar
        #expect(close(bar, 44, 72, 206), "the accent, not the first stop")
        let grey = SpaceTheme(colors: ["#808080"], intensity: 1, noise: 0, appearance: "light").developerBar
        #expect(close(grey, 92, 92, 92), "a grey space gets a grey bar")
        #expect(grey.r == grey.g && grey.g == grey.b)
        let none = SpaceTheme(colors: [], intensity: 1, noise: 0, appearance: "light").developerBar
        #expect(none == grey, "no colour at all reads as grey")
    }

    @Test func stripesCoverTheBarEveryFortyFivePoints() {
        let bands = DeveloperStripes.bands(width: 200, height: 40)
        let first = bands.first ?? []
        #expect(bands.count == 7)
        #expect(first.count == 4)
        // The first band starts left of the bar, 14.5 pt plus whole pitches back.
        #expect(first.first?.x == 14.5 - 45 * 2)
        #expect(first.first?.y == 0 && first.last?.y == 40)
        // No band is left out on the left: one more pitch back would miss the bar entirely.
        #expect(first[2].x - 45 <= 0 && first[2].x > -45)
        let lefts = bands.compactMap { $0.first?.x }
        #expect(zip(lefts, lefts.dropFirst()).allSatisfy { $1 - $0 == 45 })
        #expect((lefts.last ?? 0) < 200 && (lefts.last ?? 0) + 45 >= 200)
        #expect(bands.allSatisfy { $0[1].x - $0[0].x == 21 && $0[2].x - $0[1].x == 40 })
        #expect(DeveloperStripes.bands(width: 0, height: 40).isEmpty)
    }
}

/// The ring round a Developer Mode site's open tab (GitHub #139).
struct DeveloperTabRingTests {
    @Test(arguments: [
        (200.0, 30.0, 441.115 / 60),  // a narrow sidebar: 1/60 of the path
        (300.0, 30.0, 641.115 / 80),
        (400.0, 30.0, 841.115 / 100),
        (100.0, 10.0, 211.416 / 60),  // a short row rounds by half its height
    ])
    func dashesFollowThePathsLength(width: Double, height: Double, dash: Double) {
        #expect(abs(DeveloperTabRing.dash(width: width, height: height) - dash) < 0.001)
    }

    @Test func cornersAndEmptyRings() {
        #expect(DeveloperTabRing.cornerRadius(width: 200, height: 30) == 11)
        #expect(DeveloperTabRing.cornerRadius(width: 200, height: 10) == 5)
        #expect(DeveloperTabRing.dash(width: 0, height: 30) == 0)
    }
}
