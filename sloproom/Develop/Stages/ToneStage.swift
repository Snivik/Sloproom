//
//  ToneStage.swift
//  sloproom
//
//  Stage 2: contrast, highlights, shadows, whites, blacks.
//  NOTE: tone.exposure is applied in RawDecodeStage (scene-linear, before the base curve).
//
//  Input: linear working space, display-referred (after CIRAWFilter's base tone curve).
//  The curve works on perceptual luminance P = Y^(1/2.2) and is applied back as a luminance
//  ratio, so hues don't shift. Highlights/shadows are driven by an edge-aware smooth luminance
//  base (local tone mapping: bright/dark REGIONS move, local detail is kept, no halos).
//

import Foundation
import CoreGraphics
import CoreImage

nonisolated enum ToneStage {
    static func apply(_ image: CIImage, settings: EditSettings, context: RenderContext) -> CIImage {
        let t = settings.tone
        return AdjustmentOps.tone(image, .init(contrast: t.contrast, highlights: t.highlights, shadows: t.shadows,
                                               whites: t.whites, blacks: t.blacks), context: context)
    }
}
