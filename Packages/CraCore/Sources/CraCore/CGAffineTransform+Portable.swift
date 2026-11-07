import Foundation

#if !canImport(CoreGraphics)
/// CoreGraphics' CGAffineTransform, which swift-corelibs-foundation lacks, with the members
/// CraCore and its tests use (PeekLayout.backdropTransform). Same names and maths as Apple's:
/// a point maps to (a·x + c·y + tx, b·x + d·y + ty).
public struct CGAffineTransform: Equatable, Hashable, Sendable {
    public var a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat

    public init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) {
        (self.a, self.b, self.c, self.d, self.tx, self.ty) = (a, b, c, d, tx, ty)
    }

    public init() { self.init(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0) }

    public static let identity = CGAffineTransform()

    public var isIdentity: Bool { self == .identity }
}

extension CGPoint {
    public func applying(_ t: CGAffineTransform) -> CGPoint {
        CGPoint(x: t.a * x + t.c * y + t.tx, y: t.b * x + t.d * y + t.ty)
    }
}
#endif
