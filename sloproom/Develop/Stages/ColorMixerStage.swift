//
//  ColorMixerStage.swift
//  sloproom
//
//  Stage 4: per-band HSL (settings.colorMixer).
//
//  One Metal color kernel: hue in OkLCh, eight band centers (red … magenta) with a smooth
//  (C1, partition-of-unity) falloff between neighbouring bands, so there is no posterisation.
//  Hue ±100 shifts ~60 % of the way to the neighbouring band, saturation scales chroma
//  (-100 = gray), luminance scales Oklab L. Near-neutral pixels are left alone.
//

import Foundation
import CoreGraphics
import CoreImage

nonisolated enum ColorMixerStage {
    static func apply(_ image: CIImage, settings: EditSettings, context: RenderContext) -> CIImage {
        let mixer = settings.colorMixer
        guard !mixer.isDefault else { return image }
        func vectors(_ key: KeyPath<HSLAdjustment, Double>) -> [CIVector] {
            let v = ColorBand.allCases.map { (mixer[$0][keyPath: key] / 100).clamped(to: -1...1) }
            return [DevelopKernels.vector(v[0], v[1], v[2], v[3]), DevelopKernels.vector(v[4], v[5], v[6], v[7])]
        }
        return DevelopKernels.apply(DevelopKernels.colorMixer, image,
                                    vectors(\.hue) + vectors(\.saturation) + vectors(\.luminance))
    }
}
