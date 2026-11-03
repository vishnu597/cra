import CraCEFWin
import Foundation
import UWP
import WindowsFoundation
import WinUI

/// An image as premultiplied BGRA bytes, top-down: what the bridge decodes (CraImage) and what a
/// XAML WriteableBitmap holds. A value, so it can be made off the UI thread.
struct Pixels: Sendable {
    let width: Int
    let height: Int
    let bgra: [UInt8]

    init(width: Int, height: Int, bgra: [UInt8]) {
        self.width = width
        self.height = height
        self.bgra = bgra
    }

    /// Takes the bridge's image and frees it.
    private init?(taking image: inout CraImage) {
        defer { cra_image_free(&image) }
        guard image.width > 0, image.height > 0, let p = image.pixels else { return nil }
        let w = Int(image.width), h = Int(image.height)
        self.init(width: w, height: h, bgra: Array(UnsafeBufferPointer(start: p, count: w * h * 4)))
    }

    /// PNG (or ICO, JPEG…) bytes; `side` > 0 scales to `side` × `side`.
    static func decode(_ data: Data, side: Int = 0) -> Pixels? {
        var image = CraImage()
        let ok = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return cra_image_decode(base, raw.count, Int32(side), &image)
        }
        return ok != 0 ? Pixels(taking: &image) : nil
    }

    /// Explorer's preview of a file, else its icon, else its type's icon. Slow for a big file.
    static func file(_ path: String, side: Int) -> Pixels? {
        var image = CraImage()
        return cra_shell_file_image(path, Int32(side), &image) != 0 ? Pixels(taking: &image) : nil
    }

    /// The same bytes in RGBA order (FaviconTone's).
    var rgba: [UInt8] {
        var out = bgra
        for i in stride(from: 0, to: out.count, by: 4) { out.swapAt(i, i + 2) }
        return out
    }

    /// Every pixel in one colour at its own coverage: a one-colour glyph redrawn (SwiftUI's
    /// template rendering). `opacity` scales the coverage.
    func tinted(r: UInt8, g: UInt8, b: UInt8, opacity: Double) -> Pixels {
        var out = bgra
        for i in stride(from: 0, to: out.count, by: 4) {
            let a = Double(out[i + 3]) * opacity
            out[i] = UInt8(Double(b) * a / 255)
            out[i + 1] = UInt8(Double(g) * a / 255)
            out[i + 2] = UInt8(Double(r) * a / 255)
            out[i + 3] = UInt8(a)
        }
        return Pixels(width: width, height: height, bgra: out)
    }

    /// The middle square (SwiftUI's .aspectRatio(contentMode: .fill) in a square frame).
    func squareCrop() -> Pixels {
        guard width != height else { return self }
        let side = min(width, height), x0 = (width - side) / 2, y0 = (height - side) / 2
        var out = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            let from = ((y0 + y) * width + x0) * 4
            out.replaceSubrange(y * side * 4..<(y + 1) * side * 4, with: bgra[from..<from + side * 4])
        }
        return Pixels(width: side, height: side, bgra: out)
    }

    /// Corners rounded to `radius` pixels, their edges smoothed.
    func rounded(radius: Double) -> Pixels {
        guard radius > 0 else { return self }
        var out = bgra
        let w = Double(width), h = Double(height)
        for y in 0..<height {
            let cy = Double(y) + 0.5
            for x in 0..<width {
                let cx = Double(x) + 0.5
                // Distance past the corner's circle, for pixels in a corner square only.
                let dx = cx < radius ? radius - cx : (cx > w - radius ? cx - (w - radius) : 0)
                let dy = cy < radius ? radius - cy : (cy > h - radius ? cy - (h - radius) : 0)
                guard dx > 0, dy > 0 else { continue }
                let coverage = min(1, max(0, radius - (dx * dx + dy * dy).squareRoot() + 0.5))
                guard coverage < 1 else { continue }
                let i = (y * width + x) * 4
                for c in 0..<4 { out[i + c] = UInt8(Double(out[i + c]) * coverage) }
            }
        }
        return Pixels(width: width, height: height, bgra: out)
    }

    /// For an Image's source (a XAML WriteableBitmap is premultiplied BGRA).
    @MainActor
    func bitmap() -> WriteableBitmap? {
        let bitmap = WriteableBitmap(Int32(width), Int32(height))
        guard let buffer = bitmap.pixelBuffer, let target = try? buffer.buffer,
              Int(buffer.capacity) >= bgra.count else { return nil }
        bgra.withUnsafeBufferPointer { target.update(from: $0.baseAddress!, count: $0.count) }
        try? bitmap.invalidate()
        return bitmap
    }
}

extension UI {
    /// An Image of `size` × `size` DIPs showing `source`, scaled to fit.
    static func image(_ source: WinUI.ImageSource, size: Double) -> WinUI.Image {
        let image = WinUI.Image()
        image.source = source
        image.stretch = .uniform
        image.width = size
        image.height = size
        return image
    }
}
