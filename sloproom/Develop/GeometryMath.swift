//
//  GeometryMath.swift
//  sloproom
//
//  The single source of truth for how `Geometry` maps points between spaces.
//  GeometryStage (rendering) and CanvasGeometry (overlays) must both follow it.
//
//  Spaces (all TOP-LEFT origin, y down):
//    source   – oriented, uncropped image (EXIF orientation applied). Masks live here.
//    frame    – after `quarterTurns` (clockwise) then `flipHorizontal` (mirror x within the
//               rotated frame) then `straightenAngle` (clockwise rotation of the content about the
//               frame center; the frame keeps the rotated image's width/height, so corners of the
//               content fall outside and uncovered frame corners are empty). `Geometry.crop` is
//               normalized to this frame.
//    cropped  – normalized to `Geometry.crop` inside the frame (the final displayed image).
//
//  "pixel" functions use source pixel units; "normalized" functions use 0...1.
//

import Foundation
import CoreGraphics

nonisolated struct GeometryMath: Sendable {
    /// Oriented, uncropped source size (any consistent unit; usually full-res pixels).
    let sourceSize: CGSize
    let geometry: Geometry

    init(sourceSize: CGSize, geometry: Geometry) {
        self.sourceSize = sourceSize
        self.geometry = geometry
    }

    var turns: Int { geometry.normalizedQuarterTurns }

    /// Frame size: source size with width/height swapped for odd quarter turns.
    var frameSize: CGSize {
        turns % 2 == 1 ? CGSize(width: sourceSize.height, height: sourceSize.width) : sourceSize
    }

    /// Size of the cropped output in source units.
    var croppedSize: CGSize {
        CGSize(width: frameSize.width * geometry.crop.width, height: frameSize.height * geometry.crop.height)
    }

    private var radians: CGFloat { CGFloat(geometry.straightenAngle * .pi / 180) }

    // MARK: source <-> frame (pixels)

    func framePixel(fromSource p: CGPoint) -> CGPoint {
        var q = p
        var size = sourceSize
        for _ in 0..<turns { // one clockwise turn: (x, y) in W×H -> (H - y, x) in H×W
            q = CGPoint(x: size.height - q.y, y: q.x)
            size = CGSize(width: size.height, height: size.width)
        }
        if geometry.flipHorizontal { q.x = size.width - q.x }
        return rotate(q, by: radians, around: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    func sourcePixel(fromFrame p: CGPoint) -> CGPoint {
        let size = frameSize
        var q = rotate(p, by: -radians, around: CGPoint(x: size.width / 2, y: size.height / 2))
        if geometry.flipHorizontal { q.x = size.width - q.x }
        var s = size
        for _ in 0..<turns { // inverse clockwise turn: (x', y') in H×W -> (y', H - x') in W×H
            q = CGPoint(x: q.y, y: s.width - q.x)
            s = CGSize(width: s.height, height: s.width)
        }
        return q
    }

    // MARK: normalized conversions

    /// Source-normalized (mask space) -> frame-normalized (crop space).
    func frameNormalized(fromSource p: NormPoint) -> CGPoint {
        let px = framePixel(fromSource: CGPoint(x: p.x * sourceSize.width, y: p.y * sourceSize.height))
        return CGPoint(x: px.x / frameSize.width, y: px.y / frameSize.height)
    }

    /// Frame-normalized (crop space) -> source-normalized (mask space).
    func sourceNormalized(fromFrame p: CGPoint) -> NormPoint {
        let px = sourcePixel(fromFrame: CGPoint(x: p.x * frameSize.width, y: p.y * frameSize.height))
        return NormPoint(x: Double(px.x / sourceSize.width), y: Double(px.y / sourceSize.height))
    }

    /// Frame-normalized -> cropped-normalized.
    func croppedNormalized(fromFrame p: CGPoint) -> CGPoint {
        let c = geometry.crop
        return CGPoint(x: (p.x - c.x) / max(c.width, 1e-9), y: (p.y - c.y) / max(c.height, 1e-9))
    }

    /// Cropped-normalized -> frame-normalized.
    func frameNormalized(fromCropped p: CGPoint) -> CGPoint {
        let c = geometry.crop
        return CGPoint(x: c.x + p.x * c.width, y: c.y + p.y * c.height)
    }

    private func rotate(_ p: CGPoint, by a: CGFloat, around c: CGPoint) -> CGPoint {
        guard a != 0 else { return p }
        let dx = p.x - c.x, dy = p.y - c.y
        // y-down coordinates: positive angle = clockwise on screen.
        return CGPoint(x: c.x + dx * cos(a) - dy * sin(a), y: c.y + dx * sin(a) + dy * cos(a))
    }
}
