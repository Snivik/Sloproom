//
//  Histogram.swift
//  sloproom
//
//  RGB + luminance histogram of a rendered (display-encoded, 8-bit) image, computed on the CPU
//  from the CGImage the canvas shows (sampled, ~1 ms). Bins are normalized for display.
//

import Foundation
import CoreGraphics

nonisolated struct Histogram: Sendable, Equatable {
    static let binCount = 256
    /// 0...1 per bin (1 = tallest non-extreme bin; extreme bins may exceed 1 and are clamped by the view).
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    var luma: [Float]
    /// Fraction of sampled pixels with any channel at 0 / 255.
    var shadowClip: Float
    var highlightClip: Float

    /// Expects an 8-bit RGBA/RGBX image (what RenderPipeline.makeCGImage produces).
    init?(image: CGImage, maxSamples: Int = 250_000) {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return nil }
        let w = image.width, h = image.height, bpr = image.bytesPerRow
        guard w > 0, h > 0 else { return nil }
        // Byte positions of R, G, B: alpha first/last × big/little endian 32-bit words.
        let alphaFirst: Bool
        switch image.alphaInfo {
        case .first, .premultipliedFirst, .noneSkipFirst: alphaFirst = true
        default: alphaFirst = false
        }
        let little = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
        let (ri, gi, bi): (Int, Int, Int) = switch (alphaFirst, little) {
        case (false, false): (0, 1, 2)   // RGBA
        case (true, false): (1, 2, 3)    // ARGB
        case (true, true): (2, 1, 0)     // BGRA
        case (false, true): (3, 2, 1)    // ABGR
        }
        let stride = max(1, Int((Double(w * h) / Double(maxSamples)).squareRoot()))
        var r = [UInt32](repeating: 0, count: 256), g = r, b = r, l = r
        var lowClip = 0, highClip = 0, n = 0
        var y = 0
        while y < h {
            let row = base + y * bpr
            var x = 0
            while x < w {
                let p = row + x * 4
                let rv = Int(p[ri]), gv = Int(p[gi]), bv = Int(p[bi])
                r[rv] += 1; g[gv] += 1; b[bv] += 1
                l[(rv * 54 + gv * 183 + bv * 19) >> 8] += 1
                if rv == 0 || gv == 0 || bv == 0 { lowClip += 1 }
                if rv == 255 || gv == 255 || bv == 255 { highClip += 1 }
                n += 1
                x += stride
            }
            y += stride
        }
        let peak = max(1, [r, g, b].map { $0[1..<255].max() ?? 1 }.max() ?? 1)
        let norm = { (a: [UInt32]) in a.map { Float($0) / Float(peak) } }
        red = norm(r); green = norm(g); blue = norm(b); luma = norm(l)
        shadowClip = Float(lowClip) / Float(max(n, 1))
        highlightClip = Float(highClip) / Float(max(n, 1))
    }
}
