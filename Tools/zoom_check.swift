//
//  zoom_check.swift
//  Zoom harness: CanvasViewport math (fit / fill / ratio, anchored zoom, pan clamping, steps,
//  CanvasGeometry round trips on a zoomed rect) and RegionRenderer (a region render matches the
//  same pixels of a full render at that scale, incl. crop + local operations) + timings.
//
//  Tools/harness.sh /private/tmp/claude-501/zoom-out/zoom_check Tools/zoom_check.swift sloproom/Develop/Zoom/RegionRenderer.swift
//  /private/tmp/claude-501/zoom-out/zoom_check [dng]
//

import Foundation
import CoreGraphics
import CoreImage

@main
struct ZoomCheck {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
        if !ok { failures += 1 }
    }

    static func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 0.5) -> Bool { abs(a - b) <= eps }

    static func main() async throws {
        viewportChecks()
        let args = CommandLine.arguments
        let dng = URL(fileURLWithPath: args.count > 1 ? args[1] : "/Users/snivik/Pictures/2026/2026-08-01/L1090229.DNG")
        if let source = RenderPipeline.makeSource(url: dng) {
            regionChecks(source)
        } else {
            print("  skip region checks: cannot open \(dng.path)")
        }
        print(failures == 0 ? "ALL ZOOM CHECKS PASSED" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Viewport math

    static func viewportChecks() {
        print("CanvasViewport")
        var v = CanvasViewport(canvasSize: CGSize(width: 1400, height: 900), displayedSize: CGSize(width: 8368, height: 5584),
                               displayScale: 2, margin: 16)
        let fit = v.imageRect
        check(near(fit.midX, 700) && near(fit.midY, 450), "fit is centered")
        check(near(fit.height, 900 - 32) || near(fit.width, 1400 - 32), "fit touches the margin")
        check(!v.isZoomed, "fit is not zoomed")

        // 1:1 anchored at a view point keeps the image point under it.
        let anchor = CGPoint(x: 300, y: 200)
        let before = v.displayedPoint(fromView: anchor)
        v = v.zoomed(to: .ratio(1), anchor: anchor)
        check(near(v.pixelRatio, 1, 1e-6), "1:1 = one device pixel per image pixel")
        check(near(v.imageRect.width, 8368 / 2) && near(v.imageRect.height, 5584 / 2), "1:1 rect size = image px / backing scale")
        let after = v.displayedPoint(fromView: anchor)
        check(near(before.x, after.x, 0.001) && near(before.y, after.y, 0.001), "anchored zoom keeps the point under the pointer")

        // Pan clamping.
        let far = v.panned(by: CGSize(width: 1e6, height: 1e6)).imageRect
        check(near(far.minX, 0) && near(far.minY, 0), "pan clamps at the top-left edge")
        let farOther = v.panned(by: CGSize(width: -1e6, height: -1e6)).imageRect
        check(near(farOther.maxX, 1400) && near(farOther.maxY, 900), "pan clamps at the bottom-right edge")
        let p = v.panned(by: CGSize(width: 37, height: -21))
        check(near(p.imageRect.minX - v.imageRect.minX, 37, 0.51) && near(p.imageRect.minY - v.imageRect.minY, -21, 0.51), "pan moves by the drag")

        // Visible rect.
        let vis = v.visibleDisplayedRect
        check(near(vis.width, 1400 / (8368 / 2), 0.001) && near(vis.height, 900 / (5584 / 2), 0.001), "visible rect at 1:1")

        // Fill covers the view.
        let fill = v.zoomed(to: .fill).imageRect
        check(fill.minX <= 0.5 && fill.minY <= 0.5 && fill.maxX >= 1399.5 && fill.maxY >= 899.5, "fill covers the view")

        // Steps.
        let fitV = v.zoomed(to: .fit)
        check(fitV.stepped(in: true) == .ratio(0.25) || fitV.stepped(in: true) == .ratio(0.5), "⌘= from fit goes to the first step above fit")
        check(v.stepped(in: true) == .ratio(2), "⌘= from 100% → 200%")
        check(v.stepped(in: false) == .ratio(0.5), "⌘- from 100% → 50%")
        check(v.zoomed(to: .ratio(0.5)).stepped(in: false) == .fit || v.zoomed(to: .ratio(0.5)).stepped(in: false) == .ratio(0.25), "⌘- from 50% → 25% or fit")
        check(v.magnified(by: 0.01, anchor: nil).level == .fit, "pinching below fit snaps to fit")
        if case .ratio(let r) = v.magnified(by: 100, anchor: nil).level { check(r <= ZoomLevel.maxRatio, "pinch is capped at max ratio") }
        else { check(false, "pinch in gives a ratio") }

        // Image smaller than the view (50% on a small photo): centered.
        let small = CanvasViewport(canvasSize: CGSize(width: 1400, height: 900), displayedSize: CGSize(width: 1000, height: 800),
                                   displayScale: 2, level: .ratio(1), center: CGPoint(x: 0.1, y: 0.9))
        check(near(small.imageRect.midX, 700) && near(small.imageRect.midY, 450), "smaller-than-view image stays centered")

        // CanvasGeometry on a zoomed rect: mask <-> view round trip with crop + rotation.
        var g = Geometry()
        g.quarterTurns = 1
        g.straightenAngle = 3
        g.crop = NormRect(x: 0.1, y: 0.15, width: 0.7, height: 0.6)
        let math = GeometryMath(sourceSize: CGSize(width: 8368, height: 5584), geometry: g)
        let zv = CanvasViewport(canvasSize: CGSize(width: 1400, height: 900), displayedSize: math.croppedSize, displayScale: 2)
            .zoomed(to: .ratio(2), anchor: CGPoint(x: 900, y: 300))
        let cg = CanvasGeometry(imageRect: zv.imageRect, sourceSize: CGSize(width: 8368, height: 5584), geometry: g, showsCrop: true)
        let m = NormPoint(x: 0.43, y: 0.61)
        let back = cg.maskPoint(fromView: cg.viewPoint(fromMask: m))
        check(abs(back.x - m.x) < 1e-6 && abs(back.y - m.y) < 1e-6, "mask ↔ view round trip on a zoomed, rotated, cropped canvas")
        check(near(cg.viewScale, 1, 1e-6), "viewScale at 200% on 2x = 1 pt per source px")
        check(near(cg.viewLength(fromSourceWidthFraction: 0.01), 83.68, 0.01), "brush / radius lengths scale with zoom")
    }

    // MARK: - Region rendering

    static func regionChecks(_ source: RenderSource) {
        print("RegionRenderer (\(Int(source.orientedSize.width))×\(Int(source.orientedSize.height)))")
        var plain = EditSettings()
        plain.tone.exposure = 0.3
        plain.tone.contrast = 15
        var local = plain
        local.tone.shadows = 40
        local.tone.highlights = -30
        local.presence.clarity = 20
        var cropped = local
        cropped.geometry.crop = NormRect(x: 0.2, y: 0.1, width: 0.6, height: 0.7)
        cropped.masks = [Mask(shape: .radial(RadialGradientMask()))]
        cropped.masks[0].adjustments.exposure = 1

        let renderer = RegionRenderer()
        for (name, settings, scale) in [("plain 1:1", plain, CGFloat(1)), ("local ops 1:1", local, 1),
                                        ("crop+mask 50 pct", cropped, 0.5)] {
            let region = CGRect(x: 0.4, y: 0.35, width: 0.25, height: 0.2)
            guard let tile = renderer.render(source: source, settings: settings, applyCrop: true, scale: scale, region: region) else {
                check(false, "\(name): region render"); continue
            }
            // Reference: the same pipeline, whole image at the same scale, cropped afterwards.
            let out = RegionRenderer.outputSize(source: source, settings: settings, applyCrop: true, scale: scale)
            // Exact (unrounded) target so the reference renders at exactly `scale`.
            let crop = GeometryMath(sourceSize: source.orientedSize, geometry: settings.geometry).croppedSize
            let target = CGSize(width: crop.width * scale, height: crop.height * scale)
            let full = RenderPipeline.render(source: source, settings: settings, targetSize: target, context: RegionRenderer.context)
            let e = full.extent
            let n = tile.normalizedRect
            let px = CGRect(x: n.minX * e.width, y: n.minY * e.height, width: n.width * e.width, height: n.height * e.height).integral
            let ci = CGRect(x: px.minX, y: e.height - px.maxY, width: px.width, height: px.height)
            guard let ref = RegionRenderer.context.createCGImage(full.cropped(to: ci), from: ci, format: .RGBA8,
                                                                 colorSpace: RenderPipeline.displayP3) else {
                check(false, "\(name): reference render"); continue
            }
            check(tile.image.width == ref.width && tile.image.height == ref.height, "\(name): tile \(tile.image.width)×\(tile.image.height) = reference size")
            let diff = meanAbsDiff(tile.image, ref)
            check(diff < 1.5, String(format: "\(name): matches the full render (mean |Δ| %.2f / 255)", diff))
            check(near(tile.outputSize.width, out.width, 1) && near(tile.outputSize.height, out.height, 1), "\(name): output size \(tile.outputSize)")
        }

        // Timings: visible region of a 1400×900 pt view on a 2x display at 1:1 (2800×1800 px).
        print("Timing (1:1 region of a 1400×900 pt view @2x = 2800×1800 px)")
        let w = 2800 / source.orientedSize.width, h = 1800 / source.orientedSize.height
        for (name, settings) in [("plain", plain), ("local ops", local)] {
            let r = RegionRenderer()
            var times: [String] = []
            for i in 0..<5 {
                let region = CGRect(x: 0.3 + 0.03 * Double(i), y: 0.3, width: w, height: h)
                if let t = r.render(source: source, settings: settings, applyCrop: true, scale: 1, region: region) {
                    times.append(String(format: "%.0f%@", t.milliseconds, t.usedCachedDecode ? "c" : ""))
                }
            }
            print("  \(name): \(times.joined(separator: ", ")) ms  (c = cached full-res decode; first local-ops render materializes it)")
        }
    }

    static func meanAbsDiff(_ a: CGImage, _ b: CGImage) -> Double {
        func bytes(_ img: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: img.width * img.height * 4)
            let ctx = CGContext(data: &data, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                space: RenderPipeline.displayP3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return data
        }
        let x = bytes(a), y = bytes(b)
        guard x.count == y.count, !x.isEmpty else { return 255 }
        var sum = 0
        for i in stride(from: 0, to: x.count, by: 4) {
            sum += abs(Int(x[i]) - Int(y[i])) + abs(Int(x[i + 1]) - Int(y[i + 1])) + abs(Int(x[i + 2]) - Int(y[i + 2]))
        }
        return Double(sum) / Double(x.count / 4 * 3)
    }
}
