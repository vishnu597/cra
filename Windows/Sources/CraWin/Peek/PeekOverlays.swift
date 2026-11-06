import CraCEFWin
import CraCore
import Foundation
import WinAppSDK
import WindowsFoundation
import WinSDK

/// Where a Peek goes over a browser window, in physical screen pixels (PeekLayout, which is y up
/// in DIPs, turned into Windows' y down).
struct PeekPlacement: Equatable {
    /// The browser window's client area: the click catcher covers it.
    var client: PixelRect
    /// Right of the sidebar, top to bottom: the veil over the page (Arc fades that part, the
    /// sidebar stays as it is).
    var page: PixelRect
    /// The card's client area.
    var card: PixelRect
    /// Close, Expand and Add To Split, top first.
    var buttons: [PixelRect]

    /// `client`: the browser window's client area on screen; `sidebar`: its sidebar's width in DIPs.
    init(client: PixelRect, sidebar: Double, scale: Double) {
        self.client = client
        let width = Double(client.width) / scale, height = Double(client.height) / scale
        let area = PeekLayout.area(window: CGSize(width: width, height: height), contentMinX: CGFloat(sidebar))
        let card = PeekLayout.card(in: area)
        func pixels(_ r: CGRect) -> PixelRect {
            let top = height - Double(r.maxY)
            let x0 = (Double(r.minX) * scale).rounded(), x1 = (Double(r.maxX) * scale).rounded()
            let y0 = (top * scale).rounded(), y1 = ((top + Double(r.height)) * scale).rounded()
            return PixelRect(x: client.x + Int32(x0), y: client.y + Int32(y0), width: Int32(x1 - x0), height: Int32(y1 - y0))
        }
        page = pixels(area)
        self.card = pixels(card)
        buttons = PeekLayout.buttons(beside: card).map(pixels)
    }
}

/// The windows a Peek puts over its browser window besides its card (PeekDimPanel and
/// PeekControlsPanel on the Mac), all owned by it: a click catcher over the whole client area, the
/// veil that fades the page to `PeekLayout.pageAlpha` over the window's background, and the round
/// buttons beside the card. A click on the catcher or the veil closes the Peek. Z-order, back to
/// front: the browser window, catcher, veil, card, buttons.
@MainActor
final class PeekOverlays {
    /// A click past the card.
    var onClickOutside: () -> Void = {}
    /// A round button, by its index (0 Close, 1 Expand, 2 Add To Split).
    var onButton: (Int) -> Void = { _ in }

    private var catcher: UInt = 0
    private var veil: UInt = 0
    private var buttons: UInt = 0
    private let box: Unmanaged<Box>
    private var fadeTimer: WinAppSDK.DispatcherQueueTimer?
    private var fadeStart = Date()
    private var veilAlpha = 1
    private var destroyed = false

    /// The veil at its darkest: the page shows through at `PeekLayout.pageAlpha`.
    private static let darkestVeil = Int(((1 - Double(PeekLayout.pageAlpha)) * 255).rounded())
    private static let buttonMargin = 8.0  // DIPs round the column, for the buttons' shadows

    private final class Box {
        weak var owner: PeekOverlays?
    }

    /// `owner`: the browser window's HWND; `background`: its own fill, what the page fades toward.
    init(owner: UInt, background: HostColor, buttons glyphs: [String], tips: [String]) {
        box = Unmanaged.passRetained(Box())
        box.takeUnretainedValue().owner = self
        let context = box.toOpaque()
        let rgb = UInt32(background.r) << 16 | UInt32(background.g) << 8 | UInt32(background.b)
        let outside: CraOverlayClicked = { context in
            guard let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            // After the click's own message: closing destroys the window it came to.
            _ = try? WinAppSDK.DispatcherQueue.getForCurrentThread()?.tryEnqueue { MainActor.assumeIsolated { box.owner?.onClickOutside() } }
        }
        catcher = cra_overlay_create(owner, rgb, 1, context, outside)
        veil = cra_overlay_create(owner, rgb, 1, context, outside)
        let pressed: CraButtonClicked = { context, index in
            guard let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            _ = try? WinAppSDK.DispatcherQueue.getForCurrentThread()?.tryEnqueue { MainActor.assumeIsolated { box.owner?.onButton(Int(index)) } }
        }
        buttons = Self.withCStrings(glyphs) { g in
            Self.withCStrings(tips) { t in cra_round_buttons_create(owner, g, t, glyphs.count, context, pressed) }
        }
    }

    /// Everything where `placement` says, the card (`card`, an HWND) between the veil and the
    /// buttons. `fill` and `ink`: the buttons' colours (0xRRGGBB).
    func place(_ placement: PeekPlacement, card: HostWindow, fill: UInt32, ink: UInt32, scale: Double) {
        guard !destroyed else { return }
        let margin = Int32((Self.buttonMargin * scale).rounded())
        let column = placement.buttons.reduce(placement.buttons.first ?? placement.card) { a, b in
            let x = min(a.x, b.x), y = min(a.y, b.y)
            return PixelRect(x: x, y: y, width: max(a.x + a.width, b.x + b.width) - x, height: max(a.y + a.height, b.y + b.height) - y)
        }
        let frame = PixelRect(x: column.x - margin, y: column.y - margin, width: column.width + 2 * margin, height: column.height + 2 * margin)
        var rects: [Int32] = []
        for b in placement.buttons { rects += [b.x - frame.x, b.y - frame.y, b.width, b.height] }
        cra_round_buttons_place(buttons, frame.x, frame.y, frame.width, frame.height, rects, placement.buttons.count, fill, ink, scale, 0)
        card.placeClient(x: placement.card.x, y: placement.card.y, width: placement.card.width, height: placement.card.height)
        card.order(below: buttons)
        let p = placement.page, c = placement.client
        cra_overlay_place(veil, p.x, p.y, p.width, p.height, card.hwnd)
        cra_overlay_place(catcher, c.x, c.y, c.width, c.height, veil)
    }

    /// The page fades to `PeekLayout.pageAlpha` on an ease-out cubic (Arc's open, 0.18 s).
    func fadeIn() {
        fade(to: Self.darkestVeil, over: PeekLayout.openVeilDuration)
    }

    /// The card has gone: clicks pass again at once and the page comes back over 0.2 s, then
    /// every window goes.
    func fadeOutAndDestroy() {
        guard !destroyed else { return }
        cra_round_buttons_destroy(buttons)
        buttons = 0
        cra_overlay_destroy(catcher)
        catcher = 0
        // Kept alive by its own timer until the fade ends.
        let keep = self
        fade(to: 1, over: PeekLayout.closeVeilDuration) { keep.destroy() }
    }

    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        try? fadeTimer?.stop()
        fadeTimer = nil
        for overlay in [catcher, veil] { cra_overlay_destroy(overlay) }
        cra_round_buttons_destroy(buttons)
        (catcher, veil, buttons) = (0, 0, 0)
        box.release()
    }

    private func fade(to target: Int, over duration: Double, then done: (() -> Void)? = nil) {
        try? fadeTimer?.stop()
        let from = veilAlpha
        fadeStart = Date()
        let step: () -> Bool = { [weak self] in
            guard let self, !self.destroyed else { return true }
            let u = duration > 0 ? Date().timeIntervalSince(self.fadeStart) / duration : 1
            let p = PeekLayout.Curve.easeOutCubic(u)
            self.veilAlpha = Int((Double(from) + Double(target - from) * p).rounded())
            cra_overlay_set_alpha(self.veil, Int32(self.veilAlpha))
            return u >= 1
        }
        if step() {
            done?()
            return
        }
        fadeTimer = try? WinAppSDK.DispatcherQueue.getForCurrentThread()?.createTimer()
        fadeTimer?.interval = TimeSpan(duration: 10 * 10_000)  // 10 ms; Windows' timers tick at ~16
        fadeTimer?.isRepeating = true
        fadeTimer?.tick.addHandler { [weak self] _, _ in
            guard step() else { return }
            try? self?.fadeTimer?.stop()
            self?.fadeTimer = nil
            done?()
        }
        try? fadeTimer?.start()
    }

    /// `strings` as C strings for the call (WinShell.popupMenu's way).
    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>?) -> R) -> R {
        let copies: [UnsafeMutablePointer<CChar>] = strings.map { string in
            let utf8 = string.utf8CString
            let copy = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count)
            for (i, c) in utf8.enumerated() { copy[i] = c }
            return copy
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers: [UnsafePointer<CChar>?] = copies.map { UnsafePointer($0) }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress) }
    }
}
