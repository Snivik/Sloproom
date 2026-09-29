//
//  masks_check.swift
//  Headless check of masking: mask shapes, brush rasterization + cache, MaskStage, JSON size.
//
//  Build & run. The mask-tool interaction (DevelopSession + Masking/UI engine-side files) is
//  compiled in too:
//
//    W=<repo>; OUT=/private/tmp/claude-501/out-masks
//    UI="$W/sloproom/Develop/DevelopSession.swift $W/sloproom/Develop/Masking/UI/MaskInteraction.swift \
//        $W/sloproom/Develop/Masking/UI/MaskToolState.swift $W/sloproom/Develop/Masking/UI/DevelopSession+Masks.swift \
//        $W/sloproom/Develop/Crop/DevelopSession+Crop.swift $W/sloproom/Develop/Crop/CropMath.swift $W/sloproom/Develop/Crop/Catalog+CropPresets.swift"
//    $W/Tools/harness.sh $OUT/masks_check $W/Tools/masks_check.swift $UI
//    $OUT/masks_check [dng] [out-dir]
//
//  Writes render_*.jpg (edited photo) and mask_*.png (raw grayscale masks) into out-dir.
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@main
struct MasksCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS" : "  FAIL", what)
        if !ok { failures += 1 }
    }

    static func main() async throws {
        let args = CommandLine.arguments
        let dng = URL(fileURLWithPath: args.count > 1 ? args[1] : "/Users/snivik/Pictures/2026/2026-08-01/L1090240.DNG")
        let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "/private/tmp/claude-501/out-masks")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // MARK: Masks
        var sky = Mask(name: "Sky", shape: .linear(LinearGradientMask(start: NormPoint(x: 0.5, y: 0), end: NormPoint(x: 0.5, y: 0.4))))
        sky.adjustments.exposure = -1.5

        var r = RadialGradientMask()
        r.center = NormPoint(x: 0.5, y: 0.5); r.radiusX = 0.32; r.radiusY = 0.42; r.rotation = 20; r.feather = 60
        var vignette = Mask(name: "Vignette", shape: .radial(r))
        vignette.inverted = true
        vignette.adjustments.exposure = -1.5

        var paint = BrushStroke(); paint.radius = 0.04; paint.feather = 60; paint.flow = 100
        for i in 0...60 { // wavy horizontal stroke across the middle, decimated like the UI does
            let t = Double(i) / 60
            MaskEditing.append(NormPoint(x: 0.15 + 0.7 * t, y: 0.62 + 0.05 * sin(t * 2 * .pi)), to: &paint, aspect: 2 / 3)
        }
        var eraser = BrushStroke(); eraser.radius = 0.02; eraser.feather = 30; eraser.isEraser = true
        for i in 0...40 { MaskEditing.append(NormPoint(x: 0.5, y: 0.45 + 0.35 * Double(i) / 40), to: &eraser, aspect: 2 / 3) }
        var softDab = BrushStroke(); softDab.radius = 0.05; softDab.feather = 100; softDab.flow = 50
        softDab.points = [NormPoint(x: 0.25, y: 0.3)]
        var brushMask = BrushMask(); brushMask.strokes = [paint, eraser, softDab]
        var brush = Mask(name: "Brush", shape: .brush(brushMask))
        brush.adjustments.exposure = 2

        // MARK: Mask values (pure mask images at 1500 × 1000)
        let ctx = RenderContext(fullSize: CGSize(width: 6000, height: 4000), imageSize: CGSize(width: 1500, height: 1000), draft: false, applyCrop: true)
        for (name, m) in [("linear", sky), ("radial_inverted", vignette), ("brush", brush)] {
            let t = Date()
            guard let cg = MaskRenderer.grayscaleImage(for: m, context: ctx) else { check(false, "mask \(name)"); continue }
            writePNG(cg, to: outDir.appendingPathComponent("mask_\(name).png"))
            print(String(format: "  mask_%@ %dx%d in %.1f ms", name, cg.width, cg.height, Date().timeIntervalSince(t) * 1000))
        }
        func v(_ m: Mask, _ x: Double, _ y: Double, _ c: RenderContext = ctx) -> Double {
            sample(MaskRenderer.grayscaleImage(for: m, context: c)!, x: x, y: y)
        }
        check(v(sky, 0.5, 0.005) > 0.97, "linear: full effect at start (\(fmt(v(sky, 0.5, 0.005))))")
        check(abs(v(sky, 0.3, 0.2) - 0.5) < 0.03, "linear: 50 % halfway (\(fmt(v(sky, 0.3, 0.2))))")
        check(v(sky, 0.5, 0.1) > 0.8 && v(sky, 0.5, 0.1) < 0.9, "linear: smoothstep at 25 % (\(fmt(v(sky, 0.5, 0.1))), expect 0.84)")
        check(v(sky, 0.7, 0.5) < 0.01, "linear: none beyond end")
        check(v(vignette, 0.5, 0.5) < 0.01, "radial inverted: no effect at center")
        check(v(vignette, 0.02, 0.02) > 0.99, "radial inverted: full effect in corners")
        let edge = v(vignette, 0.5 + 0.32 * 0.8 * cos(20 * .pi / 180), 0.5 + 0.32 * 0.8 * sin(20 * .pi / 180) * 1.5)
        check(edge > 0.02 && edge < 0.98, "radial: feathered along rotated x-axis (\(fmt(edge)))")
        // Portrait, rotated ellipse: value along both rotated axes at 0.8 × radius.
        // feather 60 -> inner 0.4; t = (1 - 0.8) / 0.6 -> smoothstep 0.259.
        var rp = RadialGradientMask(); rp.radiusX = 0.3; rp.radiusY = 0.35; rp.rotation = 15; rp.feather = 60
        let portrait = RenderContext(fullSize: CGSize(width: 4000, height: 6000), imageSize: CGSize(width: 1000, height: 1500), draft: false, applyCrop: true)
        let th = 15 * Double.pi / 180
        let ax = v(Mask(shape: .radial(rp)), 0.5 + 0.8 * 0.3 * cos(th), 0.5 + 0.8 * 0.3 * sin(th) * 1000 / 1500, portrait)
        let ay = v(Mask(shape: .radial(rp)), 0.5 - 0.8 * 0.35 * sin(th) * 1500 / 1000, 0.5 + 0.8 * 0.35 * cos(th), portrait)
        check(abs(ax - 0.259) < 0.03 && abs(ay - 0.259) < 0.03, "radial portrait rotated: x-axis \(fmt(ax)), y-axis \(fmt(ay)) (expect 0.259)")
        check(v(Mask(shape: .radial(rp)), 0.5, 0.5, portrait) > 0.99, "radial: full effect at center")
        check(v(brush, 0.3, 0.62 + 0.05 * sin(0.15 / 0.7 * 2 * .pi)) > 0.97, "brush: full inside stroke core")
        check(v(brush, 0.5, 0.62) < 0.05, "brush: eraser removes where it crosses (\(fmt(v(brush, 0.5, 0.62))))")
        check(v(brush, 0.3, 0.2) < 0.01, "brush: nothing away from strokes")
        let dab = v(brush, 0.25, 0.3)
        check(abs(dab - 0.5) < 0.03, "brush: flow 50 dab center = 0.5 (\(fmt(dab)))")
        check(v(brush, 0.25 + 0.025, 0.3) < dab && v(brush, 0.25 + 0.025, 0.3) > 0.05, "brush: feather 100 falls off")
        // Scale independence: same normalized point, 400 px render.
        let small = RenderContext(fullSize: ctx.fullSize, imageSize: CGSize(width: 400, height: 267), draft: true, applyCrop: true)
        check(abs(v(sky, 0.3, 0.2, small) - v(sky, 0.3, 0.2)) < 0.03 && abs(v(brush, 0.25, 0.3, small) - dab) < 0.05,
              "masks match at 400 px and 1500 px render scale")

        // MARK: Brush cache / incremental painting
        BrushRasterizer.cache.removeAll()
        var t = Date()
        _ = BrushRasterizer.raster(for: brushMask, id: brush.id, width: 2000, height: 1333)
        let cold = Date().timeIntervalSince(t)
        t = Date()
        _ = BrushRasterizer.raster(for: brushMask, id: brush.id, width: 2000, height: 1333)
        let hit = Date().timeIntervalSince(t)
        var painting = brushMask
        var live = BrushStroke(); live.radius = 0.03
        painting.strokes.append(live)
        var incremental: [Double] = []
        for i in 0..<30 { // simulate 30 mouse moves of an in-progress stroke
            painting.strokes[painting.strokes.count - 1].points.append(NormPoint(x: 0.1 + Double(i) * 0.02, y: 0.85))
            t = Date()
            _ = BrushRasterizer.raster(for: painting, id: brush.id, width: 2000, height: 1333)
            incremental.append(Date().timeIntervalSince(t))
        }
        print(String(format: "  brush raster 2000px: cold %.1f ms, cached %.2f ms, painting avg %.1f ms (max %.1f)", cold * 1000, hit * 1000,
                     incremental.reduce(0, +) / Double(incremental.count) * 1000, (incremental.max() ?? 0) * 1000))
        check(hit < cold / 5, "cached raster is fast")

        // MARK: Render the photo
        guard let source = RenderPipeline.makeSource(url: dng) else { check(false, "makeSource \(dng.path)"); exit(1) }
        let target = CGSize(width: 1400, height: 1400)
        var base = EditSettings(); base.tone.exposure = 1 // the samples are dark
        var cases: [(String, EditSettings)] = []
        cases.append(("render_original", base))
        var a = base; a.masks = [sky]; cases.append(("render_a_linear_sky", a))
        var b = base; b.masks = [vignette]; cases.append(("render_b_radial_inverted", b))
        var c = base; c.masks = [brush]; cases.append(("render_c_brush_eraser", c))
        var all = base; all.masks = [sky, vignette, brush]; cases.append(("render_all", all))
        var disabled = all; for i in disabled.masks.indices { disabled.masks[i].isEnabled = false }
        var means: [String: Double] = [:]
        var originalCG: CGImage?
        for (name, s) in cases {
            t = Date()
            guard let cg = RenderPipeline.renderCGImage(source: source, settings: s, targetSize: target) else { check(false, name); continue }
            print(String(format: "  %@ %dx%d in %.0f ms", name, cg.width, cg.height, Date().timeIntervalSince(t) * 1000))
            writeJPEG(cg, to: outDir.appendingPathComponent("\(name).jpg"))
            means[name] = meanLuma(cg, rect: CGRect(x: 0, y: 0, width: 1, height: 0.1))
            if name == "render_original" { originalCG = cg }
            if name == "render_b_radial_inverted", let o = originalCG {
                let cornerO = meanLuma(o, rect: CGRect(x: 0, y: 0.9, width: 0.1, height: 0.1))
                let cornerB = meanLuma(cg, rect: CGRect(x: 0, y: 0.9, width: 0.1, height: 0.1))
                let midO = meanLuma(o, rect: CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1))
                let midB = meanLuma(cg, rect: CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1))
                check(cornerB < cornerO * 0.7 && abs(midB - midO) < 0.01, "inverted radial darkens corners only")
            }
        }
        check(!isPassThroughRenderer, "LocalAdjustmentRenderer applies local adjustments")
        if let o = means["render_original"], let s = means["render_a_linear_sky"] {
            check(s < o * 0.75, "sky gradient darkens the top (\(fmt(o)) -> \(fmt(s)))")
        }
        if let d = RenderPipeline.renderCGImage(source: source, settings: disabled, targetSize: target), let o = originalCG {
            check(meanLuma(d, rect: CGRect(x: 0, y: 0, width: 1, height: 1)) == meanLuma(o, rect: CGRect(x: 0, y: 0, width: 1, height: 1)), "disabled masks render the original")
        }
        // Full-resolution render of the brush mask path (export): must not blow up.
        t = Date()
        let fullCtx = RenderContext(fullSize: source.orientedSize, imageSize: source.orientedSize, draft: false, applyCrop: true)
        if let m = MaskRenderer.maskImage(for: brush, context: fullCtx) {
            check(m.extent.size == source.orientedSize, "full-res brush mask covers \(Int(source.orientedSize.width))x\(Int(source.orientedSize.height))")
        }
        print(String(format: "  full-res brush mask graph in %.0f ms", Date().timeIntervalSince(t) * 1000))

        // MARK: Coverage overlay
        if let cov = MaskRenderer.coverageImage(for: vignette, geometry: b.geometry, fullSize: source.orientedSize, targetSize: CGSize(width: 1400, height: 1400)) {
            writePNG(cov, to: outDir.appendingPathComponent("overlay_radial_inverted.png"))
            check(cov.width == 1400 || cov.height == 1400, "coverage overlay at render size (\(cov.width)x\(cov.height))")
        } else { check(false, "coverage overlay") }

        // MARK: JSON size
        var long = BrushStroke(); long.radius = 0.02
        for i in 0..<20000 { // 20 000 raw mouse samples of a long spiral -> decimated by spacing
            let a = Double(i) / 20000 * 12 * .pi
            MaskEditing.append(NormPoint(x: 0.5 + 0.4 * (Double(i) / 20000) * cos(a), y: 0.5 + 0.4 * (Double(i) / 20000) * sin(a)), to: &long, aspect: 2 / 3)
        }
        let rawCount = long.points.count
        MaskEditing.finish(&long, aspect: 2 / 3)
        print("  spiral: 20000 samples -> \(rawCount) decimated points -> \(long.points.count) after simplify")
        var fixed = BrushStroke(); fixed.radius = 0.02
        fixed.points = (0..<2000).map { i in MaskEditing.rounded(NormPoint(x: Double.random(in: 0...1), y: Double.random(in: 0...1))) }
        var bm = BrushMask(); bm.strokes = [fixed]
        var s2000 = EditSettings(); s2000.masks = [Mask(name: "Brush 1", shape: .brush(bm))]
        let json = s2000.jsonString() ?? ""
        print("  JSON of a mask with one 2000-point stroke: \(json.utf8.count) bytes (\(json.utf8.count / 2000) B/point)")
        check(EditSettings.fromJSON(json) == s2000, "2000-point mask JSON round trip")
        check(json.utf8.count < 60_000, "2000-point stroke JSON < 60 KB")

        // MARK: Mask tool interaction (drives MaskInteraction like the overlay does)
        try interactionChecks(dng: dng, outDir: outDir)

        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func interactionChecks(dng: URL, outDir: URL) throws {
        let catalog = try Catalog.open(at: outDir.appendingPathComponent("ui-catalog-\(Int(Date().timeIntervalSince1970))"))
        guard let meta = PhotoMetadataReader.read(url: dng) else { check(false, "metadata"); return }
        let id = try catalog.insertPhoto(Photo(url: dng, metadata: meta, importDate: Date(), sidecarPath: nil))
        guard let photo = try catalog.photo(id: id) else { return }
        let session = DevelopSession(photo: photo, catalog: catalog)
        let tool = MaskToolState.shared
        tool.eraseMode = false
        let rect = CanvasGeometry.aspectFitRect(imageSize: session.orientedSize, in: CGRect(x: 16, y: 16, width: 900, height: 900))
        let space = MaskSpace(geometry: session.canvasGeometry(imageRect: rect))
        var ui = MaskInteraction()
        func vp(_ x: Double, _ y: Double) -> CGPoint { space.view(space.px(NormPoint(x: x, y: y))) }
        func drag(_ a: CGPoint, _ b: CGPoint, steps: Int = 12, erase: Bool = false) {
            for i in 0...steps {
                let t = steps == 0 ? 1 : CGFloat(i) / CGFloat(steps)
                ui.dragChanged(start: a, location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                               space: space, session: session, tool: tool, erase: erase)
            }
            ui.dragEnded(location: b, space: space, session: session)
        }
        func near(_ p: NormPoint?, _ x: Double, _ y: Double, _ tol: Double = 0.004) -> Bool {
            guard let p else { return false }
            return abs(p.x - x) < tol && abs(p.y - y) < tol
        }
        print("  interaction: oriented \(session.orientedSize), image rect \(rect)")

        // Create a linear gradient by dragging.
        session.beginCreatingMask(.linear)
        drag(vp(0.5, 0), vp(0.5, 0.4))
        let linID = session.settings.masks.last?.id
        let lin = { session.mask(id: linID!)?.linear }
        check(session.settings.masks.count == 1 && session.selectedMaskID == linID && tool.pendingKind == nil && session.activeTool == .mask,
              "linear: drag creates + selects, tool active")
        check(near(lin()?.start, 0.5, 0) && near(lin()?.end, 0.5, 0.4), "linear: start/end follow the drag")
        drag(vp(0.2, 0.4), vp(0.2, 0.5))
        check(near(lin()?.start, 0.5, 0) && near(lin()?.end, 0.5, 0.5), "linear: dragging the end line widens the feather")
        drag(vp(0.5, 0.25), vp(0.6, 0.35))
        check(near(lin()?.start, 0.6, 0.1) && near(lin()?.end, 0.6, 0.6), "linear: dragging the center pin moves it")
        let h = LinearHandles(lin()!, space: space)
        let mid = space.view(h.mid)
        drag(h.rotateHandle, CGPoint(x: mid.x, y: mid.y - 44))
        if let l = lin() {
            check(l.start.x > l.end.x + 0.1 && abs(l.start.y - l.end.y) * space.aspect < 0.01, "linear: rotate handle turns the gradient 90°")
        }
        session.undo()
        check(near(lin()?.start, 0.6, 0.1) && near(lin()?.end, 0.6, 0.6), "undo reverts one drag")

        // Radial: create, resize.
        session.beginCreatingMask(.radial)
        drag(vp(0.5, 0.5), vp(0.7, 0.65))
        let radID = session.settings.masks.last?.id
        let rad = { session.mask(id: radID!)?.radial }
        check(session.settings.masks.count == 2 && abs((rad()?.radiusX ?? 0) - 0.2) < 0.004 && abs((rad()?.radiusY ?? 0) - 0.15) < 0.004
              && near(rad()?.center, 0.5, 0.5), "radial: drag from center sets radii")
        drag(vp(0.7, 0.5), vp(0.8, 0.5))
        check(abs((rad()?.radiusX ?? 0) - 0.3) < 0.004 && abs((rad()?.radiusY ?? 0) - 0.15) < 0.004, "radial: X handle resizes X only")
        let rh = RadialHandles(rad()!, space: space)
        let c = space.view(rh.center)
        drag(rh.rotateHandle, CGPoint(x: c.x + 200, y: c.y)) // top handle -> right = +90°
        check(abs((rad()?.rotation ?? 0) - 90) < 1, "radial: rotate handle (\(fmt(rad()?.rotation ?? 0))°)")
        drag(vp(0.52, 0.52), vp(0.42, 0.62))
        check(near(rad()?.center, 0.4, 0.6), "radial: drag inside moves")

        // Clicking another mask's pin selects it.
        drag(vp(0.6, 0.35), vp(0.6, 0.35), steps: 0)
        check(session.selectedMaskID == linID && near(lin()?.start, 0.6, 0.1), "clicking a pin selects that mask (no move)")

        // Brush: paint (300 mouse events) then erase across.
        session.beginCreatingMask(.brush)
        tool.brushSize = 16; tool.brushFeather = 50; tool.brushFlow = 100
        drag(vp(0.2, 0.8), vp(0.8, 0.8), steps: 300)
        let brushID = session.settings.masks.last?.id
        let br = { session.mask(id: brushID!)?.brush }
        check(session.settings.masks.count == 3 && br()?.strokes.count == 1 && session.selectedMaskID == brushID, "brush: first stroke creates the mask")
        let pts = br()?.strokes.first?.points ?? []
        check(pts.count >= 2 && pts.count <= 4 && pts.allSatisfy { abs($0.y - 0.8) < 0.002 }, "brush: straight stroke stored with \(pts.count) points (300 events)")
        drag(vp(0.5, 0.7), vp(0.5, 0.9), steps: 50, erase: true)
        check(br()?.strokes.count == 2 && br()?.strokes.last?.isEraser == true, "brush: ⌥ paints an eraser stroke")
        drag(vp(0.2, 0.3), vp(0.2, 0.3), steps: 0) // click = dab
        check(br()?.strokes.count == 3 && br()?.strokes.last?.points.count == 1, "brush: click paints a dab")
        let ctx = RenderContext(fullSize: session.orientedSize, imageSize: CGSize(width: 800, height: 800 * session.orientedSize.height / session.orientedSize.width), draft: true, applyCrop: true)
        if let m = session.mask(id: brushID!), let cg = MaskRenderer.grayscaleImage(for: m, context: ctx) {
            writePNG(cg, to: outDir.appendingPathComponent("mask_ui_brush.png"))
            check(sample(cg, x: 0.3, y: 0.8) > 0.97 && sample(cg, x: 0.5, y: 0.8) < 0.03 && sample(cg, x: 0.2, y: 0.3) > 0.97,
                  "brush: painted mask renders (paint 1, erased 0, dab 1)")
        }

        // Delete + undo.
        session.deleteMask(brushID!)
        check(session.settings.masks.count == 2 && session.selectedMaskID == nil, "delete mask")
        session.undo()
        check(session.settings.masks.count == 3, "undo restores the deleted mask")

        // Click (no drag) with a pending radial: default size.
        session.beginCreatingMask(.radial)
        drag(vp(0.3, 0.3), vp(0.3, 0.3), steps: 0)
        check(session.settings.masks.count == 4 && session.selectedMask?.radial != nil, "click creates a default radial")
        session.finishMasking()
        check(session.activeTool == .none, "Done leaves the mask tool")
        session.close()
    }

    /// True if LocalAdjustmentRenderer returns its input unchanged for a +1 EV adjustment.
    static var isPassThroughRenderer: Bool {
        let img = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        var adj = LocalAdjustments(); adj.exposure = 1
        let c = RenderContext(fullSize: CGSize(width: 4, height: 4), imageSize: CGSize(width: 4, height: 4), draft: false, applyCrop: true)
        return LocalAdjustmentRenderer.apply(img, adj, context: c) === img
    }

    static func fmt(_ x: Double) -> String { String(format: "%.3f", x) }

    /// Red channel (0...1) at a top-left normalized point.
    static func sample(_ image: CGImage, x: Double, y: Double) -> Double {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.linearSRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let w = Double(image.width), h = Double(image.height)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: -(x * w).rounded(.down), y: -(h - 1 - (y * h).rounded(.down)), width: w, height: h))
        return Double(px[0]) / 255
    }

    /// Mean luma of a top-left normalized rect.
    static func meanLuma(_ image: CGImage, rect: CGRect) -> Double {
        let w = 200, h = 200
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0, n = 0.0
        for yy in Int(rect.minY * Double(h))..<Int(rect.maxY * Double(h)) {
            let row = yy // bitmap rows are stored top to bottom
            for xx in Int(rect.minX * Double(w))..<Int(rect.maxX * Double(w)) {
                let i = (row * w + xx) * 4
                sum += 0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2]); n += 1
            }
        }
        return sum / max(n, 1) / 255
    }

    static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
