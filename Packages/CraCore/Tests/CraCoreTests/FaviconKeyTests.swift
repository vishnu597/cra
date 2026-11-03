import CraCore
import Testing

struct FaviconKeyTests {
    @Test(arguments: [
        ("https://Mail.Example.com/inbox?x=1", "mail.example.com" as String?),
        ("http://localhost:3000/", "localhost"),
        ("https://www.example.com/", "www.example.com"),
        ("notes", nil),
        ("about:blank", nil),
        ("file:///tmp/a.html", nil),
    ])
    func keyIsTheLowercasedHost(url: String, key: String?) {
        #expect(FaviconKey.key(for: url) == key)
    }
}

struct FaviconFileTests {
    @Test(arguments: [
        ("github.com", "github.com.png"),
        ("my-site.co.uk", "my-site.co.uk.png"),
        ("localhost:3000", "localhost_3000.png"),
        ("custom-1f2e", "custom-1f2e.png"),
    ])
    func fileNameKeepsSafeCharacters(key: String, file: String) {
        #expect(FaviconKey.fileName(key) == file)
    }
}

struct FaviconToneTests {
    /// 32 × 32 premultiplied RGBA: `fill` pixels of (gray, gray, gray) at full alpha, the rest clear.
    private func icon(gray: UInt8, fill: Int, tint: (UInt8, UInt8, UInt8)? = nil) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 32 * 32 * 4)
        for p in 0..<fill {
            let (r, g, b) = tint ?? (gray, gray, gray)
            buf[p * 4] = r; buf[p * 4 + 1] = g; buf[p * 4 + 2] = b; buf[p * 4 + 3] = 255
        }
        return buf
    }

    @Test func darkGlyph() { #expect(FaviconTone.glyphIsDark(rgba: icon(gray: 20, fill: 400)) == true) }

    @Test func lightGlyph() { #expect(FaviconTone.glyphIsDark(rgba: icon(gray: 240, fill: 400)) == false) }

    @Test func midGrayIsNeither() { #expect(FaviconTone.glyphIsDark(rgba: icon(gray: 128, fill: 400)) == nil) }

    @Test func colouredIconIsLeftAlone() {
        #expect(FaviconTone.glyphIsDark(rgba: icon(gray: 0, fill: 400, tint: (230, 30, 30))) == nil)
    }

    @Test func opaqueOrTinyIconsAreLeftAlone() {
        // A full square (a photo-like favicon) and a speck are not glyphs.
        #expect(FaviconTone.glyphIsDark(rgba: icon(gray: 20, fill: 1024)) == nil)
        #expect(FaviconTone.glyphIsDark(rgba: icon(gray: 20, fill: 10)) == nil)
        #expect(FaviconTone.glyphIsDark(rgba: []) == nil)
    }
}
