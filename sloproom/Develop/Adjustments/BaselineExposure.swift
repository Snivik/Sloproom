//
//  BaselineExposure.swift
//  sloproom
//
//  Camera-matched baseline brightness for RAW files.
//
//  CIRAWFilter's default rendering (the same engine as Preview/Photos/sips) is often much darker
//  than the camera's own JPEG: e.g. on the Leica SL2 samples it is 0.45–0.8 EV darker in the
//  midtones on normal scenes and up to ~2 EV on low-key scenes (the camera applies adaptive
//  tone). Library thumbnails of unedited photos show the embedded JPEG, so without this the
//  image visibly "drops" when you open it in Develop or make the first edit.
//
//  At source creation we compare luminance percentiles of a tiny default decode against the
//  embedded preview and derive an exposure offset (clamped, and limited so bright areas don't
//  end up brighter than in the camera JPEG). It is applied through `CIRAWFilter.baselineExposure`
//  (scene-linear, before the base curve), so the Exposure slider still starts at 0.
//  Deterministic per file and cached per path/size/date.
//
//  The same tiny (extended-range) decode also yields the raw clip level (`Analysis.highlightClip`)
//  RawDecodeStage uses to neutralize partially clipped highlights.
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO

nonisolated enum BaselineExposure {
    static let range: ClosedRange<Double> = -1...1.5

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Analysis] = [:]

    struct Analysis: Sendable {
        /// EV to add to the filter's default baseline exposure (0 if there is no embedded preview).
        var offset = 0.0
        /// Linear level (max channel, working space, exposure 0, WITH the offset) where the raw data
        /// clips in the extended-range decode (RawDecodeStage); 0 = nothing clips / unknown.
        /// CIRAWFilter makes fully clipped pixels neutral, but partially clipped ones around them come
        /// out with a color cast that only shows once Highlights / Whites / Exposure− pull them into
        /// view. Above white the decode is ~linear in exposure: at exposure e the level is ≈ this × 2^e.
        var highlightClip = 0.0
    }

    /// EV to add to the filter's default baseline exposure (0 if there is no embedded preview).
    static func offset(url: URL, raw: CIRAWFilter) -> Double { analyze(url: url, raw: raw).offset }

    /// Baseline offset + raw clip level from ONE tiny decode (cached per path/size/date).
    static func analyze(url: URL, raw: CIRAWFilter) -> Analysis {
        let key = cacheKey(url)
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let value = estimate(url: url, raw: raw)
        lock.lock(); cache[key] = value; lock.unlock()
        return value
    }

    private static func cacheKey(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(url.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    private static func estimate(url: URL, raw: CIRAWFilter) -> Analysis {
        let native = raw.nativeSize
        guard native.width > 0 else { return Analysis() }
        // Tiny default decode, extended range (caller hasn't touched the filter yet; restore what we change).
        let old = (raw.scaleFactor, raw.extendedDynamicRangeAmount)
        raw.scaleFactor = Float(320 / max(native.width, native.height))
        raw.extendedDynamicRangeAmount = RawDecodeStage.extendedDynamicRange
        let decoded = raw.outputImage
        (raw.scaleFactor, raw.extendedDynamicRangeAmount) = old
        guard let decoded, let pixels = linearPixels(decoded) else { return Analysis() }
        let maxChannel = Double(pixels.maxChannel)
        let offset = estimateOffset(url: url, decodedLuma: pixels.luma) ?? 0
        // Only meaningful when something actually clips above white.
        let clip = maxChannel.isFinite && maxChannel > 1.2 ? maxChannel * pow(2, offset) : 0
        return Analysis(offset: offset, highlightClip: clip)
    }

    /// Camera-JPEG-matched offset from the decode's luminance (clamped at 1 = the SDR rendering).
    private static func estimateOffset(url: URL, decodedLuma: [Float]) -> Double? {
        guard let preview = embeddedPreview(url: url, maxPixelSize: 320),
              let pb = linearPixels(CIImage(cgImage: preview)) else { return nil }
        let a = decodedLuma.map { min($0, 1) }.sorted(), b = pb.luma.sorted()
        guard a.count > 100, b.count > 100 else { return nil }
        func ev(_ p: Double) -> Double {
            let x = a[Int(p * Double(a.count - 1))], y = b[Int(p * Double(b.count - 1))]
            return log2(Double(max(y, 1e-4)) / Double(max(x, 1e-4)))
        }
        let mid = (ev(0.5) + ev(0.75)) / 2
        // Don't push highlights noticeably past the camera's rendering.
        let guarded = min(mid, ev(0.9) + 0.25)
        guard guarded.isFinite else { return nil }
        return guarded.clamped(to: range)
    }

    /// The embedded JPEG only (never a full RAW decode), oriented.
    private static func embeddedPreview(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              max(image.width, image.height) >= 160 else { return nil }
        return image
    }

    /// Linear luminance of every pixel (image scaled to ≤ 256 px) and the largest channel value.
    private static func linearPixels(_ image: CIImage) -> (luma: [Float], maxChannel: Float)? {
        let e = image.extent
        guard !e.isInfinite, e.width > 0, e.height > 0 else { return nil }
        let s = min(1, 256 / max(e.width, e.height))
        let scaled = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).scaledBy(x: s, y: s))
        let w = Int(e.width * s), h = Int(e.height * s)
        guard w > 0, h > 0 else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        RenderPipeline.context.render(scaled, toBitmap: &px, rowBytes: w * 16,
                                      bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf,
                                      colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        var l = [Float](repeating: 0, count: w * h)
        var mx: Float = 0
        for i in 0..<(w * h) {
            l[i] = 0.2126 * px[i * 4] + 0.7152 * px[i * 4 + 1] + 0.0722 * px[i * 4 + 2]
            mx = max(mx, px[i * 4], px[i * 4 + 1], px[i * 4 + 2])
        }
        return (l, mx)
    }
}
