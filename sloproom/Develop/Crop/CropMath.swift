//
//  CropMath.swift
//  sloproom
//
//  Pure crop-tool geometry (no UI). Works in FRAME PIXELS: top-left origin, y down, in the
//  frame of GeometryMath (after quarter turns + flip), where the image content is a W×H
//  rectangle rotated by `angle` (clockwise, degrees) about the frame center. A crop is valid
//  when all four corners lie inside that rotated content ("constrain to image", always on).
//
//  Also: visual quarter-turn / flip transforms of a whole `Geometry` (crop rect follows).
//

import Foundation
import CoreGraphics

/// Which part of the crop rectangle a drag grabbed.
nonisolated enum CropHandle: Hashable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    /// Drag inside: move the crop.
    case inside
    /// Drag outside: rotate (straighten).
    case outside

    var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
    /// -1 = moves the min edge, +1 = moves the max edge, 0 = that axis unaffected.
    var xSide: CGFloat {
        switch self {
        case .topLeft, .left, .bottomLeft: -1
        case .topRight, .right, .bottomRight: 1
        default: 0
        }
    }
    var ySide: CGFloat {
        switch self {
        case .topLeft, .top, .topRight: -1
        case .bottomLeft, .bottom, .bottomRight: 1
        default: 0
        }
    }
}

nonisolated struct CropMath: Sendable {
    /// Frame size in pixels (any consistent unit).
    let frameSize: CGSize
    /// Straighten angle, degrees clockwise.
    let angle: Double

    init(frameSize: CGSize, angle: Double) {
        self.frameSize = frameSize
        self.angle = angle
    }

    init(sourceSize: CGSize, geometry: Geometry, angle: Double? = nil) {
        self.frameSize = GeometryMath(sourceSize: sourceSize, geometry: geometry).frameSize
        self.angle = angle ?? geometry.straightenAngle
    }

    var center: CGPoint { CGPoint(x: frameSize.width / 2, y: frameSize.height / 2) }
    private var radians: CGFloat { CGFloat(angle * .pi / 180) }
    /// Slack for floating point error (a full-frame crop at 0° must count as inside).
    private var epsilon: CGFloat { max(frameSize.width, frameSize.height) * 1e-9 }

    // MARK: Normalized <-> pixels

    func pixelRect(_ r: NormRect) -> CGRect {
        CGRect(x: r.x * frameSize.width, y: r.y * frameSize.height,
               width: r.width * frameSize.width, height: r.height * frameSize.height)
    }

    func normRect(_ r: CGRect) -> NormRect {
        guard frameSize.width > 0, frameSize.height > 0 else { return .full }
        return NormRect(x: Double(r.minX / frameSize.width), y: Double(r.minY / frameSize.height),
                        width: Double(r.width / frameSize.width), height: Double(r.height / frameSize.height)).snapped
    }

    // MARK: Containment

    /// `p` relative to the frame center, rotated back into the content's own axes.
    private func local(_ p: CGPoint) -> CGPoint {
        let dx = p.x - center.x, dy = p.y - center.y
        let a = -radians
        return CGPoint(x: dx * cos(a) - dy * sin(a), y: dx * sin(a) + dy * cos(a))
    }

    func contains(_ p: CGPoint) -> Bool {
        let q = local(p)
        return abs(q.x) <= frameSize.width / 2 + epsilon && abs(q.y) <= frameSize.height / 2 + epsilon
    }

    func contains(_ r: CGRect) -> Bool {
        contains(CGPoint(x: r.minX, y: r.minY)) && contains(CGPoint(x: r.maxX, y: r.minY))
            && contains(CGPoint(x: r.maxX, y: r.maxY)) && contains(CGPoint(x: r.minX, y: r.maxY))
    }

    /// Largest `s` such that a rect of `size * s` centered at `c` fits inside the content
    /// (negative if `c` itself is outside).
    func maxScale(center c: CGPoint, size: CGSize) -> CGFloat {
        let a = local(c)
        let cs = abs(cos(radians)), sn = abs(sin(radians))
        let bx = (size.width * cs + size.height * sn) / 2
        let by = (size.width * sn + size.height * cs) / 2
        let sx = bx > 0 ? (frameSize.width / 2 - abs(a.x)) / bx : .greatestFiniteMagnitude
        let sy = by > 0 ? (frameSize.height / 2 - abs(a.y)) / by : .greatestFiniteMagnitude
        return min(sx, sy)
    }

    // MARK: Constraining

    /// The largest rect of aspect `ratio` (width / height) that fits, as close to `near` as possible
    /// (default: frame center).
    func maxRect(aspect ratio: CGFloat, near target: CGPoint? = nil) -> CGRect {
        let unit = CGSize(width: ratio, height: 1)
        let s = maxScale(center: center, size: unit)
        let size = CGSize(width: unit.width * s, height: unit.height * s)
        let centered = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        guard let target else { return centered }
        return moved(centered, by: CGVector(dx: target.x - center.x, dy: target.y - center.y))
    }

    /// `r` scaled down about its center (aspect kept) until it fits. If its center is (almost)
    /// outside the content, the center is pulled toward the frame center first.
    func fitted(_ r: CGRect) -> CGRect {
        guard r.width > 0, r.height > 0 else { return r }
        let c = CGPoint(x: r.midX, y: r.midY)
        let s = maxScale(center: c, size: r.size)
        if s >= 1 { return r }
        let atCenter = min(1, maxScale(center: center, size: r.size))
        var fitCenter = c, scale = s
        if s < atCenter / 2 {
            // Smallest move toward the frame center that allows half the achievable size.
            // (maxScale is concave along the segment, so bisection is valid.)
            let goal = atCenter / 2
            var lo: CGFloat = 0, hi: CGFloat = 1
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if maxScale(center: lerp(c, center, mid), size: r.size) >= goal { hi = mid } else { lo = mid }
            }
            fitCenter = lerp(c, center, hi)
            scale = goal
        }
        let size = CGSize(width: r.width * scale, height: r.height * scale)
        return CGRect(x: fitCenter.x - size.width / 2, y: fitCenter.y - size.height / 2, width: size.width, height: size.height)
    }

    /// `r` translated by `d`, sliding along the content edges instead of leaving it.
    /// `r` must already fit.
    func moved(_ r: CGRect, by d: CGVector) -> CGRect {
        let off = Self.slide(from: .zero, to: CGPoint(x: d.dx, y: d.dy)) { contains(r.offsetBy(dx: $0.x, dy: $0.y)) }
        return r.offsetBy(dx: off.x, dy: off.y)
    }

    /// Resizes `start` (which fits) by dragging `handle` to `p`. The opposite corner / edge stays
    /// fixed. `lockAspect` keeps `start`'s ratio; locked edge drags scale about the opposite
    /// edge's midpoint. Never smaller than `minSize` per side, never outside the content.
    func resized(_ start: CGRect, handle: CropHandle, to p: CGPoint, lockAspect: Bool, minSize: CGFloat) -> CGRect {
        let xs = handle.xSide, ys = handle.ySide
        guard xs != 0 || ys != 0 else { return start }
        let minSize = min(minSize, start.width, start.height)
        // Fixed anchor (opposite corner, or opposite edge midpoint).
        let ax = xs > 0 ? start.minX : xs < 0 ? start.maxX : start.midX
        let ay = ys > 0 ? start.minY : ys < 0 ? start.maxY : start.midY

        if lockAspect {
            // Scale factor from the pointer, then shrink until it fits.
            let w0 = start.width, h0 = start.height
            let fx = xs != 0 ? (p.x - ax) * xs / w0 : 0
            let fy = ys != 0 ? (p.y - ay) * ys / h0 : 0
            let lower = max(minSize / w0, minSize / h0)
            var f = handle.isCorner ? max(fx, fy) : (xs != 0 ? fx : fy)
            f = max(f, lower)
            let rect: (CGFloat) -> CGRect = { f in
                let w = w0 * f, h = h0 * f
                let x = xs > 0 ? ax : xs < 0 ? ax - w : ax - w / 2
                let y = ys > 0 ? ay : ys < 0 ? ay - h : ay - h / 2
                return CGRect(x: x, y: y, width: w, height: h)
            }
            if contains(rect(f)) { return rect(f) }
            // Homothetic family about the anchor: containment is monotone in f.
            var lo = contains(rect(1)) ? 1 : lower, hi = f
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if contains(rect(mid)) { lo = mid } else { hi = mid }
            }
            return rect(lo)
        }

        // Free: move the grabbed corner / edge toward the pointer, clamped per axis.
        let startCorner = CGPoint(x: xs > 0 ? start.maxX : xs < 0 ? start.minX : 0,
                                  y: ys > 0 ? start.maxY : ys < 0 ? start.minY : 0)
        var target = CGPoint(x: xs != 0 ? p.x : 0, y: ys != 0 ? p.y : 0)
        if xs != 0 { target.x = xs > 0 ? max(target.x, ax + minSize) : min(target.x, ax - minSize) }
        if ys != 0 { target.y = ys > 0 ? max(target.y, ay + minSize) : min(target.y, ay - minSize) }
        let rect: (CGPoint) -> CGRect = { q in
            let x0 = xs != 0 ? min(ax, q.x) : start.minX, x1 = xs != 0 ? max(ax, q.x) : start.maxX
            let y0 = ys != 0 ? min(ay, q.y) : start.minY, y1 = ys != 0 ? max(ay, q.y) : start.maxY
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
        let q = Self.slide(from: startCorner, to: target) { contains(rect($0)) }
        return rect(q)
    }

    /// From `a` (feasible) toward `b`: the furthest feasible point along a→b, then extended along
    /// x and along y separately (so a drag slides along a constraint instead of stopping).
    /// `feasible` must describe a convex set.
    static func slide(from a: CGPoint, to b: CGPoint, feasible: (CGPoint) -> Bool) -> CGPoint {
        if feasible(b) { return b }
        var p = bisect(from: a, to: b, feasible: feasible)
        p = bisect(from: p, to: CGPoint(x: b.x, y: p.y), feasible: feasible)
        p = bisect(from: p, to: CGPoint(x: p.x, y: b.y), feasible: feasible)
        return p
    }

    private static func bisect(from a: CGPoint, to b: CGPoint, feasible: (CGPoint) -> Bool) -> CGPoint {
        if a == b || feasible(b) { return b }
        var lo: CGFloat = 0, hi: CGFloat = 1
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if feasible(lerp(a, b, mid)) { lo = mid } else { hi = mid }
        }
        return lerp(a, b, lo)
    }
}

nonisolated private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}

// MARK: - Whole-geometry transforms (what the user sees rotates / mirrors; crop follows)

nonisolated extension Geometry {
    /// Rotates the displayed result by 90° (clockwise or not), crop rect included.
    /// With flip on, a visual clockwise turn is one fewer stored turn (R∘F = F∘R⁻¹).
    /// Straighten commutes with quarter turns about the same center, so it is unchanged.
    func rotatedQuarter(clockwise: Bool) -> Geometry {
        var g = self
        let step = (clockwise ? 1 : -1) * (flipHorizontal ? -1 : 1)
        g.quarterTurns = (((normalizedQuarterTurns + step) % 4) + 4) % 4
        let c = crop
        g.crop = clockwise
            ? NormRect(x: 1 - c.y - c.height, y: c.x, width: c.height, height: c.width)
            : NormRect(x: c.y, y: 1 - c.x - c.width, width: c.height, height: c.width)
        g.crop = g.crop.snapped
        return g
    }

    /// Mirrors the displayed result horizontally: toggles flip, negates straighten, mirrors crop.
    func flippedHorizontally() -> Geometry {
        var g = self
        g.flipHorizontal.toggle()
        g.straightenAngle = straightenAngle == 0 ? 0 : -straightenAngle
        g.crop = NormRect(x: 1 - crop.x - crop.width, y: crop.y, width: crop.width, height: crop.height).snapped
        return g
    }
}

nonisolated extension NormRect {
    /// Removes float noise around 0 / 1 so a full crop stays `.full`.
    var snapped: NormRect {
        var r = self
        func snap(_ v: inout Double, _ t: Double) { if abs(v - t) < 1e-9 { v = t } }
        snap(&r.x, 0); snap(&r.y, 0); snap(&r.width, 1); snap(&r.height, 1)
        return r
    }
}

nonisolated extension EditSettings {
    /// True if the two settings render the same UNCROPPED frame (they differ at most in crop
    /// rect / preset / aspect lock). The crop tool uses this to skip pointless re-renders.
    func rendersSameUncroppedFrame(as other: EditSettings) -> Bool {
        var a = self, b = other
        a.geometry.crop = .full; a.geometry.cropPresetID = nil; a.geometry.aspectLocked = false
        b.geometry.crop = .full; b.geometry.cropPresetID = nil; b.geometry.aspectLocked = false
        return a == b
    }
}
