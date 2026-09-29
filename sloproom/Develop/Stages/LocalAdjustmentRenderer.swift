//
//  LocalAdjustmentRenderer.swift
//  sloproom
//
//  Applies a set of LocalAdjustments to a whole image (no masking). MaskStage blends the
//  result through each mask. Reuses the global stage operations (AdjustmentOps), so a local
//  "+50 shadows" looks like the global one inside the mask.
//
//  Input/output: linear working space, extent (0, 0, W, H) preserved.
//

import Foundation
import CoreGraphics
import CoreImage

nonisolated enum LocalAdjustmentRenderer {
    /// - Parameters:
    ///   - image: linear working-space image, extent (0, 0, W, H).
    ///   - adj: local adjustment values (-100...100; exposure -4...4 EV).
    ///   - context: render context (radii are relative to the image size, so it is only informational).
    static func apply(_ image: CIImage, _ adj: LocalAdjustments, context: RenderContext) -> CIImage {
        guard !adj.isDefault else { return image }
        var out = AdjustmentOps.temperatureTint(image, temperature: adj.temperature, tint: adj.tint)
        out = AdjustmentOps.exposure(out, ev: adj.exposure.clamped(to: LocalAdjustments.exposureRange))
        out = AdjustmentOps.tone(out, .init(contrast: adj.contrast, highlights: adj.highlights, shadows: adj.shadows,
                                            whites: adj.whites, blacks: adj.blacks), context: context)
        out = AdjustmentOps.dehaze(out, amount: adj.dehaze, context: context)
        out = AdjustmentOps.detail(out, texture: adj.texture, clarity: adj.clarity, context: context)
        out = AdjustmentOps.vibranceSaturation(out, vibrance: 0, saturation: adj.saturation)
        return out.cropped(to: image.extent)
    }
}
