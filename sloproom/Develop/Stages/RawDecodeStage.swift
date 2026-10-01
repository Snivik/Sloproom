//
//  RawDecodeStage.swift
//  sloproom
//
//  Stage 1: decode + white balance + exposure + downscale.
//  Output: oriented, uncropped image with extent (0, 0, W, H) at the requested scale,
//  in the linear working space.
//
//  RAW: CIRAWFilter does demosaic, white balance (camera space), exposure and baseline exposure
//  in scene-linear light, then its base tone curve ("boost") and gamut mapping, and outputs
//  display-referred LINEAR extended sRGB. With `extendedDynamicRangeAmount` the output keeps the
//  highlights above diffuse white (1.0 = diffuse white, up to ~2.7 = the brightest raw data at
//  default exposure) instead of clipping them; later stages work on that range and OutputStage
//  rolls it off into 0…1 at the very end. The baseline exposure gets a camera-matched offset
//  (BaselineExposure) so "no edits" looks like the camera JPEG.
//

import Foundation
import CoreGraphics
import CoreImage

nonisolated enum RawDecodeStage {
    /// CIRAWFilter.extendedDynamicRangeAmount (0 = SDR, clipped at 1; 2 = maximum headroom).
    static let extendedDynamicRange: Float = 2
    /// Fraction of the raw clip level (max channel) where highlights start / finish fading to neutral.
    static let clipNeutralStart = 0.2
    static let clipNeutralEnd = 0.75

    static func apply(source: RenderSource, settings: EditSettings, scale: CGFloat, draft: Bool) -> CIImage {
        let wb = settings.whiteBalance
        let exposure = settings.tone.exposure
        var image: CIImage

        if let raw = source.rawFilter {
            source.lock.lock()
            // The filter is shared and mutable: set EVERY property we touch on every render.
            let decodeScale = cleanDecodeScale(scale, size: source.orientedSize)
            raw.scaleFactor = Float(decodeScale)
            raw.isDraftModeEnabled = draft
            raw.exposure = Float(exposure)
            raw.baselineExposure = source.defaultBaselineExposure + Float(source.baselineOffset)
            // Keep the scene highlights above diffuse white (up to ~1.5 stops) instead of letting the
            // filter's SDR output clip them: Highlights / Whites / Exposure− recover detail from them,
            // and OutputStage rolls them off at the end of the pipeline.
            raw.extendedDynamicRangeAmount = Self.extendedDynamicRange
            switch wb.mode {
            case .asShot:
                raw.neutralTemperature = Float(source.asShotTemperature ?? 6500)
                raw.neutralTint = Float(source.asShotTint ?? 0)
            case .custom:
                raw.neutralTemperature = Float(wb.temperature.clamped(to: WhiteBalance.temperatureRange))
                raw.neutralTint = Float(wb.tint.clamped(to: WhiteBalance.tintRange))
            }
            image = raw.outputImage ?? CIImage.empty()
            source.lock.unlock()
            // Partially clipped raw highlights are reconstructed with a color cast (fully clipped
            // ones come out neutral): fade them to neutral towards the clip level, like Lightroom's
            // highlight recovery, so pulling them into view shows clean white/grey, not orange.
            if source.highlightClip > 0 {
                let clip = source.highlightClip * pow(2, exposure)
                image = DevelopKernels.apply(DevelopKernels.clipNeutral, image,
                                             [DevelopKernels.vector(Self.clipNeutralStart * clip, Self.clipNeutralEnd * clip)])
            }
            if decodeScale > scale * 1.0001 {
                // Resample the small remainder; a clamped margin gives the filter real edge pixels.
                let e = image.extent
                let r = scale / decodeScale
                image = image.clampedToExtent().cropped(to: e.insetBy(dx: -8, dy: -8))
                    .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: r, kCIInputAspectRatioKey: 1])
                    .cropped(to: CGRect(x: e.minX * r, y: e.minY * r, width: e.width * r, height: e.height * r))
            }
        } else {
            image = source.image ?? CIImage.empty()
            if scale < 1 {
                image = draft
                    ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    : image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            }
            if wb.mode == .custom {
                // Non-RAW: treat temperature/tint relative to D65 (6500 K, 0).
                image = image.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: CGFloat(wb.temperature), y: CGFloat(wb.tint)),
                    "inputTargetNeutral": CIVector(x: 6500, y: 0),
                ])
            }
            if exposure != 0 {
                image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
            }
        }

        // Normalize extent to start at (0, 0) and drop fractional/infinite edges.
        let e = image.extent
        guard !e.isInfinite, !e.isEmpty else { return image }
        image = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        // Whole pixels only, and never the partially covered last row/column a resampler adds.
        let expected = CGSize(width: (source.orientedSize.width * scale + 0.01).rounded(.down),
                              height: (source.orientedSize.height * scale + 0.01).rounded(.down))
        let size = CGSize(width: min(e.width.rounded(.down), max(1, expected.width)),
                          height: min(e.height.rounded(.down), max(1, expected.height)))
        return image.cropped(to: CGRect(origin: .zero, size: size))
    }
}

nonisolated extension RawDecodeStage {
    /// CIRAWFilter rounds its output size UP when the scaled size isn't whole and fills the extra
    /// row/column with edge garbage that bleeds a few pixels in (e.g. a bright line along the top).
    /// Returns a decode scale ≥ `scale` at which BOTH dimensions are whole pixels — the smallest
    /// j / gcd(width, height) (for 8368×5584 that is multiples of 1/16) — so the caller only has to
    /// Lanczos-downscale the small remainder. For awkward sizes (small gcd) it nudges the scale so
    /// the height lands just below a whole pixel instead.
    static func cleanDecodeScale(_ scale: CGFloat, size: CGSize) -> CGFloat {
        guard scale < 1, size.width >= 1, size.height >= 1 else { return scale }
        var a = Int(size.width), b = Int(size.height)
        while b != 0 { (a, b) = (b, a % b) }
        let g = CGFloat(a)
        if g >= 8 { return min(1, (scale * g - 1e-9).rounded(.up) / g) }
        let v = size.height * scale
        return v == v.rounded(.down) ? scale : (v.rounded(.down) - 0.002) / size.height
    }
}

nonisolated extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
