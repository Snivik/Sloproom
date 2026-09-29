//
//  MaskRenderer.swift
//  sloproom
//
//  Mask shape -> grayscale CIImage (white = full effect), extent (0, 0, W, H) of the
//  pre-geometry image at render scale. Works at any render scale because shapes are stored
//  normalized (radii / brush sizes relative to the oriented, uncropped image).
//
//  - Linear: CILinearGradient start (1) -> end (0), smoothstep.
//  - Radial: CIRadialGradient scaled into an ellipse and rotated; the drawn ellipse is the
//    outer (0) edge, `feather` moves the full-effect edge inwards; smoothstep.
//  - Brush: strokes rasterized with CoreGraphics (BrushRasterizer, cached).
//
//  Mask values are linear (no color management): 0.5 = 50 % blend.
//

import Foundation
import CoreGraphics
import CoreImage

nonisolated enum MaskRenderer {
    /// The mask for `mask` (inversion applied), or nil if it covers nothing.
    static func maskImage(for mask: Mask, context: RenderContext) -> CIImage? {
        let extent = CGRect(origin: .zero, size: context.imageSize)
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let shape: CIImage?
        switch mask.shape {
        case .linear(let m): shape = linear(m, context: context)
        case .radial(let m): shape = radial(m, context: context)
        case .brush(let m): shape = BrushRasterizer.maskImage(for: m, id: mask.id, context: context)
        }
        if mask.inverted {
            return invert(shape ?? black).cropped(to: extent)
        }
        return shape?.cropped(to: extent)
    }

    static func linear(_ m: LinearGradientMask, context: RenderContext) -> CIImage {
        let p0 = context.ciPoint(m.start)
        var p1 = context.ciPoint(m.end)
        if hypot(p1.x - p0.x, p1.y - p0.y) < 0.5 { p1.y -= 0.5 } // degenerate: hard edge
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(cgPoint: p0),
            "inputPoint1": CIVector(cgPoint: p1),
            "inputColor0": white,
            "inputColor1": blackColor,
        ])?.outputImage ?? black
        return smoothstep(gradient)
    }

    static func radial(_ m: RadialGradientMask, context: RenderContext) -> CIImage {
        let w = context.imageSize.width, h = context.imageSize.height
        let rx = max(CGFloat(m.radiusX) * w, 0.5)
        let ry = max(CGFloat(m.radiusY) * h, 0.5)
        let feather = CGFloat(min(max(m.feather, 0), 100)) / 100
        let inner = min(rx * (1 - feather), rx - 0.75)
        let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputRadius0": max(inner, 0),
            "inputRadius1": rx,
            "inputColor0": white,
            "inputColor1": blackColor,
        ])?.outputImage ?? black
        // Circle of radius rx -> ellipse rx × ry, rotated clockwise on screen (= negative
        // angle in CI's y-up space), moved to the center.
        let theta = CGFloat(m.rotation * .pi / 180)
        let transform = CGAffineTransform(scaleX: 1, y: ry / rx)
            .concatenating(CGAffineTransform(rotationAngle: -theta))
            .concatenating(CGAffineTransform(translationX: context.ciPoint(m.center).x, y: context.ciPoint(m.center).y))
        return smoothstep(gradient.transformed(by: transform))
    }

    /// 1 - x on RGB, alpha 1.
    static func invert(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
    }

    /// 3t² - 2t³ on a 0...1 ramp (softer start/end than a linear ramp, like Lightroom).
    static func smoothstep(_ ramp: CIImage) -> CIImage {
        let c = CIVector(x: 0, y: 0, z: 3, w: -2)
        return ramp.applyingFilter("CIColorPolynomial", parameters: [
            "inputRedCoefficients": c,
            "inputGreenCoefficients": c,
            "inputBlueCoefficients": c,
            "inputAlphaCoefficients": CIVector(x: 1, y: 0, z: 0, w: 0),
        ])
    }

    private static let white = CIColor(red: 1, green: 1, blue: 1)
    private static let blackColor = CIColor(red: 0, green: 0, blue: 0)
    static var black: CIImage { CIImage(color: blackColor) }

    // MARK: - Overlay visualisation

    /// Red, semi-transparent picture of `mask`'s coverage in DISPLAYED (geometry-applied,
    /// cropped) space, sized like a pipeline render into `targetSize`. For the "O" overlay.
    static func coverageImage(for mask: Mask, geometry: Geometry, fullSize: CGSize, targetSize: CGSize,
                              opacity: CGFloat = 0.5) -> CGImage? {
        guard fullSize.width > 0, fullSize.height > 0, targetSize.width > 0, targetSize.height > 0 else { return nil }
        var settings = EditSettings()
        settings.geometry = geometry
        let out = GeometryMath(sourceSize: fullSize, geometry: geometry).croppedSize
        guard out.width > 0, out.height > 0 else { return nil }
        let scale = min(1, targetSize.width / out.width, targetSize.height / out.height)
        let imageSize = CGSize(width: (fullSize.width * scale).rounded(.down), height: (fullSize.height * scale).rounded(.down))
        let context = RenderContext(fullSize: fullSize, imageSize: imageSize, draft: true, applyCrop: true)
        let m = maskImage(for: mask, context: context) ?? black.cropped(to: CGRect(origin: .zero, size: imageSize))
        let displayed = GeometryStage.apply(m, settings: settings, context: context)
        // Unpremultiplied (1, 0, 0, opacity × mask): CIColorMatrix works on unpremultiplied values.
        let tinted = displayed.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: opacity, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 1, y: 0, z: 0, w: 0),
        ])
        let extent = displayed.extent.integral
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return nil }
        return RenderPipeline.context.createCGImage(tinted, from: extent, format: .RGBA8, colorSpace: RenderPipeline.sRGB)
    }

    /// Grayscale picture of a mask at render scale (harness / debugging).
    static func grayscaleImage(for mask: Mask, context: RenderContext) -> CGImage? {
        let extent = CGRect(origin: .zero, size: context.imageSize)
        let m = maskImage(for: mask, context: context) ?? black.cropped(to: extent)
        return RenderPipeline.context.createCGImage(m, from: extent, format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
    }
}
