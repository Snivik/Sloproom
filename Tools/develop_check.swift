//
//  develop_check.swift
//  Develop engine harness: renders one image per control at a strong value, checks basic
//  invariants, and prints a timing table.
//
//  Tools/harness.sh /private/tmp/claude-501/out-develop/develop_check Tools/develop_check.swift
//  /private/tmp/claude-501/out-develop/develop_check [dng] [out-dir] [only-name-substring]
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@main
struct DevelopCheck {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
        if !ok { failures += 1 }
    }

    static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// Mean (display-encoded P3) RGB of a CGImage.
    static func mean(_ cg: CGImage) -> (Double, Double, Double) {
        let img = CIImage(cgImage: cg)
        let avg = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: img.extent)])
        var px = [Float](repeating: 0, count: 4)
        RenderPipeline.context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                      format: .RGBAf, colorSpace: RenderPipeline.displayP3)
        return (Double(px[0]), Double(px[1]), Double(px[2]))
    }

    static func ms(_ f: () -> Void) -> Double {
        let t = Date(); f(); return Date().timeIntervalSince(t) * 1000
    }

    static func main() async throws {
        let args = CommandLine.arguments
        let dng = URL(fileURLWithPath: args.count > 1 ? args[1] : "/Users/snivik/Pictures/2026/2026-08-01/L1090229.DNG")
        let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "/private/tmp/claude-501/out-develop")
        let only = args.count > 3 ? args[3] : ""
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var t0 = Date()
        guard let source = RenderPipeline.makeSource(url: dng) else { print("cannot open \(dng.path)"); exit(1) }
        print(String(format: "makeSource %.0f ms, baseline offset %+.2f EV, as shot %.0f K / %+.1f",
                     Date().timeIntervalSince(t0) * 1000, source.baselineOffset,
                     source.asShotTemperature ?? 0, source.asShotTint ?? 0))

        func edit(_ f: (inout EditSettings) -> Void) -> EditSettings { var s = EditSettings(); f(&s); return s }
        let cases: [(String, EditSettings)] = [
            ("00_default", EditSettings()),
            ("01_exposure+1", edit { $0.tone.exposure = 1 }),
            ("02_contrast+50", edit { $0.tone.contrast = 50 }),
            ("03_contrast-50", edit { $0.tone.contrast = -50 }),
            ("04_highlights-100", edit { $0.tone.highlights = -100 }),
            ("05_shadows+100", edit { $0.tone.shadows = 100 }),
            ("06_whites+60", edit { $0.tone.whites = 60 }),
            ("07_blacks-60", edit { $0.tone.blacks = -60 }),
            ("08_whites-60_blacks+60", edit { $0.tone.whites = -60; $0.tone.blacks = 60 }),
            ("09_clarity+60", edit { $0.presence.clarity = 60 }),
            ("10_texture+60", edit { $0.presence.texture = 60 }),
            ("11_dehaze+50", edit { $0.presence.dehaze = 50 }),
            ("12_vibrance+60", edit { $0.presence.vibrance = 60 }),
            ("13_saturation-100", edit { $0.presence.saturation = -100 }),
            ("14_mixer_blueSat-100_orangeHue+40", edit {
                $0.colorMixer[.blue] = HSLAdjustment(saturation: -100)
                $0.colorMixer[.orange] = HSLAdjustment(hue: 40)
            }),
            ("15_vignette-50", edit { $0.effects.vignetteAmount = -50 }),
            ("16_grain50", edit { $0.effects.grainAmount = 50 }),
            ("17_temp3500", edit { $0.whiteBalance.mode = .custom; $0.whiteBalance.temperature = 3500; $0.whiteBalance.tint = source.asShotTint ?? 0 }),
            ("18_temp9000", edit { $0.whiteBalance.mode = .custom; $0.whiteBalance.temperature = 9000; $0.whiteBalance.tint = source.asShotTint ?? 0 }),
            ("19_tint+60", edit { $0.whiteBalance.mode = .custom; $0.whiteBalance.temperature = source.asShotTemperature ?? 5500; $0.whiteBalance.tint = 60 }),
            ("20_mixer_redLum-80_greenHue-60", edit {
                $0.colorMixer[.red] = HSLAdjustment(luminance: -80)
                $0.colorMixer[.yellow] = HSLAdjustment(saturation: 80)
                $0.colorMixer[.green] = HSLAdjustment(hue: -60)
            }),
            ("21_dehaze-50", edit { $0.presence.dehaze = -50 }),
            ("22_clarity-60", edit { $0.presence.clarity = -60 }),
            ("23_vignette+50_round-100", edit { $0.effects.vignetteAmount = 50; $0.effects.vignetteRoundness = -100; $0.effects.vignetteFeather = 20 }),
            ("24_combo", edit {
                $0.tone.exposure = 0.3; $0.tone.highlights = -60; $0.tone.shadows = 50; $0.tone.contrast = 20
                $0.tone.whites = 15; $0.tone.blacks = -10
                $0.presence.clarity = 20; $0.presence.vibrance = 25; $0.presence.texture = 15
                $0.effects.vignetteAmount = -20
            }),
            ("25_local_mask_reuse", EditSettings()),
        ]

        let target = CGSize(width: 1400, height: 1400)
        var means: [String: (Double, Double, Double)] = [:]
        print("Rendering at 1400 px to \(outDir.path)")
        for (name, settings) in cases where only.isEmpty || name.contains(only) {
            var image: CIImage
            if name == "25_local_mask_reuse" {
                // LocalAdjustmentRenderer on the whole image (no mask) — engineer F's entry point.
                let base = RenderPipeline.render(source: source, settings: EditSettings(), targetSize: target)
                var adj = LocalAdjustments()
                adj.exposure = 0.5; adj.shadows = 60; adj.temperature = 40; adj.clarity = 40; adj.saturation = 30
                let ctx = RenderContext(fullSize: source.orientedSize, imageSize: base.extent.size, draft: false, applyCrop: true, seed: source.seed)
                image = LocalAdjustmentRenderer.apply(base, adj, context: ctx)
                check(image.extent == base.extent, "local adjustments keep extent")
            } else {
                image = RenderPipeline.render(source: source, settings: settings, targetSize: target)
            }
            guard let cg = RenderPipeline.makeCGImage(image) else { check(false, "render \(name)"); continue }
            writeJPEG(cg, to: outDir.appendingPathComponent("dev_\(name).jpg"))
            let m = mean(cg)
            means[name] = m
            print(String(format: "  %-38@ %dx%d  mean %.3f %.3f %.3f", name as NSString, cg.width, cg.height, m.0, m.1, m.2))
        }

        if only.isEmpty, let d = means["00_default"] {
            let lum = { (m: (Double, Double, Double)) in 0.2126 * m.0 + 0.7152 * m.1 + 0.0722 * m.2 }
            check(lum(means["01_exposure+1"]!) > lum(d) + 0.05, "exposure +1 brighter")
            check(lum(means["05_shadows+100"]!) > lum(d), "shadows +100 brighter")
            check(lum(means["04_highlights-100"]!) < lum(d), "highlights -100 darker")
            check(lum(means["15_vignette-50"]!) < lum(d), "vignette -50 darker")
            let w = means["18_temp9000"]!, c = means["17_temp3500"]!
            check(w.0 / w.2 > c.0 / c.2, "9000 K warmer than 3500 K")
            let tint = means["19_tint+60"]!
            check(tint.1 < (tint.0 + tint.2) / 2 + 0.005 && tint.1 < d.1 + 0.01, "tint +60 is magenta (less green)")
            let g = means["13_saturation-100"]!
            check(abs(g.0 - g.1) < 0.01 && abs(g.1 - g.2) < 0.01, "saturation -100 is neutral")
            // Grain determinism.
            let s = cases.first { $0.0 == "16_grain50" }!.1
            let a = RenderPipeline.renderCGImage(source: source, settings: s, targetSize: CGSize(width: 300, height: 300))!
            let b = RenderPipeline.renderCGImage(source: source, settings: s, targetSize: CGSize(width: 300, height: 300))!
            check(a.dataProvider?.data == b.dataProvider?.data, "grain is deterministic")
        }

        // MARK: Scale consistency (proxy / thumbnail / export should look alike)
        if only.isEmpty {
            let combo = cases.first { $0.0 == "24_combo" }!.1
            func diff(_ a: CIImage, _ b: CIImage) -> Double {
                // Mean absolute difference (display-encoded) after bringing both to a's size.
                let bs = b.transformed(by: CGAffineTransform(scaleX: a.extent.width / b.extent.width, y: a.extent.height / b.extent.height))
                let d = a.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: bs])
                let avg = d.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: a.extent)])
                var px = [Float](repeating: 0, count: 4)
                RenderPipeline.context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: RenderPipeline.sRGB)
                return Double(px[0] + px[1] + px[2]) / 3
            }
            func small(_ i: CIImage) -> CIImage {
                i.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 700 / max(i.extent.width, i.extent.height), kCIInputAspectRatioKey: 1])
            }
            func energy(_ i: CIImage) -> Double {
                // Mean |image - blur(image)|: amount of fine detail / grain.
                let blurred = i.clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: i.extent)
                return diff(i, blurred)
            }
            func trio(_ s: EditSettings) -> (CIImage, CIImage, CIImage) {
                (small(RenderPipeline.render(source: source, settings: s, targetSize: CGSize(width: 1400, height: 1400))),
                 small(RenderPipeline.render(source: source, settings: s, targetSize: CGSize(width: 2800, height: 2800))),
                 small(RenderPipeline.render(source: source, settings: s, targetSize: CGSize(width: 2800, height: 2800), proxyScale: 0.55)))
            }
            let (d0, d1, d2) = trio(EditSettings())
            let base = max(diff(d0, d1), diff(d1, d2))
            let (c0, c1, c2) = trio(combo)
            let dc = max(diff(c0, c1), diff(c1, c2))
            print(String(format: "  scale consistency: default %.4f (resampling baseline), combo %.4f", base, dc))
            check(dc < base + 0.006, "combo looks the same at 1400 px, 2800 px and as a proxy")
            var grainy = EditSettings()
            grainy.effects.grainAmount = 50
            let (g0, g1, g2) = trio(grainy)
            let e0 = energy(g0), e1 = energy(g1), e2 = energy(g2), eBase = energy(d1)
            print(String(format: "  grain energy at 700 px: from 1400 %.4f, from 2800 %.4f, proxy %.4f (no grain %.4f)", e0, e1, e2, eBase))
            check(abs(diff(g0, g1) - diff(d0, d1)) < 0.03 && e0 / e1 > 0.6 && e0 / e1 < 1.6 && e2 / e1 > 0.6 && e2 / e1 < 1.6,
                  "grain looks consistent across render sizes")
        }

        // MARK: Timing
        print("\nTiming (ms, median of 5; interactive context caches intermediates)")
        let combo = cases.first { $0.0 == "24_combo" }!.1
        var heavy = combo
        heavy.presence.dehaze = 20
        heavy.colorMixer[.blue] = HSLAdjustment(saturation: -30)
        heavy.effects.grainAmount = 30
        func median(_ n: Int = 5, _ f: () -> Void) -> Double {
            var ts = (0..<n).map { _ in ms(f) }
            ts.sort()
            return ts[n / 2]
        }
        func row(_ name: String, _ v: Double) { print(String(format: "  %-52@ %7.1f", name as NSString, v)) }
        let ictx = RenderPipeline.interactiveContext
        for (label, s) in [("default", EditSettings()), ("combo", combo), ("heavy (combo+dehaze+mixer+grain)", heavy)] {
            _ = RenderPipeline.renderCGImage(source: source, settings: s, targetSize: CGSize(width: 1600, height: 1600), context: ictx)
            row("1600 px \(label), settings unchanged", median { _ = RenderPipeline.renderCGImage(source: source, settings: s, targetSize: CGSize(width: 1600, height: 1600), context: ictx) })
            var i = 0
            row("1600 px \(label), exposure changes each frame", median {
                var s2 = s; i += 1; s2.tone.exposure = Double(i % 7) * 0.1
                _ = RenderPipeline.renderCGImage(source: source, settings: s2, targetSize: CGSize(width: 1600, height: 1600), context: ictx)
            })
            row("1600 px \(label), shadows change each frame", median {
                var s2 = s; i += 1; s2.tone.shadows = Double(i % 7) * 10
                _ = RenderPipeline.renderCGImage(source: source, settings: s2, targetSize: CGSize(width: 1600, height: 1600), context: ictx)
            })
            row("2880 px canvas \(label), shadows change", median {
                var s2 = s; i += 1; s2.tone.shadows = Double(i % 7) * 10
                _ = RenderPipeline.renderCGImage(source: source, settings: s2, targetSize: CGSize(width: 2880, height: 1800), context: ictx)
            })
            row("2880 px canvas, 0.5 proxy \(label), shadows change", median {
                var s2 = s; i += 1; s2.tone.shadows = Double(i % 7) * 10
                _ = RenderPipeline.renderCGImage(source: source, settings: s2, targetSize: CGSize(width: 2880, height: 1800), proxyScale: 0.5, context: ictx)
            })
        }
        row("1600 px heavy, non-caching context (previews)", median(3) { _ = RenderPipeline.renderCGImage(source: source, settings: heavy, targetSize: CGSize(width: 1600, height: 1600)) })
        t0 = Date()
        let full = RenderPipeline.renderCGImage(source: source, settings: heavy)
        row("full resolution heavy (\(full?.width ?? 0)x\(full?.height ?? 0)), one shot", Date().timeIntervalSince(t0) * 1000)
        t0 = Date()
        _ = RenderPipeline.renderCGImage(source: source, settings: EditSettings())
        row("full resolution default, one shot", Date().timeIntervalSince(t0) * 1000)
        row("color mixer: per-pixel kernel, no LUT to rebuild", 0)

        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
