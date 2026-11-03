// CGFloat and CGRect come from Foundation off Apple platforms (Windows, Linux).
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Pure layout for Arc-style split panes, after ARCUI.SplitViewControllerLayout:
/// each pane gets `widthFactor × (container − gaps)` along the main axis,
/// clamped to a minimum, with the dragger handles living in the gaps.
public struct SplitPaneLayout {
    public struct Pane: Equatable {
        public let id: UUID
        public var factor: CGFloat

        public init(id: UUID, factor: CGFloat) {
            self.id = id
            self.factor = factor
        }
    }

    public struct Result: Equatable {
        /// Card frame per pane, in the container's coordinates.
        public var frames: [UUID: CGRect] = [:]
        /// Gap rects between consecutive panes (the dragger handle lives here), in pane order.
        public var gaps: [CGRect] = []
        /// Factors after clamping to the minimum size; sum to 1.
        public var factors: [UUID: CGFloat] = [:]

        public init() {}

        /// The divider under `point`: the index of the pane before the gap, counting `outset`
        /// points around each gap as the gap (the handle reacts a little outside it).
        public func divider(at point: CGPoint, outset: CGFloat = Constants.handleHitOutset) -> Int? {
            gaps.firstIndex { $0.insetBy(dx: -outset, dy: -outset).contains(point) }
        }
    }

    public enum Constants {
        /// Gap between two pane cards; measured on Arc 1.170 at 2x: 20 px.
        public static let gap: CGFloat = 10
        /// Smallest pane along the main axis.
        public static let minimumPaneLength: CGFloat = 200
        /// The handle reacts a little outside the visible gap (Arc: draggerHandleHitTargetOutset).
        public static let handleHitOutset: CGFloat = 4
        /// Add/remove pane transition. Arc lays the new pane out within a single
        /// frame (window recording at 27 fps, 24 Oct 2026); 0 = no transition.
        public static let transitionDuration: TimeInterval = 0
        /// Arc's View ▸ Add Split View stops at four panes ("Cannot Add New Pane").
        public static let maximumPanes = 4
    }

    public var panes: [Pane]
    public var orientation: SplitOrientation
    public var containerSize: CGSize
    public var backingScaleFactor: CGFloat = 2
    public var gap: CGFloat = Constants.gap
    public var minimumPaneLength: CGFloat = Constants.minimumPaneLength
    /// y grows downward (Windows, a flipped NSView): stacked panes start at y = 0. AppKit's
    /// default (false) puts the first stacked pane at the top, the largest y.
    public var flipped = false

    public init(panes: [Pane], orientation: SplitOrientation, containerSize: CGSize, backingScaleFactor: CGFloat = 2,
                flipped: Bool = false) {
        self.panes = panes
        self.orientation = orientation
        self.containerSize = containerSize
        self.backingScaleFactor = backingScaleFactor
        self.flipped = flipped
    }

    /// Equal shares for panes without a stored factor; the stored ones keep
    /// their share of what is left (Arc stores only the dragged factors).
    public static func normalizedFactors(ids: [UUID], stored: [UUID: Double]) -> [UUID: CGFloat] {
        guard !ids.isEmpty else { return [:] }
        let known = ids.filter { stored[$0] != nil }
        let knownSum = known.reduce(0.0) { $0 + (stored[$1] ?? 0) }
        var out: [UUID: CGFloat] = [:]
        if known.count == ids.count, knownSum > 0 {
            for id in ids { out[id] = CGFloat(stored[id]! / knownSum) }
            return out
        }
        let unknown = ids.count - known.count
        let remaining = max(0, 1 - min(knownSum, 1))
        for id in ids {
            if let f = stored[id] { out[id] = CGFloat(min(f, 1)) }
            else { out[id] = CGFloat(remaining / Double(unknown)) }
        }
        let sum = out.values.reduce(0, +)
        if sum > 0 { for id in ids { out[id]! /= sum } }
        return out
    }

    public func compute() -> Result {
        var result = Result()
        let n = panes.count
        guard n > 0 else { return result }
        let horizontal = orientation == .horizontal
        let total = (horizontal ? containerSize.width : containerSize.height) - gap * CGFloat(n - 1)
        let cross = horizontal ? containerSize.height : containerSize.width
        let scale = max(1, backingScaleFactor)
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

        // Clamp to the minimum, redistributing from the larger panes.
        var factors = panes.map { max(0, $0.factor) }
        let fsum = factors.reduce(0, +)
        if fsum <= 0 { factors = Array(repeating: 1 / CGFloat(n), count: n) } else { factors = factors.map { $0 / fsum } }
        var lengths = factors.map { $0 * total }
        let minLen = min(minimumPaneLength, total / CGFloat(n))
        for _ in 0..<n {
            var deficit: CGFloat = 0
            var flexible: [Int] = []
            for i in 0..<n {
                if lengths[i] < minLen { deficit += minLen - lengths[i]; lengths[i] = minLen } else { flexible.append(i) }
            }
            guard deficit > 0, !flexible.isEmpty else { break }
            let flexSum = flexible.reduce(0) { $0 + lengths[$1] - minLen }
            for i in flexible {
                let share = flexSum > 0 ? (lengths[i] - minLen) / flexSum : 1 / CGFloat(flexible.count)
                lengths[i] -= deficit * share
            }
        }

        // A stacked span from `start` to `end` down the main axis, as a rect.
        func stacked(_ start: CGFloat, _ end: CGFloat) -> CGRect {
            let y = flipped ? start : containerSize.height - end
            return CGRect(x: 0, y: y, width: cross, height: max(0, end - start))
        }
        var cursor: CGFloat = 0
        for (i, pane) in panes.enumerated() {
            let start = snap(cursor)
            let end = i == n - 1 ? (horizontal ? containerSize.width : containerSize.height) : snap(cursor + lengths[i])
            result.frames[pane.id] = horizontal ? CGRect(x: start, y: 0, width: max(0, end - start), height: cross) : stacked(start, end)
            result.factors[pane.id] = total > 0 ? lengths[i] / total : 0
            if i < n - 1 {
                let gapStart = end
                let gapEnd = snap(cursor + lengths[i] + gap)
                result.gaps.append(horizontal ? CGRect(x: gapStart, y: 0, width: gapEnd - gapStart, height: cross) : stacked(gapStart, gapEnd))
            }
            cursor += lengths[i] + gap
        }
        return result
    }

    /// Move the divider after pane `index` by `delta` points along the main
    /// axis, respecting minimum sizes; returns the new factors. Snaps to the
    /// centre when two panes would end up within `snapDistance` of equal.
    public func dragging(dividerAfter index: Int, by delta: CGFloat, snapDistance: CGFloat = 6) -> (factors: [UUID: CGFloat], snapped: Bool) {
        let n = panes.count
        guard index >= 0, index + 1 < n else { return (Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0.factor) }), false) }
        let horizontal = orientation == .horizontal
        let total = (horizontal ? containerSize.width : containerSize.height) - gap * CGFloat(n - 1)
        guard total > 0 else { return (Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0.factor) }), false) }
        var lengths = panes.map { $0.factor * total }
        let minLen = min(minimumPaneLength, total / CGFloat(n))
        var d = delta
        if lengths[index] + d < minLen { d = minLen - lengths[index] }
        if lengths[index + 1] - d < minLen { d = lengths[index + 1] - minLen }
        lengths[index] += d
        lengths[index + 1] -= d
        var snapped = false
        if n == 2 {
            let mid = total / 2
            if abs(lengths[0] - mid) < snapDistance { lengths = [mid, mid]; snapped = true }
        } else {
            let pairSum = lengths[index] + lengths[index + 1]
            if abs(lengths[index] - pairSum / 2) < snapDistance { lengths[index] = pairSum / 2; lengths[index + 1] = pairSum / 2; snapped = true }
        }
        var out: [UUID: CGFloat] = [:]
        for (i, p) in panes.enumerated() { out[p.id] = lengths[i] / total }
        return (out, snapped)
    }

    /// The pane `delta` steps from `current` in pane order, wrapping (Arc's Switch to Next and
    /// Previous Split View); nil with fewer than two panes or when `current` isn't one.
    public static func pane(_ delta: Int, from current: UUID, in panes: [UUID]) -> UUID? {
        guard panes.count > 1, let i = panes.firstIndex(of: current) else { return nil }
        let n = panes.count
        return panes[((i + delta) % n + n) % n]
    }
}
