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

    /// Constants of the tone model, calibrated against Lightroom Classic exports
    /// (Tools/lrmatch_check.swift). Highlights / Shadows are exposure changes (EV) driven by the
    /// edge-aware base's log2 luminance `lb`: at ±100 a pixel gets
    /// ±min(slope × softPos(lb − pivot, knee), cap) EV (shadows: softPos(pivot − lb, knee)), i.e. a
    /// power-law compression (−) / expansion (+) of the base around the pivot, applied as a
    /// luminance ratio so local detail and hue are kept. Brighter bases move more for Highlights
    /// (so headroom above white is pulled into view with its detail) and the brightest point stays
    /// the brightest in its neighbourhood.
    nonisolated struct ToneModel: Sendable {
        /// (slope EV per stop, pivot log2 Y, knee width in stops, cap EV)
        var highlightsNeg = SIMD4<Double>(0.451, -2.72, 0.94, 1.50)
        var highlightsPos = SIMD4<Double>(0.390, -2.64, 1.23, 1.36)
        var shadowsNeg = SIMD4<Double>(0.723, -2.46, 0.71, 1.56)
        var shadowsPos = SIMD4<Double>(0.701, -2.42, 0.67, 2.34)
        /// Share of the smooth base (vs the pixel itself) driving highlights / shadows.
        var baseMix = 1.0
        /// Edge-aware base: radius (fraction of the long side) and guided-filter eps (P²).
        var baseRadius = 0.025
        var baseEps = 0.021
        /// Share of the local detail (pixel − base, in P) whose amplitude Highlights / Shadows keep
        /// (0 = scaled with the region like a ratio, 1 = kept as is).
        var highlightsDetailKeep = 1.3
        var shadowsDetailKeep = 0.0
        /// Contrast exponent: P is raised to 2^(contrastK × c) around the pivot.
        var contrastK = 0.6
        var whitesK = 0.35
        var blacksK = 0.07
        /// Deepest shadows (P range) where lifting adds neutral light instead of scaling color.
        var liftNeutral = SIMD2<Double>(0.015, 0.1)

        static let lightroom = ToneModel()
        /// The model in use. Only calibration harnesses change it.
        nonisolated(unsafe) static var current = ToneModel.lightroom
    }

    static func tone(_ image: CIImage, _ p: ToneParams, context: RenderContext) -> CIImage {
        guard !p.isIdentity else { return image }
        let local = p.highlights != 0 || p.shadows != 0
        let m = ToneModel.current
        var base = image
        if local {
            let luma = perceptualLuma(image)
            base = edgeAwareBase(luma, guide: luma, radiusFraction: m.baseRadius, eps: m.baseEps, context: context)
        }
        let n = { (v: Double) in (v / 100).clamped(to: -1...1) }
        func v4(_ s: SIMD4<Double>) -> CIVector { DevelopKernels.vector(s.x, s.y, s.z, s.w) }
        return DevelopKernels.apply(DevelopKernels.tone, image, [
            base,
            DevelopKernels.vector(n(p.contrast), n(p.highlights), n(p.shadows), n(p.whites)),
            DevelopKernels.vector(n(p.blacks), local ? 1 : 0, m.liftNeutral.x, m.liftNeutral.y),
            v4(m.highlightsNeg), v4(m.highlightsPos), v4(m.shadowsNeg), v4(m.shadowsPos),
            DevelopKernels.vector(m.baseMix, m.contrastK, m.whitesK, m.blacksK),
            DevelopKernels.vector(m.highlightsDetailKeep, m.shadowsDetailKeep),
        ])
    }

    // MARK: - Presence

    /// Constants of Texture / Clarity / Dehaze, calibrated against Lightroom Classic exports
    /// (Tools/lrmatch_check.swift). Radii are fractions of the image's long side.
    nonisolated struct PresenceModel: Sendable {
        /// Texture: unsharp-mask radius and amount at +100 / −100.
        var textureRadius = 0.0010
        var texturePos = 0.246, textureNeg = 0.199
        /// Clarity: edge-aware base radius / eps (P²) and amount at +100 / −100.
        var clarityRadius = 0.0052, clarityEps = 0.042
        var clarityPos = 1.17, clarityNeg = 0.594
        /// Dehaze dark-channel base radius.
        var dehazeRadius = 0.015
        /// Dehaze > 0: (strength ω, airlight A in P, minimum transmission, dark-channel exponent).
        var dehazePlus = SIMD4<Double>(0.62, 0.966, 0.42, 0.83)
        /// Dehaze < 0: (veil density, extra density × dark channel, veil level in P, desaturation).
        var dehazeMinus = SIMD4<Double>(0.227, 1.061, 1.098, 0.0)

        static let lightroom = PresenceModel()
        /// The model in use. Only calibration harnesses change it.
        nonisolated(unsafe) static var current = PresenceModel.lightroom
    }

    /// Texture (fine/medium detail, unsharp mask) and clarity (midtone local contrast around a large
    /// edge-aware base), -100...100.
    static func detail(_ image: CIImage, texture: Double, clarity: Double, context: RenderContext) -> CIImage {
        guard texture != 0 || clarity != 0 else { return image }
        let m = PresenceModel.current
        let long = max(image.extent.width, image.extent.height)
        let luma = perceptualLuma(image)
        var texBlur = luma, base = luma
        if texture != 0 {
            texBlur = blur(luma, sigma: CGFloat(m.textureRadius) * long)
        }
        if clarity != 0 {
            base = edgeAwareBase(luma, guide: luma, radiusFraction: CGFloat(m.clarityRadius), eps: m.clarityEps, context: context)
        }
        return DevelopKernels.apply(DevelopKernels.detail, image, [
            texBlur, base,
            DevelopKernels.vector((texture / 100).clamped(to: -1...1), (clarity / 100).clamped(to: -1...1)),
            DevelopKernels.vector(m.texturePos, m.textureNeg, m.clarityPos, m.clarityNeg),
        ])
    }

    /// Dehaze -100...100 (dark-channel prior on P-encoded channels with an edge-aware haze estimate).
    static func dehaze(_ image: CIImage, amount: Double, context: RenderContext) -> CIImage {
        guard amount != 0 else { return image }
        let m = PresenceModel.current
        let dark = DevelopKernels.apply(DevelopKernels.darkChannel, image, [])
        // Minimum filter (on the small image) so bright details don't read as haze.
        let base = edgeAwareBase(dark, guide: perceptualLuma(image), radiusFraction: CGFloat(m.dehazeRadius), context: context) {
            $0.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1])
        }
        func v4(_ s: SIMD4<Double>) -> CIVector { DevelopKernels.vector(s.x, s.y, s.z, s.w) }
        return DevelopKernels.apply(DevelopKernels.dehaze, image, [base, (amount / 100).clamped(to: -1...1),
                                                                   v4(m.dehazePlus), v4(m.dehazeMinus)])
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
