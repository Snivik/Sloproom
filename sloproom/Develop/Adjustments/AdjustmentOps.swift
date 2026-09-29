//
//  AdjustmentOps.swift
//  sloproom
//
//  Building blocks shared by the global stages (Tone, Presence, Color Mixer, Effects) and
//  LocalAdjustmentRenderer (masks). All take / return linear working-space images whose extent
//  is (0, 0, W, H) and preserve that extent.
//
//  Radii are expressed as a FRACTION OF THE IMAGE'S LONG SIDE, so a proxy render, a thumbnail and
//  a full-resolution export produce the same look (just at different resolutions).
//

import Foundation
import CoreGraphics
import CoreImage

nonisolated enum AdjustmentOps {

    // MARK: - Smoothing helpers

    /// Perceptual luminance (P = Y^(1/2.2)) in every channel.
    static func perceptualLuma(_ image: CIImage) -> CIImage {
        DevelopKernels.apply(DevelopKernels.perceptualLuma, image, [])
    }

    /// Gaussian blur (sigma in pixels) with clamped edges; keeps `image.extent`.
    static func blur(_ image: CIImage, sigma: CGFloat) -> CIImage {
        guard sigma >= 0.3 else { return image }
        return image.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: image.extent)
    }

    /// Smooth, edge-aware version of `value` (radius = `radiusFraction` × long side), computed with
    /// a fast guided filter (He et al.): the linear model q = a·guide + b is fitted on a small
    /// downsampled copy, its coefficients are blurred and upsampled, and applied at full
    /// resolution. Near strong edges (guide variance >> eps) q follows the guide, so there are
    /// no halos; in flat regions it is a plain blur. `eps` is in guide units squared (P ≈ 0...1).
    /// `prefilter` runs on the downsampled value before fitting (cheap there).
    static func edgeAwareBase(_ value: CIImage, guide: CIImage, radiusFraction: CGFloat, eps: Double = 0.004,
                              context: RenderContext, prefilter: ((CIImage) -> CIImage)? = nil) -> CIImage {
        let extent = value.extent
        let long = max(extent.width, extent.height)
        let radius = radiusFraction * long
        // Work at a resolution where the window radius is ~3 px.
        let scale = min(1, 3 / max(radius, 1))
        func down(_ img: CIImage) -> CIImage {
            guard scale < 1 else { return img }
            return img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        }
        let smallGuide = down(guide)
        let smallExtent = smallGuide.extent
        var smallValue = value === guide ? smallGuide : down(value).cropped(to: smallExtent)
        if let prefilter { smallValue = prefilter(smallValue).cropped(to: smallExtent) }
        let sigma = Double(radius * scale)
        let pack = DevelopKernels.apply(DevelopKernels.guidedPack, smallGuide, [smallValue])
        let means = pack.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: smallExtent)
        let ab = DevelopKernels.apply(DevelopKernels.guidedCoefficients, means, [eps])
        var abMean = ab.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: smallExtent)
        if scale < 1 {
            abMean = materialize(abMean, context: context.ciContext)
            let sx = extent.width / smallExtent.width, sy = extent.height / smallExtent.height
            abMean = abMean.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy).translatedBy(x: -smallExtent.minX, y: -smallExtent.minY))
                .cropped(to: extent)
        }
        return DevelopKernels.apply(DevelopKernels.guidedApply, guide, [abMean])
    }

    /// Renders a (small) image into memory now and returns it as a leaf image. Without this, every
    /// output tile of a large render would re-evaluate the whole upstream graph to rebuild it.
    static func materialize(_ image: CIImage, context: CIContext, maxPixels: Int = 4_000_000) -> CIImage {
        let e = image.extent.integral
        let w = Int(e.width), h = Int(e.height)
        guard w > 0, h > 0, w * h <= maxPixels else { return image }
        var data = Data(count: w * h * 8)
        data.withUnsafeMutableBytes { buf in
            context.render(image, toBitmap: buf.baseAddress!, rowBytes: w * 8, bounds: e, format: .RGBAh, colorSpace: nil)
        }
        return CIImage(bitmapData: data, bytesPerRow: w * 8, size: e.size, format: .RGBAh, colorSpace: nil)
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
    }

    // MARK: - Tone

    /// Contrast / highlights / shadows / whites / blacks, each -100...100 (Lightroom units).
    struct ToneParams: Equatable, Sendable {
        var contrast = 0.0, highlights = 0.0, shadows = 0.0, whites = 0.0, blacks = 0.0
        var isIdentity: Bool { self == ToneParams() }
    }

    /// Radius of the smooth luminance base used by highlights/shadows.
    static let toneBaseRadius: CGFloat = 0.02

    static func tone(_ image: CIImage, _ p: ToneParams, context: RenderContext) -> CIImage {
        guard !p.isIdentity else { return image }
        let local = p.highlights != 0 || p.shadows != 0
        var base = image
        if local {
            let luma = perceptualLuma(image)
            base = edgeAwareBase(luma, guide: luma, radiusFraction: toneBaseRadius, eps: 0.01, context: context)
        }
        let n = { (v: Double) in (v / 100).clamped(to: -1...1) }
        return DevelopKernels.apply(DevelopKernels.tone, image, [
            base,
            DevelopKernels.vector(n(p.contrast), n(p.highlights), n(p.shadows), n(p.whites)),
            DevelopKernels.vector(n(p.blacks), local ? 1 : 0),
        ])
    }

    // MARK: - Presence

    /// Texture (fine detail, band-pass) and clarity (midtone local contrast, edge-aware), -100...100.
    static func detail(_ image: CIImage, texture: Double, clarity: Double, context: RenderContext) -> CIImage {
        guard texture != 0 || clarity != 0 else { return image }
        let long = max(image.extent.width, image.extent.height)
        let luma = perceptualLuma(image)
        var fine = luma, coarse = luma, base = luma
        if texture != 0 {
            fine = blur(luma, sigma: 0.00012 * long)
            coarse = blur(luma, sigma: 0.0007 * long)
        }
        if clarity != 0 {
            base = edgeAwareBase(luma, guide: luma, radiusFraction: 0.008, eps: 0.003, context: context)
        }
        return DevelopKernels.apply(DevelopKernels.detail, image, [
            fine, coarse, base,
            DevelopKernels.vector((texture / 100).clamped(to: -1...1), (clarity / 100).clamped(to: -1...1)),
        ])
    }

    /// Dehaze -100...100 (dark-channel prior with an edge-aware haze estimate).
    static func dehaze(_ image: CIImage, amount: Double, context: RenderContext) -> CIImage {
        guard amount != 0 else { return image }
        let dark = DevelopKernels.apply(DevelopKernels.darkChannel, image, [])
        // Minimum filter (on the small image) so bright details don't read as haze.
        let base = edgeAwareBase(dark, guide: perceptualLuma(image), radiusFraction: 0.015, context: context) {
            $0.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1])
        }
        return DevelopKernels.apply(DevelopKernels.dehaze, image, [base, (amount / 100).clamped(to: -1...1)])
    }

    /// Vibrance and saturation -100...100 (Oklab chroma; vibrance protects saturated colors & skin).
    static func vibranceSaturation(_ image: CIImage, vibrance: Double, saturation: Double) -> CIImage {
        guard vibrance != 0 || saturation != 0 else { return image }
        return DevelopKernels.apply(DevelopKernels.vibranceSaturation, image, [
            DevelopKernels.vector((vibrance / 100).clamped(to: -1...1), (saturation / 100).clamped(to: -1...1)),
        ])
    }

    // MARK: - White balance / exposure (relative, for local adjustments)

    /// Relative temperature (+ warmer) / tint (+ magenta) shift, -100...100, luminance preserving.
    static func temperatureTint(_ image: CIImage, temperature: Double, tint: Double) -> CIImage {
        guard temperature != 0 || tint != 0 else { return image }
        let t = (temperature / 100).clamped(to: -1...1), m = (tint / 100).clamped(to: -1...1)
        var r = pow(2, 0.45 * t), g = pow(2, -0.35 * m), b = pow(2, -0.6 * t)
        // Keep luminance constant.
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        r /= y; g /= y; b /= y
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
        ])
    }

    /// Linear exposure gain in EV.
    static func exposure(_ image: CIImage, ev: Double) -> CIImage {
        guard ev != 0 else { return image }
        return image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
    }
}

nonisolated extension EditSettings {
    /// True when some stage reads a neighbourhood of the image (blurred bases), i.e. the graph
    /// branches and benefits from a materialized decode in non-caching contexts.
    var usesLocalOperations: Bool {
        tone.highlights != 0 || tone.shadows != 0 || presence.texture != 0 || presence.clarity != 0
            || presence.dehaze != 0
            || masks.contains { m in
                let a = m.adjustments
                return m.isEnabled && (a.highlights != 0 || a.shadows != 0 || a.texture != 0 || a.clarity != 0 || a.dehaze != 0)
            }
    }
}
