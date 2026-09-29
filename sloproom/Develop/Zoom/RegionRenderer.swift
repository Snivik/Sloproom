//
//  RegionRenderer.swift
//  sloproom
//
//  Zoomed rendering (engine, UI-free; harness: Tools/zoom_check.swift). Renders only a REGION of
//  the final (cropped) image at a given scale, e.g. the visible part of the canvas at 1:1.
//
//  - The pipeline graph is built at `scale` (≤ 1 = full resolution) and the output is cropped to
//    the region before rendering, so Core Image only evaluates the visible pixels. CIRAWFilter is
//    ROI-aware: a 2800×1800 1:1 region of a 60 MP DNG decodes in ~25 ms.
//  - Neighbourhood operations (highlights / shadows / clarity / dehaze / masks with them) build a
//    small blurred base from the WHOLE image, which forces a full-resolution demosaic on every
//    render (~150–300 ms). For those settings the stage-1 decode is materialized once (RGBAh) and
//    reused while panning / editing non-decode settings (~40 ms per region). The cache holds one
//    decode (≈ 375 MB for 60 MP at 1:1) and is keyed by source, scale, white balance and exposure.
//  - Thread-safe; call off the main thread. `purge()` when the photo closes.
//

import Foundation
import CoreGraphics
import CoreImage
import Metal

nonisolated final class RegionRenderer: @unchecked Sendable {
    /// The rendered region: `image` covers `normalizedRect` of the final image (top-left origin).
    struct Result: @unchecked Sendable {
        let image: CGImage
        /// Rect of the output image the tile covers, normalized 0…1 (top-left origin).
        let normalizedRect: CGRect
        /// Full output size in pixels at this scale.
        let outputSize: CGSize
        let milliseconds: Double
        let usedCachedDecode: Bool
    }

    private struct DecodeKey: Equatable {
        let source: ObjectIdentifier
        let scale: CGFloat
        let whiteBalance: WhiteBalance
        let exposure: Double
    }

    private let lock = NSLock()
    private var cachedKey: DecodeKey?
    private var cachedDecode: CIImage?

    /// Non-caching Metal context for region renders (keeps the interactive context's cache for
    /// the fit render).
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .cacheIntermediates: false,
            .name: "Sloproom.Region",
        ]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    init() {}

    /// Drops the cached decode (photo closed / switched).
    func purge() {
        lock.lock(); cachedKey = nil; cachedDecode = nil; lock.unlock()
    }

    /// Output size (pixels) of the final image at `scale`.
    static func outputSize(source: RenderSource, settings: EditSettings, applyCrop: Bool, scale: CGFloat) -> CGSize {
        let math = GeometryMath(sourceSize: source.orientedSize, geometry: settings.geometry)
        let out = applyCrop ? math.croppedSize : math.frameSize
        return CGSize(width: max(1, (out.width * scale).rounded()), height: max(1, (out.height * scale).rounded()))
    }

    /// Renders `region` (normalized to the final image, top-left origin; clamped to it) at
    /// `scale` (clamped to ≤ 1). Returns nil for an empty region.
    func render(source: RenderSource, settings: EditSettings, applyCrop: Bool, scale requested: CGFloat,
                region: CGRect, colorSpace: CGColorSpace = RenderPipeline.displayP3) -> Result? {
        let start = Date()
        let scale = min(1, max(requested, 0.01))
        let ctx = Self.context
        var decoded: CIImage
        var usedCache = false
        if settings.usesLocalOperations {
            let key = DecodeKey(source: ObjectIdentifier(source), scale: scale, whiteBalance: settings.whiteBalance,
                                exposure: settings.tone.exposure)
            lock.lock()
            let hit = cachedKey == key ? cachedDecode : nil
            lock.unlock()
            if let hit {
                decoded = hit
                usedCache = true
            } else {
                // Free the old decode first (they are big).
                purge()
                let raw = RawDecodeStage.apply(source: source, settings: settings, scale: scale, draft: false)
                decoded = AdjustmentOps.materialize(raw, context: ctx, maxPixels: 80_000_000)
                lock.lock(); cachedKey = key; cachedDecode = decoded; lock.unlock()
            }
        } else {
            decoded = RawDecodeStage.apply(source: source, settings: settings, scale: scale, draft: false)
        }
        let rc = RenderContext(fullSize: source.orientedSize, imageSize: decoded.extent.size, draft: false,
                               applyCrop: applyCrop, requestedScale: scale, seed: source.seed, ciContext: ctx)
        let full = RenderPipeline.applyStages(decoded, settings: settings, context: rc)
        let extent = full.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return nil }
        let n = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !n.isNull, n.width > 0, n.height > 0 else { return nil }
        // Whole output pixels, top-left origin.
        let px = CGRect(x: n.minX * extent.width, y: n.minY * extent.height,
                        width: n.width * extent.width, height: n.height * extent.height)
            .integral.intersection(CGRect(origin: .zero, size: extent.size))
        guard px.width >= 1, px.height >= 1 else { return nil }
        let ci = CGRect(x: extent.minX + px.minX, y: extent.maxY - px.maxY, width: px.width, height: px.height)
        guard let cg = ctx.createCGImage(full.cropped(to: ci), from: ci, format: .RGBA8, colorSpace: colorSpace, deferred: false)
        else { return nil }
        let normalized = CGRect(x: px.minX / extent.width, y: px.minY / extent.height,
                                width: px.width / extent.width, height: px.height / extent.height)
        return Result(image: cg, normalizedRect: normalized, outputSize: extent.size,
                      milliseconds: Date().timeIntervalSince(start) * 1000, usedCachedDecode: usedCache)
    }
}
