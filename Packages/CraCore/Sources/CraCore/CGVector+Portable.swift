import Foundation

#if !canImport(CoreGraphics)
/// CoreGraphics' CGVector, which swift-corelibs-foundation lacks (it has CGPoint, CGSize and
/// CGRect only). Same members as Apple's, so the code that uses it reads the same everywhere.
public struct CGVector: Equatable, Hashable, Sendable {
    public var dx: CGFloat
    public var dy: CGFloat

    public init() { self.init(dx: 0, dy: 0) }

    public init(dx: CGFloat, dy: CGFloat) {
        self.dx = dx
        self.dy = dy
    }

    public init(dx: Double, dy: Double) { self.init(dx: CGFloat(dx), dy: CGFloat(dy)) }

    public init(dx: Int, dy: Int) { self.init(dx: CGFloat(dx), dy: CGFloat(dy)) }

    public static let zero = CGVector()
}
#endif
