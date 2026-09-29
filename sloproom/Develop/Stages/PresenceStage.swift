//
//  PresenceStage.swift
//  sloproom
//
//  Stage 3: texture, clarity, dehaze, vibrance, saturation.
//
//  Input: linear working space. Texture/clarity work on perceptual luminance (band-pass /
//  edge-aware local contrast); dehaze is a dark-channel-prior in linear light; vibrance and
//  saturation scale Oklab chroma.
//

import Foundation
import CoreGraphics
import CoreImage

nonisolated enum PresenceStage {
    static func apply(_ image: CIImage, settings: EditSettings, context: RenderContext) -> CIImage {
        let p = settings.presence
        guard !p.isDefault else { return image }
        var out = AdjustmentOps.dehaze(image, amount: p.dehaze, context: context)
        out = AdjustmentOps.detail(out, texture: p.texture, clarity: p.clarity, context: context)
        out = AdjustmentOps.vibranceSaturation(out, vibrance: p.vibrance, saturation: p.saturation)
        return out
    }
}
