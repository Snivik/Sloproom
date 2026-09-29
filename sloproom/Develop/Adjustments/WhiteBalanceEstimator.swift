//
//  WhiteBalanceEstimator.swift
//  sloproom
//
//  Auto white balance and the white-balance eyedropper (RAW only).
//
//  Both measure a color on a small decode (gray-world over near-neutral pixels, or the average
//  around a clicked point), express its cast as a CIE xy offset from D65, move the filter's
//  `neutralChromaticity` (the assumed illuminant) by that offset and read back the resulting
//  `neutralTemperature` / `neutralTint`. A few iterations converge.
//

import Foundation
import CoreGraphics
import CoreImage

nonisolated enum WhiteBalanceEstimator {
    /// What to neutralize.
    enum Target: Sendable {
        /// Weighted gray world over the whole image (auto WB).
        case auto
        /// A point in oriented source space (top-left normalized), e.g. the eyedropper.
        case point(NormPoint)
    }

    /// Returns (temperature K, tint) that make `target` neutral, or nil (non-RAW / unreadable).
    static func estimate(source: RenderSource, settings: EditSettings, target: Target) -> (temperature: Double, tint: Double)? {
        guard let raw = source.rawFilter else { return nil }
        source.lock.lock()
        defer { source.lock.unlock() }
        let saved = (raw.scaleFactor, raw.neutralTemperature, raw.neutralTint, raw.exposure, raw.baselineExposure, raw.isDraftModeEnabled)
        defer {
            raw.scaleFactor = saved.0; raw.neutralTemperature = saved.1; raw.neutralTint = saved.2
            raw.exposure = saved.3; raw.baselineExposure = saved.4; raw.isDraftModeEnabled = saved.5
        }
        raw.scaleFactor = Float(320 / max(source.orientedSize.width, source.orientedSize.height))
        raw.isDraftModeEnabled = false
        raw.exposure = 0
        raw.baselineExposure = source.defaultBaselineExposure + Float(source.baselineOffset)
        // Start from the current white balance.
        switch settings.whiteBalance.mode {
        case .asShot:
            raw.neutralTemperature = Float(source.asShotTemperature ?? 5500)
            raw.neutralTint = Float(source.asShotTint ?? 0)
        case .custom:
            raw.neutralTemperature = Float(settings.whiteBalance.temperature)
            raw.neutralTint = Float(settings.whiteBalance.tint)
        }
        for _ in 0..<4 {
            guard let image = raw.outputImage, let c = measure(image, target: target) else { return nil }
            let (x, y) = chromaticity(c)
            let dx = x - 0.3127, dy = y - 0.3290
            if abs(dx) < 0.0005 && abs(dy) < 0.0005 { break }
            let n = raw.neutralChromaticity
            raw.neutralChromaticity = CGPoint(x: n.x + dx, y: n.y + dy)
        }
        let t = Double(raw.neutralTemperature).clamped(to: WhiteBalance.temperatureRange)
        let tint = Double(raw.neutralTint).clamped(to: WhiteBalance.tintRange)
        guard t.isFinite, tint.isFinite else { return nil }
        return ((t / 10).rounded() * 10, tint.rounded())
    }

    /// Linear sRGB color to neutralize.
    private static func measure(_ image: CIImage, target: Target) -> SIMD3<Double>? {
        let e = image.extent
        guard !e.isInfinite, e.width >= 4, e.height >= 4 else { return nil }
        let w = Int(e.width), h = Int(e.height)
        var px = [Float](repeating: 0, count: w * h * 4)
        RenderPipeline.context.render(image, toBitmap: &px, rowBytes: w * 16, bounds: CGRect(x: e.minX, y: e.minY, width: CGFloat(w), height: CGFloat(h)),
                                      format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        var sum = SIMD3<Double>(0, 0, 0), weight = 0.0
        func add(_ i: Int, _ wgt: Double) {
            sum += SIMD3(Double(px[i * 4]), Double(px[i * 4 + 1]), Double(px[i * 4 + 2])) * wgt
            weight += wgt
        }
        switch target {
        case .point(let p):
            // Bitmap rows are top-down: row 0 = top of the image.
            let cx = Int(p.x * Double(w)), cy = Int(p.y * Double(h))
            let r = max(1, w / 160)
            for yy in max(0, cy - r)...min(h - 1, cy + r) {
                for xx in max(0, cx - r)...min(w - 1, cx + r) { add(yy * w + xx, 1) }
            }
        case .auto:
            for i in 0..<(w * h) {
                let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
                let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                guard y > 0.02, y < 0.9, r > 0, g > 0, b > 0 else { continue }
                // Favour near-neutral pixels (gray-world on likely grays).
                let mx = max(r, g, b), mn = min(r, g, b)
                let sat = (mx - mn) / mx
                add(i, 1 / (1 + 40 * sat * sat))
            }
        }
        guard weight > 0 else { return nil }
        return sum / weight
    }

    /// CIE xy of a linear sRGB color.
    private static func chromaticity(_ c: SIMD3<Double>) -> (Double, Double) {
        let X = 0.4124 * c.x + 0.3576 * c.y + 0.1805 * c.z
        let Y = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        let Z = 0.0193 * c.x + 0.1192 * c.y + 0.9505 * c.z
        let s = max(X + Y + Z, 1e-9)
        return (X / s, Y / s)
    }
}
