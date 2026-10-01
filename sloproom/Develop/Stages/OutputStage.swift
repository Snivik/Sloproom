//
//  OutputStage.swift
//  sloproom
//
//  Stage 8: output transform. RAW decodes keep the scene highlights above diffuse white
//  (RawDecodeStage, `extendedDynamicRangeAmount`), so every stage before this one can pull detail
//  out of them (Highlights, Whites, Exposure−, masks). Here that extended range is rolled off into
//  0…1 with a smooth per-channel shoulder in perceptual space (P = c^(1/2.2)): identity below the
//  knee, C1-continuous, asymptotic to white; the hue is then re-imposed from the input (the middle
//  channel is placed between the new max and min), so bright colors desaturate towards white without
//  turning e.g. a bright blue sky cyan (`hueKeep` = how much of the hue is restored). It replaces CIRAWFilter's SDR clip, which used to
//  flatten everything above 1 before the sliders ever saw it.
//
//  Non-RAW sources are display-referred already (`RenderContext.extendedRange == false`): untouched.
//

import Foundation
import CoreGraphics
import CoreImage

nonisolated enum OutputStage {
    /// Shoulder knee in perceptual units (P 0.86 ≈ 72 % linear ≈ L* 88).
    static let knee: Double = 0.86
    /// How much of the input hue is re-imposed after the per-channel curve (0 = plain per-channel).
    nonisolated(unsafe) static var hueKeep: Double = 0.5   // calibration harness may change it

    static func apply(_ image: CIImage, settings: EditSettings, context: RenderContext) -> CIImage {
        guard context.extendedRange else { return image }
        return rollOff(image)
    }

    /// The shoulder alone (also usable on any extended-range linear image).
    static func rollOff(_ image: CIImage) -> CIImage {
        DevelopKernels.apply(DevelopKernels.shoulder, image, [knee, hueKeep])
    }
}
