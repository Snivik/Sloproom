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
//  Zoom / pan (Develop/Zoom): `imageRect` is where the WHOLE displayed image is drawn, so when
//  zoomed it is larger than the view and may start at negative coordinates. Every conversion
//  below is relative to `imageRect`, so overlays work unchanged at any zoom. `CanvasViewport`
//  (end of this file) computes that rect from the zoom level and pan position.
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

// MARK: - Zoom / pan

/// Develop canvas zoom level. `ratio` = device pixels per displayed-image (full-resolution)
/// pixel: 1 = 1:1 "actual pixels", 2 = 200 %, 0.5 = 50 %.
nonisolated enum ZoomLevel: Hashable, Sendable {
    case fit, fill
    case ratio(Double)

    /// Levels offered in the zoom menu / stepped through by ⌘= / ⌘-.
    static let steps: [Double] = [0.25, 0.5, 1, 2, 4]
    static let maxRatio: Double = 8
}

/// Zoom + pan transform of the canvas: which rect of the view the displayed image occupies.
/// Pure value math (no UI), shared by the Develop canvas and the full-screen preview.
nonisolated struct CanvasViewport: Equatable, Sendable {
    /// View size in points.
    var canvasSize: CGSize
    /// Size of the displayed image in full-resolution pixels (`CanvasGeometry.displayedImageSize`).
    var displayedSize: CGSize
    /// Backing scale (device pixels per point).
    var displayScale: CGFloat = 2
    /// Margin around the image at Fit (points).
    var margin: CGFloat = 16
    var level: ZoomLevel = .fit
    /// Displayed-normalized point (0…1, top-left origin) shown at the view center (ignored at Fit).
    var center = CGPoint(x: 0.5, y: 0.5)

    var isValid: Bool {
        canvasSize.width > 0 && canvasSize.height > 0 && displayedSize.width > 0 && displayedSize.height > 0
    }

    /// View points per displayed-image pixel at Fit / Fill.
    var fitScale: CGFloat {
        guard isValid else { return 0 }
        return max(0, min((canvasSize.width - 2 * margin) / displayedSize.width,
                          (canvasSize.height - 2 * margin) / displayedSize.height))
    }
    var fillScale: CGFloat {
        guard isValid else { return 0 }
        return max(canvasSize.width / displayedSize.width, canvasSize.height / displayedSize.height)
    }

    /// View points per displayed-image pixel at `level`.
    func scale(for level: ZoomLevel) -> CGFloat {
        switch level {
        case .fit: fitScale
        case .fill: fillScale
        case .ratio(let r): CGFloat(r) / max(displayScale, 0.1)
        }
    }

    /// View points per displayed-image pixel.
    var scale: CGFloat { scale(for: level) }
    /// Device pixels per displayed-image pixel (1 = 1:1).
    var pixelRatio: CGFloat { scale * displayScale }
    /// Zoomed past Fit (panning possible, hand tool).
    var isZoomed: Bool { level != .fit && scale > fitScale * 1.001 }

    /// Where the whole displayed image is drawn (view coordinates, top-left origin): centered at
    /// Fit or when smaller than the view, otherwise positioned by `center` and clamped so the
    /// image always covers the view (can't be dragged out of sight). Pixel-aligned.
    var imageRect: CGRect {
        guard isValid else { return .zero }
        let s = scale
        let size = CGSize(width: displayedSize.width * s, height: displayedSize.height * s)
        if level == .fit {
            return CGRect(x: (canvasSize.width - size.width) / 2, y: (canvasSize.height - size.height) / 2,
                          width: size.width, height: size.height)
        }
        func axis(_ view: CGFloat, _ len: CGFloat, _ c: CGFloat) -> CGFloat {
            if len <= view { return (view - len) / 2 }
            let o = view / 2 - c * len
            let snapped = (o * displayScale).rounded() / max(displayScale, 0.1)
            return min(0, max(view - len, snapped))
        }
        return CGRect(x: axis(canvasSize.width, size.width, center.x), y: axis(canvasSize.height, size.height, center.y),
                      width: size.width, height: size.height)
    }

    /// `center` of the clamped `imageRect` (so panning past an edge leaves no dead zone).
    var clampedCenter: CGPoint {
        let r = imageRect
        guard r.width > 0, r.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (canvasSize.width / 2 - r.minX) / r.width, y: (canvasSize.height / 2 - r.minY) / r.height)
    }

    /// Displayed-normalized rect of the image that is visible in the view.
    var visibleDisplayedRect: CGRect {
        let r = imageRect
        guard r.width > 0, r.height > 0 else { return .zero }
        let v = r.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !v.isNull else { return .zero }
        return CGRect(x: (v.minX - r.minX) / r.width, y: (v.minY - r.minY) / r.height,
                      width: v.width / r.width, height: v.height / r.height)
    }

    /// Displayed-normalized point under view point `p` (may be outside 0…1).
    func displayedPoint(fromView p: CGPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: (p.x - r.minX) / max(r.width, 1e-9), y: (p.y - r.minY) / max(r.height, 1e-9))
    }

    /// Switches to `newLevel` keeping the image point under view point `anchor` fixed (nil = the
    /// view center stays put). Anchors outside the image are clamped onto it.
    func zoomed(to newLevel: ZoomLevel, anchor: CGPoint? = nil) -> CanvasViewport {
        var v = self
        v.level = newLevel
        guard isValid, newLevel != .fit else { v.center = CGPoint(x: 0.5, y: 0.5); return v }
        let a = anchor ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        var d = displayedPoint(fromView: a)
        d = CGPoint(x: min(max(d.x, 0), 1), y: min(max(d.y, 0), 1))
        let s = v.scale
        let size = CGSize(width: displayedSize.width * s, height: displayedSize.height * s)
        // Keep d under a: origin = a - d * size; center = (view/2 - origin) / size.
        let origin = CGPoint(x: a.x - d.x * size.width, y: a.y - d.y * size.height)
        v.center = CGPoint(x: (canvasSize.width / 2 - origin.x) / size.width,
                           y: (canvasSize.height / 2 - origin.y) / size.height)
        v.center = v.clampedCenter
        return v
    }

    /// Moves the image by `delta` view points (drag / scroll), clamped.
    func panned(by delta: CGSize) -> CanvasViewport {
        guard isZoomed else { return self }
        var v = self
        let r = imageRect
        v.center = CGPoint(x: (canvasSize.width / 2 - (r.minX + delta.width)) / r.width,
                           y: (canvasSize.height / 2 - (r.minY + delta.height)) / r.height)
        v.center = v.clampedCenter
        return v
    }

    /// Continuous zoom (pinch, ⌘-scroll) by `factor` around `anchor`; snaps to Fit at or below it.
    func magnified(by factor: CGFloat, anchor: CGPoint?) -> CanvasViewport {
        let target = scale * factor
        let fit = fitScale
        if target <= fit * 1.001 { return zoomed(to: .fit, anchor: anchor) }
        let ratio = min(Double(target * displayScale), ZoomLevel.maxRatio)
        return zoomed(to: .ratio(ratio), anchor: anchor)
    }

    /// Next / previous preset for ⌘= / ⌘- (Fit is the bottom of the ladder).
    func stepped(in zoomIn: Bool) -> ZoomLevel {
        let current = Double(pixelRatio)
        let fitRatio = Double(fitScale * displayScale)
        if zoomIn {
            let next = ZoomLevel.steps.first { $0 > current * 1.01 && $0 > fitRatio * 1.01 }
            return next.map(ZoomLevel.ratio) ?? level
        }
        if let prev = ZoomLevel.steps.last(where: { $0 < current * 0.99 }), prev > fitRatio * 1.01 { return .ratio(prev) }
        return .fit
    }

    /// Short label: "Fit", "Fill", "100%".
    static func label(_ level: ZoomLevel) -> String {
        switch level {
        case .fit: "Fit"
        case .fill: "Fill"
        case .ratio(let r): "\(Int((r * 100).rounded()))%"
        }
    }

    /// Current zoom as a percentage of actual pixels, e.g. "23%".
    var percentLabel: String { "\(Int((Double(pixelRatio) * 100).rounded()))%" }
}
