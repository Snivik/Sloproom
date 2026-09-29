//
//  CanvasGeometry.swift
//  sloproom
//
//  Converts between view coordinates of the Develop canvas and image spaces, for overlays.
//
//  The canvas shows either:
//    - the CROPPED image (normal / mask tool), or
//    - the UNCROPPED frame (crop tool active: rotated + flipped + straightened, no crop),
//  which is `showsCrop`. `imageRect` is where that image is drawn, in the overlay's view
//  coordinates (SwiftUI, top-left origin).
//
//  Spaces: see GeometryMath. Masks use "mask" = source-normalized; crop uses "frame"-normalized.
//

import Foundation
import CoreGraphics

nonisolated struct CanvasGeometry: Sendable {
    /// Where the displayed image is drawn, in view coordinates.
    let imageRect: CGRect
    let math: GeometryMath
    /// True if the displayed image has the crop applied (false while the crop tool is active).
    let showsCrop: Bool

    init(imageRect: CGRect, sourceSize: CGSize, geometry: Geometry, showsCrop: Bool) {
        self.imageRect = imageRect
        self.math = GeometryMath(sourceSize: sourceSize, geometry: geometry)
        self.showsCrop = showsCrop
    }

    /// Aspect-fit rect of an image of `imageSize` centered in `bounds`.
    static func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let s = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// Size (source units) of the image the canvas shows: cropped size or full frame size.
    var displayedImageSize: CGSize { showsCrop ? math.croppedSize : math.frameSize }

    /// View points per source pixel.
    var viewScale: CGFloat {
        let w = displayedImageSize.width
        return w > 0 ? imageRect.width / w : 0
    }

    // MARK: displayed-normalized (0...1 over the displayed image) <-> view

    func viewPoint(fromDisplayed p: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + p.x * imageRect.width, y: imageRect.minY + p.y * imageRect.height)
    }

    func displayedPoint(fromView p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - imageRect.minX) / max(imageRect.width, 1e-9),
                y: (p.y - imageRect.minY) / max(imageRect.height, 1e-9))
    }

    // MARK: frame-normalized (crop space) <-> view

    func viewPoint(fromFrame p: CGPoint) -> CGPoint {
        viewPoint(fromDisplayed: showsCrop ? math.croppedNormalized(fromFrame: p) : p)
    }

    func framePoint(fromView p: CGPoint) -> CGPoint {
        let d = displayedPoint(fromView: p)
        return showsCrop ? math.frameNormalized(fromCropped: d) : d
    }

    /// View rect of a frame-normalized rect (e.g. the crop rect while the crop tool is active).
    func viewRect(fromFrame r: NormRect) -> CGRect {
        let a = viewPoint(fromFrame: CGPoint(x: r.x, y: r.y))
        let b = viewPoint(fromFrame: CGPoint(x: r.x + r.width, y: r.y + r.height))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    // MARK: mask space (source-normalized) <-> view

    func viewPoint(fromMask p: NormPoint) -> CGPoint {
        viewPoint(fromFrame: math.frameNormalized(fromSource: p))
    }

    func maskPoint(fromView p: CGPoint) -> NormPoint {
        math.sourceNormalized(fromFrame: framePoint(fromView: p))
    }

    /// View length of a distance given as a fraction of the source (oriented, uncropped) width,
    /// e.g. `BrushStroke.radius` or `RadialGradientMask.radiusX`.
    func viewLength(fromSourceWidthFraction f: Double) -> CGFloat {
        CGFloat(f) * math.sourceSize.width * viewScale
    }

    /// Inverse of `viewLength(fromSourceWidthFraction:)`.
    func sourceWidthFraction(fromViewLength l: CGFloat) -> Double {
        let d = math.sourceSize.width * viewScale
        return d > 0 ? Double(l / d) : 0
    }

    /// View length of a distance given as a fraction of the source height (e.g. `radiusY`).
    func viewLength(fromSourceHeightFraction f: Double) -> CGFloat {
        CGFloat(f) * math.sourceSize.height * viewScale
    }
}
