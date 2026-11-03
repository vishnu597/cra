// CGFloat and CGRect come from Foundation off Apple platforms (Windows, Linux).
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import CraCore
import Testing

/// Arc's split panes (ARCUI.SplitViewControllerLayout): factors of the room left after the
/// 10 pt gaps, a 200 pt minimum, and dividers that snap to equal.
struct SplitPaneLayoutTests {
    private let a = UUID(), b = UUID(), c = UUID()

    private func layout(_ factors: [CGFloat], _ orientation: SplitOrientation = .horizontal,
                        size: CGSize = CGSize(width: 1010, height: 600), flipped: Bool = false) -> SplitPaneLayout {
        let ids = [a, b, c]
        let panes = factors.enumerated().map { SplitPaneLayout.Pane(id: ids[$0.offset], factor: $0.element) }
        return SplitPaneLayout(panes: panes, orientation: orientation, containerSize: size, backingScaleFactor: 1, flipped: flipped)
    }

    @Test func noPanesLayNothingOut() {
        let r = SplitPaneLayout(panes: [], orientation: .horizontal, containerSize: CGSize(width: 800, height: 600)).compute()
        #expect(r.frames.isEmpty)
        #expect(r.gaps.isEmpty)
    }

    @Test func twoEqualPanesSideBySide() {
        let r = layout([0.5, 0.5]).compute()
        #expect(r.frames[a] == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(r.frames[b] == CGRect(x: 510, y: 0, width: 500, height: 600))
        #expect(r.gaps == [CGRect(x: 500, y: 0, width: 10, height: 600)])
        #expect(r.factors[a] == 0.5)
    }

    /// AppKit's y grows upward: the first stacked pane is the top one, at the largest y.
    @Test func stackedPanesStartAtTheTopInAppKit() {
        let r = layout([0.5, 0.5], .vertical, size: CGSize(width: 800, height: 610)).compute()
        #expect(r.frames[a] == CGRect(x: 0, y: 310, width: 800, height: 300))
        #expect(r.frames[b] == CGRect(x: 0, y: 0, width: 800, height: 300))
        #expect(r.gaps == [CGRect(x: 0, y: 300, width: 800, height: 10)])
    }

    /// Windows' y grows downward: the first stacked pane sits at y = 0.
    @Test func stackedPanesStartAtZeroWhenFlipped() {
        let r = layout([0.5, 0.5], .vertical, size: CGSize(width: 800, height: 610), flipped: true).compute()
        #expect(r.frames[a] == CGRect(x: 0, y: 0, width: 800, height: 300))
        #expect(r.frames[b] == CGRect(x: 0, y: 310, width: 800, height: 300))
        #expect(r.gaps == [CGRect(x: 0, y: 300, width: 800, height: 10)])
    }

    /// Side by side, flipped changes nothing.
    @Test func flippedSideBySideIsTheSame() {
        #expect(layout([0.3, 0.7], flipped: true).compute() == layout([0.3, 0.7]).compute())
    }

    @Test func aPaneBelowTheMinimumTakesFromTheOthers() {
        let r = layout([0.05, 0.95]).compute()
        #expect(r.frames[a]?.width == 200)
        #expect(r.frames[b]?.width == 800)
    }

    @Test func zeroFactorsShareEqually() {
        let r = layout([0, 0, 0], size: CGSize(width: 920, height: 600)).compute()
        #expect(r.frames[a]?.width == 300)
        #expect(r.frames[b]?.minX == 310)
        #expect(r.frames[c]?.maxX == 920)
        #expect(r.gaps.count == 2)
    }

    @Test func theLastPaneReachesTheEdgeAfterRounding() {
        let r = SplitPaneLayout(panes: [.init(id: a, factor: 1), .init(id: b, factor: 1), .init(id: c, factor: 1)],
                                orientation: .horizontal, containerSize: CGSize(width: 1001, height: 600), backingScaleFactor: 2).compute()
        #expect(r.frames[c]?.maxX == 1001)
    }

    @Test func dividerHitsCountTheOutset() {
        let r = layout([0.5, 0.5]).compute()
        #expect(r.divider(at: CGPoint(x: 505, y: 300)) == 0)
        #expect(r.divider(at: CGPoint(x: 497, y: 300)) == 0)  // 3 pt left of the gap
        #expect(r.divider(at: CGPoint(x: 494, y: 300)) == nil)
        #expect(r.divider(at: CGPoint(x: 505, y: 300), outset: 0) == 0)
        #expect(r.divider(at: CGPoint(x: 499, y: 300), outset: 0) == nil)
        let three = layout([1, 1, 1], size: CGSize(width: 920, height: 600)).compute()
        #expect(three.divider(at: CGPoint(x: 615, y: 10)) == 1)
    }

    @Test func draggingMovesTheDividerAndStopsAtTheMinimum() {
        let l = layout([0.5, 0.5])
        let moved = l.dragging(dividerAfter: 0, by: 100)
        #expect(moved.factors[a] == 0.6)
        #expect(moved.factors[b] == 0.4)
        #expect(!moved.snapped)
        let far = l.dragging(dividerAfter: 0, by: 1000)
        #expect(far.factors[b] == 0.2)
    }

    @Test func draggingNearTheMiddleSnaps() {
        let r = layout([0.3, 0.7]).dragging(dividerAfter: 0, by: 197)
        #expect(r.snapped)
        #expect(r.factors[a] == 0.5)
        let three = layout([0.2, 0.4, 0.4], size: CGSize(width: 1020, height: 600)).dragging(dividerAfter: 0, by: 98)
        #expect(three.snapped)
        #expect(three.factors[a] == three.factors[b])
    }

    @Test func draggingAMissingDividerChangesNothing() {
        let l = layout([0.5, 0.5])
        #expect(l.dragging(dividerAfter: 1, by: 50).factors == [a: 0.5, b: 0.5])
        #expect(l.dragging(dividerAfter: -1, by: 50).factors == [a: 0.5, b: 0.5])
        let tiny = SplitPaneLayout(panes: [.init(id: a, factor: 0.5), .init(id: b, factor: 0.5)], orientation: .horizontal,
                                   containerSize: CGSize(width: 5, height: 5))
        #expect(!tiny.dragging(dividerAfter: 0, by: 1).snapped)
    }

    @Test func storedFactorsAreNormalized() {
        #expect(SplitPaneLayout.normalizedFactors(ids: [], stored: [:]).isEmpty)
        #expect(SplitPaneLayout.normalizedFactors(ids: [a, b], stored: [:]) == [a: 0.5, b: 0.5])
        #expect(SplitPaneLayout.normalizedFactors(ids: [a, b], stored: [a: 1, b: 3]) == [a: 0.25, b: 0.75])
        // Arc stores only dragged panes: the new one gets what's left.
        #expect(SplitPaneLayout.normalizedFactors(ids: [a, b, c], stored: [a: 0.5]) == [a: 0.5, b: 0.25, c: 0.25])
    }

    @Test func nextAndPreviousPaneWrap() {
        #expect(SplitPaneLayout.pane(1, from: a, in: [a, b, c]) == b)
        #expect(SplitPaneLayout.pane(1, from: c, in: [a, b, c]) == a)
        #expect(SplitPaneLayout.pane(-1, from: a, in: [a, b, c]) == c)
        #expect(SplitPaneLayout.pane(1, from: a, in: [a]) == nil)
        #expect(SplitPaneLayout.pane(1, from: c, in: [a, b]) == nil)
    }
}
