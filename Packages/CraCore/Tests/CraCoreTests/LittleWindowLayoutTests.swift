import CraCore
import Foundation
import Testing

/// The Little Window's size, placement, colours and the space and profile its page goes with
/// (GitHub #92, #172), shared by the Mac's LittleWindowController and Windows' LittleWindow.
@MainActor
struct LittleWindowLayoutTests {
    @Test func theSizeIsTheLastOneDraggedToNoSmallerThanTheMinimum() {
        #expect(LittleWindowLayout.size(saved: nil) == LittleWindowLayout.defaultSize)
        #expect(LittleWindowLayout.size(saved: "{1200, 800}") == CGSize(width: 1200, height: 800))
        #expect(LittleWindowLayout.size(saved: "{200, 100}") == LittleWindowLayout.minSize)
        #expect(LittleWindowLayout.size(saved: "{1000, 700}") == LittleWindowLayout.defaultSize, "the old default was never a choice")
        #expect(LittleWindowLayout.size(saved: "nonsense") == LittleWindowLayout.defaultSize)
        #expect(LittleWindowLayout.size(saved: "{0, 0}") == LittleWindowLayout.defaultSize)
    }

    /// AppKit's NSStringFromSize, which the Mac writes into settings.json.
    @Test func sizesReadAndWriteAsAppKitDoes() {
        #expect(LittleWindowLayout.sizeString(CGSize(width: 1400, height: 900)) == "{1400, 900}")
        #expect(LittleWindowLayout.sizeString(CGSize(width: 1400.5, height: 900)) == "{1400.5, 900}")
        #expect(LittleWindowLayout.parseSize("{1400.5, 900}") == CGSize(width: 1400.5, height: 900))
        #expect(LittleWindowLayout.parseSize(" {12,34} ") == CGSize(width: 12, height: 34))
        #expect(LittleWindowLayout.parseSize("{12}") == nil)
        #expect(LittleWindowLayout.parseSize("12, 34") == nil)
    }

    @Test func windowsCentreAndCascadeOnTheWorkArea() {
        let area = CGRect(x: 0, y: 0, width: 1920, height: 1040)
        let first = LittleWindowLayout.frame(size: CGSize(width: 1400, height: 900), in: area, index: 0)
        #expect(first == CGRect(x: 260, y: 70, width: 1400, height: 900))
        let second = LittleWindowLayout.frame(size: CGSize(width: 1400, height: 900), in: area, index: 1)
        #expect(second.origin == CGPoint(x: 284, y: 94), "24 right and down, y down")
        // Too big for the screen: 40 clear in all, and never off it however many are open.
        let small = CGRect(x: 100, y: 50, width: 1280, height: 680)
        let big = LittleWindowLayout.frame(size: CGSize(width: 1400, height: 900), in: small, index: 0)
        #expect(big == CGRect(x: 120, y: 70, width: 1240, height: 640))
        let far = LittleWindowLayout.frame(size: CGSize(width: 1400, height: 900), in: small, index: 40)
        #expect(far.maxX <= small.maxX && far.maxY <= small.maxY)
    }

    @Test func theSpaceNameIsItsColourNearlyWhite() {
        let victor = SpaceTheme(colors: ["#F2C230"], intensity: 1, noise: 0, appearance: "light")
        let c = LittleWindowLayout.spaceNameColor(victor)
        #expect(abs(c.r * 255 - (242 + (255 - 242) * 0.72)) < 0.5)
        #expect(abs(c.b * 255 - (48 + (255 - 48) * 0.72)) < 0.5)
        let accented = SpaceTheme(colors: ["#000000"], intensity: 1, noise: 0, appearance: "dark", accent: "#FFFFFF")
        #expect(LittleWindowLayout.spaceNameColor(accented) == .white, "the accent wins")
    }

    @Test func openInNamesTheRequestedSpaceThenTheLastWindowsSpace() {
        let f = StoreFixture()
        let work = f.store.createSpace(title: "Work", emoji: "💼", focus: false)
        #expect(f.store.littleWindowTarget(requested: nil) == f.space.id)
        #expect(f.store.littleWindowTarget(requested: work.id) == work.id)
        #expect(f.store.littleWindowTarget(requested: UUID()) == f.space.id, "a space that's gone")
        #expect(f.store.littleWindowDestination(work.id) == work.id)
        #expect(f.store.littleWindowDestination(UUID()) == f.store.focusedSpaceID)
        let incognito = f.store.addIncognitoWindow(frame: nil)
        let privateSpace = f.store.focusedSpaceID(window: incognito.id)
        #expect(f.store.littleWindowDestination(privateSpace) != privateSpace)
    }

    @Test func thePageTakesItsSpacesProfile() {
        let f = StoreFixture()
        #expect(f.store.littleWindowProfile(forSpace: f.space.id) == nil, "Default")
        let p = f.store.createProfile(name: "Work", forSpaces: [f.space.id])
        #expect(f.store.littleWindowProfile(forSpace: f.space.id) == p.id)
        let incognito = f.store.addIncognitoWindow(frame: nil)
        #expect(f.store.littleWindowProfile(forSpace: f.store.focusedSpaceID(window: incognito.id)) == nil)
    }
}

/// New Little Window's key from any app on Windows (RegisterHotKey).
struct GlobalShortcutWindowsTests {
    @Test func modifiersInWindowsBits() {
        #expect(GlobalShortcut.windowsModifiers([.control, .option]) == 0x4003)
        #expect(GlobalShortcut.windowsModifiers([.shift, .command]) == 0x400C)
        #expect(GlobalShortcut.windowsModifiers([]) == 0x4000)
    }

    @Test func chordsGiveBackTheirVirtualKey() {
        for vk: Int32 in [0x41, 0x4E, 0x5A, 0x30, 0x39, 0x08, 0x09, 0x25, 0x26, 0x27, 0x28, 0x70, 0x7B, 0xBB, 0xBC, 0xDE] {
            #expect(KeyChord(windowsVirtualKey: vk, control: true, shift: false, alt: true)?.windowsVirtualKey == vk, "\(vk)")
        }
        #expect(KeyChord(" ", .control).windowsVirtualKey == nil)
    }

    @Test func newLittleWindowIsArcForWindowsKey() {
        let win = Dictionary(uniqueKeysWithValues: KeyBindingDefaults.windows.map { ($0.id, $0) })
        #expect(win["newLittleWindow"]?.primary?.windowsDisplay == "Ctrl+Alt+N")
        #expect(win["promoteLittleWindow"]?.primary?.windowsDisplay == "Ctrl+O")
        #expect(win["closeLittleWindows"]?.shortcuts.isEmpty == true)
    }
}
