//
//  RenderPipeline.swift
//  sloproom
//
//  EditSettings -> CIImage. Stages run in this FIXED order, one file each in Stages/:
//
//    1. RawDecodeStage   decode (CIRAWFilter / CIImage), white balance, exposure, scale
//    2. ToneStage        contrast, highlights, shadows, whites, blacks (NOT exposure)
//    3. PresenceStage    texture, clarity, dehaze, vibrance, saturation
//    4. ColorMixerStage  per-band HSL
//    5. MaskStage        local adjustments (masks, in oriented uncropped space)
//    6. GeometryStage    quarter turns, flip, straighten, crop
//    7. EffectsStage     post-crop vignette, grain
//
//  Color: Core Image working space is extended linear sRGB (CI default; `workingColorSpace`).
//  Stage inputs/outputs are therefore linear, scene-referred, possibly > 1.0.
//  `renderCGImage` outputs 8-bit Display P3 by default (pass `colorSpace:` for sRGB export).
//
//  Image coordinates inside the pipeline: Core Image, origin BOTTOM-LEFT, and every stage
//  before GeometryStage receives an image whose extent is (0, 0, W, H) = the oriented,
//  uncropped image at `RenderContext.scale`. Use `RenderContext.ciPoint(_:)` to convert a
//  top-left normalized `NormPoint` to CI coordinates.
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Metal
import UniformTypeIdentifiers

/// A decoded, reusable source for one photo. Create with `RenderPipeline.makeSource`.
/// Keep one per open photo for interactive editing: re-rendering reuses the RAW decode setup.
/// The CIRAWFilter is mutable, so rendering from one source is serialized by `lock`.
nonisolated final class RenderSource: @unchecked Sendable {
    let url: URL
    /// CIRAWFilter-backed (RAW/DNG) vs plain image (JPEG/HEIC/TIFF/PNG).
    var isRAW: Bool { rawFilter != nil }
    /// RAW decoder (access only while holding `lock`).
    let rawFilter: CIRAWFilter?
    /// Oriented full-resolution image for non-RAW sources.
    let image: CIImage?
    /// Full-resolution size after EXIF orientation, in pixels.
    let orientedSize: CGSize
    /// Camera white balance (RAW only), for initializing custom WB in the UI.
    let asShotTemperature: Double?
    let asShotTint: Double?
    /// Render with CIRAWFilter draft mode (faster, lower quality demosaic).
    let draft: Bool
    /// CIRAWFilter's own default baseline exposure (RAW only).
    let defaultBaselineExposure: Float
    /// Camera-matched brightness offset in EV added to the baseline (see BaselineExposure).
    let baselineOffset: Double
    /// Deterministic per-file seed (grain).
    let seed: UInt32
    let lock = NSLock()

    init(url: URL, rawFilter: CIRAWFilter?, image: CIImage?, orientedSize: CGSize, draft: Bool, baselineOffset: Double = 0) {
        self.url = url
        self.rawFilter = rawFilter
        self.image = image
        self.orientedSize = orientedSize
        self.asShotTemperature = rawFilter.map { Double($0.neutralTemperature) }
        self.asShotTint = rawFilter.map { Double($0.neutralTint) }
        self.draft = draft
        self.defaultBaselineExposure = rawFilter?.baselineExposure ?? 0
        self.baselineOffset = baselineOffset
        // FNV-1a of the file name: stable across launches (unlike Hasher) and across folders.
        var h: UInt32 = 2166136261
        for b in url.lastPathComponent.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        self.seed = h
    }
}

/// Per-render information passed to every stage after decode.
nonisolated struct RenderContext: Sendable {
    /// Full-resolution oriented, uncropped size (pixels).
    let fullSize: CGSize
    /// Size of the decoded (scaled) oriented uncropped image = extent of stage inputs before geometry.
    let imageSize: CGSize
    /// imageSize / fullSize. Multiply pixel-based radii (blur, grain) by this.
    var scale: CGFloat { fullSize.width > 0 ? imageSize.width / fullSize.width : 1 }
    /// Interactive/draft render: stages may trade quality for speed.
    let draft: Bool
    /// When false (crop tool active) GeometryStage must skip the crop and output the full frame.
    let applyCrop: Bool
    /// The scale RenderPipeline asked the decoder for. Decoders round the scaled width/height
    /// (CIRAWFilter rounds up), so `scale` can differ slightly; GeometryStage sizes its output
    /// from this so the final size fits `targetSize` exactly.
    var requestedScale: CGFloat? = nil
    /// Deterministic per-photo seed (e.g. grain pattern).
    var seed: UInt32 = 0
    /// The context that will draw this render. Stages use it to eagerly render tiny intermediates
    /// (blurred bases), which keeps full-resolution renders from recomputing the whole graph per tile.
    var ciContext: CIContext = RenderPipeline.context

    /// Top-left normalized point (mask space) -> CI coordinates (bottom-left origin) of the
    /// pre-geometry image.
    func ciPoint(_ p: NormPoint) -> CGPoint {
        CGPoint(x: p.x * imageSize.width, y: (1 - p.y) * imageSize.height)
    }
}

nonisolated enum RenderPipeline {
    /// Shared Metal-backed context for previews/export. Engineer E may add an interactive one.
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .cacheIntermediates: false,
            .name: "Sloproom.RenderPipeline",
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    /// Context for interactive Develop rendering: caches intermediates, so re-rendering after a
    /// slider change reuses the RAW demosaic (exposure/WB drag ≈ 5 ms instead of ≈ 40 ms at 1600 px).
    static let interactiveContext: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .cacheIntermediates: true,
            .name: "Sloproom.Interactive",
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// True for camera RAW / DNG files (decoded with CIRAWFilter).
    static func isRAW(url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .rawImage)
    }

    /// Creates a source. Caller must already have sandbox access to `url`
    /// (use `SecurityScopeManager.accessibleURL(for:catalog:)`). Returns nil if unreadable.
    static func makeSource(url: URL, draft: Bool = false) -> RenderSource? {
        if isRAW(url: url), let raw = CIRAWFilter(imageURL: url) {
            let native = raw.nativeSize
            let swapped = (5...8).contains(Int(raw.orientation.rawValue))
            let size = swapped ? CGSize(width: native.height, height: native.width) : native
            let offset = BaselineExposure.offset(url: url, raw: raw)
            return RenderSource(url: url, rawFilter: raw, image: nil, orientedSize: size, draft: draft, baselineOffset: offset)
        }
        guard let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        let normalized = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        return RenderSource(url: url, rawFilter: nil, image: normalized, orientedSize: normalized.extent.size, draft: draft)
    }

    /// Scale (<= 1) so the final (cropped) output fits `targetSize` (pixels). nil = full resolution.
    static func renderScale(source: RenderSource, settings: EditSettings, targetSize: CGSize?, applyCrop: Bool) -> CGFloat {
        guard let targetSize, targetSize.width > 0, targetSize.height > 0 else { return 1 }
        let math = GeometryMath(sourceSize: source.orientedSize, geometry: settings.geometry)
        let out = applyCrop ? math.croppedSize : math.frameSize
        guard out.width > 0, out.height > 0 else { return 1 }
        return min(1, targetSize.width / out.width, targetSize.height / out.height)
    }

    /// Builds the full CIImage graph for `settings`. Cheap (lazy); the work happens when drawn.
    /// - targetSize: pixel box the final output should fit (nil = full resolution).
    /// - applyCrop: false while the crop tool is active (show the whole rotated frame).
    /// - proxyScale: extra downscale (< 1) applied right AFTER decode, for interactive previews:
    ///   the decode stays at the `targetSize` scale (so the interactive context's cached demosaic
    ///   is reused) while all later stages run on fewer pixels.
    static func render(source: RenderSource, settings: EditSettings, targetSize: CGSize? = nil,
                       draft: Bool = false, applyCrop: Bool = true, proxyScale: CGFloat = 1,
                       context ciContext: CIContext = RenderPipeline.context) -> CIImage {
        let scale = renderScale(source: source, settings: settings, targetSize: targetSize, applyCrop: applyCrop)
        var image = RawDecodeStage.apply(source: source, settings: settings, scale: scale, draft: draft || source.draft)
        if proxyScale < 1 {
            let e = image.extent
            image = image.transformed(by: CGAffineTransform(scaleX: proxyScale, y: proxyScale))
                .cropped(to: CGRect(x: 0, y: 0, width: (e.width * proxyScale).rounded(.down),
                                    height: (e.height * proxyScale).rounded(.down)))
        }
        // One-shot renders (previews, export): evaluate the decode once instead of once per branch.
        // The interactive context caches it anyway.
        if ciContext !== interactiveContext, settings.usesLocalOperations {
            image = AdjustmentOps.materialize(image, context: ciContext, maxPixels: 12_000_000)
        }
        let ctx = RenderContext(fullSize: source.orientedSize, imageSize: image.extent.size,
                                draft: draft || source.draft, applyCrop: applyCrop, requestedScale: scale * min(proxyScale, 1),
                                seed: source.seed, ciContext: ciContext)
        return applyStages(image, settings: settings, context: ctx)
    }

    /// Stages 2–7 (tone … effects) on a stage-1 (RawDecodeStage) output with extent (0, 0, W, H).
    /// `render` uses it; zoomed region rendering (Develop/Zoom) feeds it a cached full-res decode.
    static func applyStages(_ decoded: CIImage, settings: EditSettings, context ctx: RenderContext) -> CIImage {
        var image = decoded
        image = ToneStage.apply(image, settings: settings, context: ctx)
        image = PresenceStage.apply(image, settings: settings, context: ctx)
        image = ColorMixerStage.apply(image, settings: settings, context: ctx)
        image = MaskStage.apply(image, settings: settings, context: ctx)
        image = GeometryStage.apply(image, settings: settings, context: ctx)
        image = EffectsStage.apply(image, settings: settings, context: ctx)
        return image
    }

    /// Renders to an 8-bit CGImage using the shared context.
    static func renderCGImage(source: RenderSource, settings: EditSettings, targetSize: CGSize? = nil,
                              draft: Bool = false, applyCrop: Bool = true,
                              colorSpace: CGColorSpace = RenderPipeline.displayP3,
                              proxyScale: CGFloat = 1, context: CIContext = RenderPipeline.context) -> CGImage? {
        let image = render(source: source, settings: settings, targetSize: targetSize, draft: draft,
                           applyCrop: applyCrop, proxyScale: proxyScale, context: context)
        return makeCGImage(image, colorSpace: colorSpace, context: context)
    }

    /// Renders `image` NOW (not deferred to draw time, which would happen on the main thread).
    static func makeCGImage(_ image: CIImage, colorSpace: CGColorSpace = RenderPipeline.displayP3,
                            context: CIContext = RenderPipeline.context) -> CGImage? {
        let extent = image.extent.integral
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return nil }
        return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: colorSpace, deferred: false)
    }

    /// One-shot convenience for previews/export: decode `url`, apply `settings`, fit `maxPixelSize`
    /// (longest side; nil = full resolution).
    static func renderCGImage(url: URL, settings: EditSettings, maxPixelSize: Int?,
                              colorSpace: CGColorSpace = RenderPipeline.displayP3) -> CGImage? {
        guard let source = makeSource(url: url) else { return nil }
        let target = maxPixelSize.map { CGSize(width: $0, height: $0) }
        return renderCGImage(source: source, settings: settings, targetSize: target, colorSpace: colorSpace)
    }
}
