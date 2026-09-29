//
//  crop_check.swift
//  Headless checks for crop & rotate: CropMath constraint math, Geometry transforms,
//  GeometryStage vs GeometryMath (synthetic marker image), and real DNG renders.
//
//  Build & run:
//    Tools/harness.sh /private/tmp/claude-501/out-crop/crop_check Tools/crop_check.swift sloproom/Develop/Crop/CropMath.swift \
//        sloproom/Develop/Crop/Catalog+CropPresets.swift
//    /private/tmp/claude-501/out-crop/crop_check [photo-dir] [out-dir]
//
//  Reads sample photos READ-ONLY; writes only into out-dir.
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@main
struct CropCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS" : "  FAIL", what)
        if !ok { failures += 1 }
    }

    static func main() async throws {
        let args = CommandLine.arguments
        let photoDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/Users/snivik/Pictures/2026/2026-08-01")
        let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "/private/tmp/claude-501/out-crop")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        mathChecks()
        transformChecks()
        try syntheticRenderChecks(outDir: outDir)
        try catalogChecks(outDir: outDir)
        dngChecks(photoDir: photoDir, outDir: outDir)

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - CropMath

    static func mathChecks() {
        print("CropMath")
        let frame = CGSize(width: 6000, height: 4000)
        let m0 = CropMath(frameSize: frame, angle: 0)
        let full = CGRect(origin: .zero, size: frame)
        check(m0.contains(full), "full frame fits at 0°")
        check(!m0.contains(full.insetBy(dx: -1, dy: 0)), "larger than frame does not fit")
        check(m0.normRect(m0.pixelRect(.full)) == .full, "norm <-> pixel round trip keeps .full")

        let m8 = CropMath(frameSize: frame, angle: 8)
        check(!m8.contains(full), "full frame does not fit at 8°")
        let max8 = m8.maxRect(aspect: 1.5)
        check(m8.contains(max8), "max 3:2 rect fits at 8°")
        check(!m8.contains(max8.insetBy(dx: -max8.width * 0.001, dy: -max8.height * 0.001)), "max 3:2 rect is maximal")
        check(abs(max8.width / max8.height - 1.5) < 1e-9, "max rect keeps aspect")
        check(abs(max8.midX - 3000) < 1e-6 && abs(max8.midY - 2000) < 1e-6, "max rect centered")
        // Analytic value for a W×H rect at angle a, aspect W/H: s = 1 / (cos a + (H/W... ) sin a)).
        let a = 8 * Double.pi / 180
        let expectedH = 4000 / (cos(a) + 1.5 * sin(a))
        check(abs(Double(max8.height) - expectedH) < 0.01, String(format: "max rect height %.2f == analytic %.2f", max8.height, expectedH))

        let fitted = m8.fitted(full)
        check(m8.contains(fitted), "fitted(full) fits at 8°")
        check(abs(fitted.width / fitted.height - 1.5) < 1e-9, "fitted keeps aspect")

        // Random stress: fitted / moved / resized always stay inside.
        var rng = SplitMix(seed: 42)
        var okFit = true, okMove = true, okResize = true, okLocked = true
        for _ in 0..<2000 {
            let angle = rng.next(in: -45...45)
            let m = CropMath(frameSize: CGSize(width: rng.next(in: 500...8000), height: rng.next(in: 500...8000)), angle: angle)
            let w = rng.next(in: 10...Double(m.frameSize.width)), h = rng.next(in: 10...Double(m.frameSize.height))
            let r = CGRect(x: rng.next(in: 0...Double(m.frameSize.width) - w), y: rng.next(in: 0...Double(m.frameSize.height) - h), width: w, height: h)
            let f = m.fitted(r)
            if !m.contains(f) || f.width <= 0 { okFit = false }
            let moved = m.moved(f, by: CGVector(dx: rng.next(in: -5000...5000), dy: rng.next(in: -5000...5000)))
            if !m.contains(moved) || abs(moved.width - f.width) > 1e-6 { okMove = false }
            let handles: [CropHandle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
            let handle = handles[Int(rng.next(in: 0...7.999))]
            let p = CGPoint(x: rng.next(in: -3000...10000), y: rng.next(in: -3000...10000))
            let free = m.resized(f, handle: handle, to: p, lockAspect: false, minSize: 5)
            if !m.contains(free) { okResize = false }
            let locked = m.resized(f, handle: handle, to: p, lockAspect: true, minSize: 5)
            if !m.contains(locked) || abs(locked.width / locked.height - f.width / f.height) > 1e-6 * max(1, f.width / f.height) { okLocked = false }
        }
        check(okFit, "fitted() always inside (2000 random cases)")
        check(okMove, "moved() always inside, size kept")
        check(okResize, "free resize always inside")
        check(okLocked, "locked resize always inside and keeps aspect")

        // Resize semantics at 0°.
        let start = CGRect(x: 1000, y: 1000, width: 3000, height: 2000)
        let r1 = m0.resized(start, handle: .bottomRight, to: CGPoint(x: 5000, y: 3500), lockAspect: false, minSize: 10)
        check(r1 == CGRect(x: 1000, y: 1000, width: 4000, height: 2500), "free corner resize follows pointer, anchor fixed")
        let r2 = m0.resized(start, handle: .bottomRight, to: CGPoint(x: 9000, y: 3500), lockAspect: false, minSize: 10)
        check(approx(r2, CGRect(x: 1000, y: 1000, width: 5000, height: 2500)), "free corner resize clamps x, keeps sliding in y")
        let r3 = m0.resized(start, handle: .right, to: CGPoint(x: 9000, y: 0), lockAspect: true, minSize: 10)
        check(abs(r3.width / r3.height - 1.5) < 1e-9 && abs(r3.midY - start.midY) < 1e-6 && m0.contains(r3), "locked edge resize scales about opposite edge midpoint")
        let r4 = m0.resized(start, handle: .topLeft, to: CGPoint(x: 3990, y: 2990), lockAspect: false, minSize: 50)
        check(r4.width >= 50 - 1e-9 && r4.height >= 50 - 1e-9 && r4.maxX == 4000 && r4.maxY == 3000, "min size respected, anchor fixed")
        let mv = m0.moved(start, by: CGVector(dx: 5000, dy: -300))
        check(approx(mv, CGRect(x: 3000, y: 700, width: 3000, height: 2000)), "move slides along the edge")
    }

    // MARK: - Geometry transforms

    static func transformChecks() {
        print("Geometry transforms")
        let size = CGSize(width: 6000, height: 4000)
        var rng = SplitMix(seed: 7)
        var okRot = true, okFlip = true, okRound = true
        for _ in 0..<500 {
            var g = Geometry()
            g.quarterTurns = Int(rng.next(in: 0...3.999))
            g.flipHorizontal = rng.next(in: 0...1) > 0.5
            g.straightenAngle = rng.next(in: -45...45)
            let cw = rng.next(in: 0.1...1), ch = rng.next(in: 0.1...1)
            g.crop = NormRect(x: rng.next(in: 0...(1 - cw)), y: rng.next(in: 0...(1 - ch)), width: cw, height: ch)
            let before = GeometryMath(sourceSize: size, geometry: g)
            // Each displayed (cropped-normalized) point must show the same source point after the
            // visual transform, at the rotated / mirrored position.
            let samples = [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.5, y: 0.5)]
            for cw in [true, false] {
                let after = GeometryMath(sourceSize: size, geometry: g.rotatedQuarter(clockwise: cw))
                for p in samples {
                    let src = before.sourceNormalized(fromFrame: before.frameNormalized(fromCropped: p))
                    let q = cw ? CGPoint(x: 1 - p.y, y: p.x) : CGPoint(x: p.y, y: 1 - p.x)
                    let src2 = after.sourceNormalized(fromFrame: after.frameNormalized(fromCropped: q))
                    if abs(src.x - src2.x) > 1e-9 || abs(src.y - src2.y) > 1e-9 { okRot = false }
                }
            }
            let flipped = GeometryMath(sourceSize: size, geometry: g.flippedHorizontally())
            for p in samples {
                let src = before.sourceNormalized(fromFrame: before.frameNormalized(fromCropped: p))
                let src2 = flipped.sourceNormalized(fromFrame: flipped.frameNormalized(fromCropped: CGPoint(x: 1 - p.x, y: p.y)))
                if abs(src.x - src2.x) > 1e-9 || abs(src.y - src2.y) > 1e-9 { okFlip = false }
            }
            var four = g
            for _ in 0..<4 { four = four.rotatedQuarter(clockwise: true) }
            if four.normalizedQuarterTurns != g.normalizedQuarterTurns || abs(four.crop.x - g.crop.x) > 1e-12 || abs(four.crop.width - g.crop.width) > 1e-12 { okRound = false }
        }
        check(okRot, "rotate left/right turns the displayed crop (500 random geometries, flip on/off)")
        check(okFlip, "flip mirrors the displayed crop")
        check(okRound, "four clockwise turns = identity")
        var g = Geometry()
        g = g.rotatedQuarter(clockwise: true)
        check(g.quarterTurns == 1 && g.crop == .full, "turn keeps a full crop exactly full")
        check(Geometry().flippedHorizontally().rotatedQuarter(clockwise: false).flippedHorizontally().rotatedQuarter(clockwise: false).isDefault, "flip/turn sequence returns to default")
    }

    // MARK: - Synthetic render: GeometryStage == GeometryMath

    static func syntheticRenderChecks(outDir: URL) throws {
        print("GeometryStage vs GeometryMath (synthetic marker image)")
        let W = 900, H = 600
        let marker = NormPoint(x: 0.3, y: 0.2)
        let url = outDir.appendingPathComponent("synthetic_marker.png")
        try writeMarkerPNG(width: W, height: H, marker: marker, to: url)
        guard let source = RenderPipeline.makeSource(url: url) else { check(false, "synthetic source"); return }

        var cases: [(String, Geometry)] = []
        var g = Geometry(); cases.append(("identity", g))
        g = Geometry(); g.quarterTurns = 1; cases.append(("turn1", g))
        g = Geometry(); g.quarterTurns = 2; cases.append(("turn2", g))
        g = Geometry(); g.quarterTurns = 3; cases.append(("turn3", g))
        g = Geometry(); g.flipHorizontal = true; cases.append(("flip", g))
        g = Geometry(); g.quarterTurns = 1; g.flipHorizontal = true; cases.append(("turn1+flip", g))
        g = Geometry(); g.straightenAngle = 8; cases.append(("straighten8", g))
        g = Geometry(); g.straightenAngle = -20; g.quarterTurns = 3; g.flipHorizontal = true; cases.append(("turn3+flip+straighten-20", g))
        g = Geometry(); g.crop = NormRect(x: 0.1, y: 0.05, width: 0.5, height: 0.6); cases.append(("crop", g))
        g = Geometry(); g.quarterTurns = 1; g.straightenAngle = 12
        g.crop = CropMath(frameSize: CGSize(width: H, height: W), angle: 12).normRect(CropMath(frameSize: CGSize(width: H, height: W), angle: 12).maxRect(aspect: 0.8, near: CGPoint(x: 250, y: 300)))
        cases.append(("turn1+straighten12+crop", g))

        for (name, geo) in cases {
            var s = EditSettings(); s.geometry = geo
            for applyCrop in [true, false] {
                guard let cg = RenderPipeline.renderCGImage(source: source, settings: s, applyCrop: applyCrop) else { check(false, "\(name) rendered"); continue }
                let math = GeometryMath(sourceSize: CGSize(width: W, height: H), geometry: geo)
                let frameN = math.frameNormalized(fromSource: marker)
                let pos = applyCrop ? math.croppedNormalized(fromFrame: frameN) : frameN
                let expected = CGPoint(x: pos.x * CGFloat(cg.width), y: pos.y * CGFloat(cg.height))
                let found = brightCentroid(cg)
                let size = applyCrop ? math.croppedSize : math.frameSize
                let dimsOK = abs(CGFloat(cg.width) - size.width) <= 1 && abs(CGFloat(cg.height) - size.height) <= 1
                let err = found.map { hypot($0.x - expected.x, $0.y - expected.y) } ?? .infinity
                check(dimsOK && err < 1.0, String(format: "%@%@: %dx%d, marker at (%.1f, %.1f), expected (%.1f, %.1f)",
                                                  name, applyCrop ? "" : " (uncropped)", cg.width, cg.height,
                                                  found?.x ?? -1, found?.y ?? -1, expected.x, expected.y))
            }
        }
        // Pure turns / flips / unrotated crops must be exact pixel copies.
        var s = EditSettings(); s.geometry.quarterTurns = 1; s.geometry.flipHorizontal = true
        s.geometry.crop = NormRect(x: 0.25, y: 0.1, width: 0.5, height: 0.5)
        if let cg = RenderPipeline.renderCGImage(source: source, settings: s) {
            let values = Set(pixels(cg).enumerated().filter { $0.offset % 4 == 0 }.map(\.element))
            check(values.isSubset(of: [0, 255]), "turn+flip+crop is resampling-free (only 0/255 in a 0/255 image)")
        }
    }

    // MARK: - Catalog presets

    static func catalogChecks(outDir: URL) throws {
        print("Crop presets in catalog")
        let dir = outDir.appendingPathComponent("catalog-\(Int(Date().timeIntervalSince1970))")
        let catalog = try Catalog.open(at: dir)
        try catalog.ensureDefaultCropPresets()
        try catalog.ensureDefaultCropPresets()
        let names = try catalog.allCropPresets().map(\.name)
        check(names == ["Instagram Story", "Instagram Post Square", "Vertical 4:5", "Horizontal 3:2", "Horizontal 16:9"], "defaults seeded once: \(names)")
        let id = try catalog.createCropPreset(name: "Cinema", ratioW: 2.39, ratioH: 1)
        var presets = try catalog.allCropPresets()
        try catalog.reorderCropPresets(ids: [id] + presets.map(\.id).filter { $0 != id })
        presets = try catalog.allCropPresets()
        check(presets.first?.name == "Cinema" && presets.map(\.sortOrder) == Array(0..<presets.count), "reorder puts Cinema first with dense sort order")
        try catalog.deleteCropPreset(id: id)
        let reopened = try Catalog.open(at: dir)
        try reopened.ensureDefaultCropPresets()
        check(try reopened.allCropPresets().count == 5, "delete persists; defaults not re-seeded on reopen")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - DNG renders

    static func dngChecks(photoDir: URL, outDir: URL) {
        print("DNG renders (~1200 px)")
        guard let url = (try? FileManager.default.contentsOfDirectory(at: photoDir, includingPropertiesForKeys: nil))?
            .filter({ RenderPipeline.isRAW(url: $0) }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first,
              let source = RenderPipeline.makeSource(url: url) else { check(false, "found a DNG in \(photoDir.path)"); return }
        print("  \(url.lastPathComponent) oriented \(Int(source.orientedSize.width))x\(Int(source.orientedSize.height))")
        let target = CGSize(width: 1200, height: 1200)
        let full = source.orientedSize

        func render(_ name: String, _ geo: Geometry, ratio: Double?, applyCrop: Bool = true) {
            var s = EditSettings(); s.geometry = geo
            let t = Date()
            guard let cg = RenderPipeline.renderCGImage(source: source, settings: s, targetSize: target, applyCrop: applyCrop) else {
                check(false, "\(name) rendered"); return
            }
            let ms = Date().timeIntervalSince(t) * 1000
            writeJPEG(cg, to: outDir.appendingPathComponent("dng_\(name).jpg"))
            let math = GeometryMath(sourceSize: full, geometry: geo)
            let want = applyCrop ? math.croppedSize : math.frameSize
            let wantRatio = ratio ?? Double(want.width / want.height)
            // ±1 px: the shorter side implied by the longer side and the ratio.
            let ratioOK = cg.width >= cg.height
                ? abs(Double(cg.height) - Double(cg.width) / wantRatio) <= 1
                : abs(Double(cg.width) - Double(cg.height) * wantRatio) <= 1
            let fitOK = max(cg.width, cg.height) <= 1200 && max(cg.width, cg.height) >= 1199
            let opaque = applyCrop ? cornersOpaque(cg) : true
            check(ratioOK && fitOK && opaque, String(format: "%@: %dx%d (want ratio %.4f, got %.4f)%@ %.0f ms", name, cg.width, cg.height,
                                                      wantRatio, Double(cg.width) / Double(cg.height), opaque ? "" : " TRANSPARENT CORNER", ms))
        }

        var g = Geometry()
        g.quarterTurns = 1
        render("turn1", g, ratio: Double(full.height / full.width))
        g = Geometry(); g.flipHorizontal = true
        render("flip", g, ratio: Double(full.width / full.height))

        g = Geometry(); g.straightenAngle = 8
        let m8 = CropMath(sourceSize: full, geometry: g)
        g.crop = m8.normRect(m8.fitted(m8.pixelRect(.full)))
        render("straighten8_maxcrop", g, ratio: Double(full.width / full.height))
        render("straighten8_uncropped", g, ratio: nil, applyCrop: false)

        let presets: [(String, Double, Double)] = [("story_9x16", 9, 16), ("square_1x1", 1, 1), ("vertical_4x5", 4, 5), ("horizontal_3x2", 3, 2), ("16x9", 16, 9)]
        for (name, w, h) in presets {
            var p = Geometry()
            let m = CropMath(sourceSize: full, geometry: p)
            p.crop = m.normRect(m.maxRect(aspect: w / h))
            p.aspectLocked = true
            render("preset_\(name)", p, ratio: w / h)
            // Same preset on a straightened, turned photo.
            p = Geometry(); p.quarterTurns = 3; p.straightenAngle = -5
            let m2 = CropMath(sourceSize: full, geometry: p)
            p.crop = m2.normRect(m2.maxRect(aspect: w / h, near: CGPoint(x: m2.frameSize.width * 0.4, y: m2.frameSize.height * 0.6)))
            render("preset_\(name)_turn3_straighten-5", p, ratio: w / h)
        }

        var rng = SplitMix(seed: 1234)
        for i in 0..<3 {
            var r = Geometry()
            let cw = rng.next(in: 0.2...0.9), ch = rng.next(in: 0.2...0.9)
            r.crop = NormRect(x: rng.next(in: 0...(1 - cw)), y: rng.next(in: 0...(1 - ch)), width: cw, height: ch)
            let ratio = Double(full.width) * cw / (Double(full.height) * ch)
            render("random\(i)", r, ratio: ratio)
        }
    }

    // MARK: - Helpers

    static func approx(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-4 && abs(a.minY - b.minY) < 1e-4 && abs(a.width - b.width) < 1e-4 && abs(a.height - b.height) < 1e-4
    }

    static func writeMarkerPNG(width: Int, height: Int, marker: NormPoint, to url: URL) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        // CG is bottom-left: the marker's top-left normalized position -> flip y. 10x10 px square.
        let cx = marker.x * Double(width), cy = (1 - marker.y) * Double(height)
        ctx.fill(CGRect(x: cx - 5, y: cy - 5, width: 10, height: 10))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    /// Centroid (top-left pixel coordinates, pixel edges) of bright pixels, weighted.
    static func brightCentroid(_ image: CGImage) -> CGPoint? {
        let px = pixels(image), w = image.width, h = image.height
        var sx = 0.0, sy = 0.0, sw = 0.0
        for y in 0..<h { for x in 0..<w {
            let v = Double(px[(y * w + x) * 4])
            if v > 40 { let wt = v; sx += (Double(x) + 0.5) * wt; sy += (Double(y) + 0.5) * wt; sw += wt }
        } }
        return sw > 0 ? CGPoint(x: sx / sw, y: sy / sw) : nil
    }

    static func cornersOpaque(_ image: CGImage) -> Bool {
        let px = pixels(image), w = image.width, h = image.height
        return [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)].allSatisfy { px[($0.1 * w + $0.0) * 4 + 3] == 255 }
    }

    static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}

/// Deterministic RNG for repeatable random tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUInt() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(nextUInt() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
}
