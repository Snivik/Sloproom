//
//  MaskStage.swift
//  sloproom
//
//  Stage 5: local adjustments. For each enabled mask with non-zero adjustments (in order):
//  build a grayscale mask image (white = full effect) over the input's extent
//  (MaskRenderer: linear / radial gradients, rasterized + cached brush strokes, inversion),
//  render LocalAdjustmentRenderer.apply(current, mask.adjustments, context:) and blend it
//  over the current image with CIBlendWithMask. Masks chain: each one sees the previous result.
//

import Foundation
import CoreGraphics
import CoreImage

nonisolated enum MaskStage {
    static func apply(_ image: CIImage, settings: EditSettings, context: RenderContext) -> CIImage {
        let masks = settings.masks.filter { $0.isEnabled && !$0.adjustments.isDefault }
        guard !masks.isEmpty else { return image }
        let extent = image.extent
        var result = image
        for mask in masks {
            guard let maskImage = MaskRenderer.maskImage(for: mask, context: context) else { continue }
            let adjusted = LocalAdjustmentRenderer.apply(result, mask.adjustments, context: context)
            if adjusted === result { continue } // renderer made no change
            result = adjusted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: result,
                kCIInputMaskImageKey: maskImage,
            ]).cropped(to: extent)
        }
        return result
    }
}
