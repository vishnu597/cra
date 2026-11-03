import AppKit

// SplitPaneLayout lives in CraCore (the Windows app lays its panes out with it too); the
// transition's timing curve is Core Animation's.
extension SplitPaneLayout.Constants {
    static let transitionTiming = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
}
