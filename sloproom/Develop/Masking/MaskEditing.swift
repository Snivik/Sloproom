//
//  MaskEditing.swift
//  sloproom
//
//  UI-free helpers for editing masks: brush point decimation / simplification (strokes must
//  stay small in JSON), naming, pin positions. Distances are measured in "width units"
//  (fractions of the oriented image width; y is scaled by the aspect H/W), like brush radii.
//

import Foundation
import CoreGraphics

nonisolated enum MaskKind: String, CaseIterable, Sendable {
    case linear, radial, brush

    var title: String {
        switch self {
        case .linear: "Linear Gradient"
        case .radial: "Radial Gradient"
        case .brush: "Brush"
        }
    }

    var systemImage: String {
        switch self {
        case .linear: "rectangle.tophalf.filled"
        case .radial: "circle.dashed"
        case .brush: "paintbrush.pointed"
        }
    }
}

nonisolated extension MaskShape {
    var kind: MaskKind {
        switch self {
        case .linear: .linear
        case .radial: .radial
        case .brush: .brush
        }
    }
}

nonisolated extension Mask {
    /// Shape accessors: nil if the mask is another kind; setting replaces the shape.
    var linear: LinearGradientMask? {
        get { if case .linear(let m) = shape { m } else { nil } }
        set { if let newValue { shape = .linear(newValue) } }
    }
    var radial: RadialGradientMask? {
        get { if case .radial(let m) = shape { m } else { nil } }
        set { if let newValue { shape = .radial(newValue) } }
    }
    var brush: BrushMask? {
        get { if case .brush(let m) = shape { m } else { nil } }
        set { if let newValue { shape = .brush(newValue) } }
    }

    /// Where the mask's pin is drawn (mask space).
    var pinPoint: NormPoint? {
        switch shape {
        case .linear(let m): return NormPoint(x: (m.start.x + m.end.x) / 2, y: (m.start.y + m.end.y) / 2)
        case .radial(let m): return m.center
        case .brush(let m): return m.strokes.first(where: { !$0.isEraser && !$0.points.isEmpty })?.points.first
        }
    }
}

nonisolated enum MaskEditing {
    /// Point spacing while painting, as a fraction of the brush radius.
    static let brushSpacing = 0.25
    /// Simplification tolerance, as a fraction of the brush radius.
    static let brushTolerance = 0.04

    /// Rounds to 1e-5 (0.1 px on a 10 000 px image) so JSON stays short.
    static func rounded(_ p: NormPoint) -> NormPoint {
        NormPoint(x: (p.x * 1e5).rounded() / 1e5, y: (p.y * 1e5).rounded() / 1e5)
    }

    /// Distance in width units between two mask points. `aspect` = height / width.
    static func distance(_ a: NormPoint, _ b: NormPoint, aspect: Double) -> Double {
        hypot(a.x - b.x, (a.y - b.y) * aspect)
    }

    /// Appends `p` to the stroke if it is at least `brushSpacing × radius` from the last point.
    /// Returns true if the point was added.
    @discardableResult
    static func append(_ p: NormPoint, to stroke: inout BrushStroke, aspect: Double, force: Bool = false) -> Bool {
        let p = rounded(p)
        if let last = stroke.points.last {
            let d = distance(last, p, aspect: aspect)
            guard d > 1e-6, force || d >= max(stroke.radius * brushSpacing, 1e-4) else { return false }
        }
        stroke.points.append(p)
        return true
    }

    /// Ramer–Douglas–Peucker simplification (keeps the stroke within `tolerance` width units).
    static func simplify(_ points: [NormPoint], tolerance: Double, aspect: Double) -> [NormPoint] {
        guard points.count > 2, tolerance > 0 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true; keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let ax = points[a].x, ay = points[a].y * aspect
            let dx = points[b].x - ax, dy = points[b].y * aspect - ay
            let len = hypot(dx, dy)
            var best = -1.0, index = a
            for i in (a + 1)..<b {
                let px = points[i].x - ax, py = points[i].y * aspect - ay
                let d = len > 1e-12 ? abs(px * dy - py * dx) / len : hypot(px, py)
                if d > best { best = d; index = i }
            }
            if best > tolerance {
                keep[index] = true
                stack.append((a, index)); stack.append((index, b))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    /// Final clean-up at the end of a stroke.
    static func finish(_ stroke: inout BrushStroke, aspect: Double) {
        stroke.points = simplify(stroke.points, tolerance: stroke.radius * brushTolerance, aspect: aspect)
    }

    /// "Linear Gradient 2" — first unused number for the kind.
    static func nextName(for kind: MaskKind, existing: [Mask]) -> String {
        let names = Set(existing.map(\.name))
        var n = 1
        while names.contains("\(kind.title) \(n)") { n += 1 }
        return "\(kind.title) \(n)"
    }
}
