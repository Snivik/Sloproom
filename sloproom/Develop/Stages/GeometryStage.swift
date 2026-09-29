//
//  GeometryStage.swift
//  sloproom
//
//  Stage 6: quarter turns, flip, straighten, crop — exactly GeometryMath's mapping, built as ONE
//  affine transform (single resample; none at all for pure turns/flips/crops).
//
//  Output extent starts at (0, 0):
//    - applyCrop: the crop rect, round(full-res crop size × scale) px.
//      The input is edge-clamped first so sub-pixel sampling at a crop edge that touches the
//      content never pulls in transparency.
//    - !applyCrop (crop tool active): the whole frame; uncovered straighten corners are empty.
//

import Foundation
import CoreGraphics
import CoreImage

nonisolated enum GeometryStage {
    static func apply(_ image: CIImage, settings: EditSettings, context: RenderContext) -> CIImage {
        let geometry = settings.geometry
        guard !geometry.isDefault else { return image }
        let e = image.extent
        guard !e.isInfinite, e.width > 0, e.height > 0 else { return image }
        let input = e.origin == .zero ? image : image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))

        let math = GeometryMath(sourceSize: e.size, geometry: geometry)
        let frame = math.frameSize
        var transform = ciTransform(math: math)
        let cropping = context.applyCrop && !geometry.crop.isFull

        guard cropping else {
            return input.transformed(by: transform).cropped(to: CGRect(origin: .zero, size: frame))
        }
        let c = geometry.crop
        let rect = CGRect(x: c.x * frame.width, y: c.y * frame.height, width: c.width * frame.width, height: c.height * frame.height)
        // Output size from the FULL-resolution crop at the requested scale, so the aspect ratio is
        // exact (±1 px) and fits the target, even though the decoder rounds the scaled width and
        // height separately (up to ~1 px larger than asked).
        var exact = rect.size
        if context.fullSize.width > 0, context.fullSize.height > 0 {
            let s = context.requestedScale ?? min(e.width / context.fullSize.width, e.height / context.fullSize.height)
            let full = GeometryMath(sourceSize: context.fullSize, geometry: geometry).croppedSize
            exact = CGSize(width: full.width * s, height: full.height * s)
        }
        let size = CGSize(width: max(1, exact.width.rounded()), height: max(1, exact.height.rounded()))
        // Crop origin in CI (bottom-left) frame coordinates.
        var origin = CGPoint(x: rect.minX, y: frame.height - rect.maxY)
        if geometry.straightenAngle == 0 {
            // Pixel-aligned: snap so the output is an exact copy of source pixels (no resampling).
            origin = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
        }
        transform = transform.concatenating(CGAffineTransform(translationX: -origin.x, y: -origin.y))
        return input.clampedToExtent().transformed(by: transform).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Source -> frame in Core Image coordinates (bottom-left origin). GeometryMath's
    /// `framePixel(fromSource:)` is affine (top-left coordinates), so three points define it;
    /// it is then conjugated with the y flips of the source and frame.
    static func ciTransform(math: GeometryMath) -> CGAffineTransform {
        let src = math.sourceSize, frame = math.frameSize
        let o = math.framePixel(fromSource: .zero)
        let x = math.framePixel(fromSource: CGPoint(x: 1, y: 0))
        let y = math.framePixel(fromSource: CGPoint(x: 0, y: 1))
        let topLeft = CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: src.height)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: frame.height)
        return flipIn.concatenating(topLeft).concatenating(flipOut)
    }
}
