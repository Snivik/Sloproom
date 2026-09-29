//
//  EffectsStage.swift
//  sloproom
//
//  Stage 7: post-crop vignette and grain (settings.effects), relative to the final extent.
//
//  Input: linear working space, the final (cropped) image with extent (0, 0, W, H).
//  - Vignette: elliptical (roundness 0) … circular (+100) … rounded-rectangle (-100) falloff
//    around the frame center; midpoint = where it starts, feather = transition width. Applied
//    to perceptual luminance (darkening multiplies, lightening moves towards white).
//  - Grain: monochrome, deterministic per photo (`context.seed`). The noise lives in full-
//    resolution pixel units, so a thumbnail looks like a downscaled export (finer-than-a-pixel
//    grain averages out instead of turning into a different pattern).
//

import Foundation
import CoreGraphics
import CoreImage

nonisolated enum EffectsStage {
    static func apply(_ image: CIImage, settings: EditSettings, context: RenderContext) -> CIImage {
        let e = settings.effects
        guard !e.isDefault else { return image }
        var out = image
        if e.vignetteAmount != 0 { out = vignette(out, e) }
        if e.grainAmount != 0 { out = grain(out, e, context: context) }
        return out
    }

    static func vignette(_ image: CIImage, _ e: Effects) -> CIImage {
        let r = image.extent
        guard r.width > 0, r.height > 0 else { return image }
        return DevelopKernels.apply(DevelopKernels.vignette, image, [
            CIVector(cgRect: r),
            DevelopKernels.vector((e.vignetteAmount / 100).clamped(to: -1...1),
                                  (e.vignetteMidpoint / 100).clamped(to: 0...1),
                                  (e.vignetteRoundness / 100).clamped(to: -1...1),
                                  (e.vignetteFeather / 100).clamped(to: 0...1)),
        ])
    }

    static func grain(_ image: CIImage, _ e: Effects, context: RenderContext) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, context.scale > 0,
              let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        // Grain cell size in full-resolution pixels (bigger sensors get proportionally bigger grain).
        let fullLong = max(extent.width, extent.height) / context.scale
        let cellFull = (0.8 + e.grainSize.clamped(to: 0...100) / 100 * 2.4) * max(1, Double(fullLong) / 6000)
        let cellPx = cellFull * Double(context.scale)
        let seed = context.seed
        let offset = CGAffineTransform(translationX: -CGFloat(seed % 509), y: -CGFloat((seed / 509) % 503))
        let noise = random.transformed(by: offset)
        // Roughness mixes smooth (blurred, re-normalized) and rough (raw) noise.
        let rough = e.grainRoughness.clamped(to: 0...100) / 100
        let smooth = noise.applyingGaussianBlur(sigma: 1).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 3.5, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: -1.25, y: 0, z: 0, w: 0),
        ])
        let mixed = smooth.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: noise, "inputTime": rough,
        ])
        let placed = mixed.transformed(by: CGAffineTransform(scaleX: cellPx, y: cellPx)).cropped(to: extent)
        // Sub-pixel grain averages out: std of a box average of 1/cellPx² cells ≈ cellPx.
        let amount = e.grainAmount.clamped(to: 0...100) / 100 * 0.1 * min(1, cellPx)
        return DevelopKernels.apply(DevelopKernels.grain, image, [placed, amount])
    }
}
