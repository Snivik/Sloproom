//
//  lrmatch_check.swift
//  Calibrates the Develop sliders against real Lightroom Classic exports of one RAW.
//
//  Reference layout (downscaled copies of the owner's exports, never the 40 MB originals):
//    <tuning>/ref/<Slider>/<value>.jpg     whole image, 1600 px long side (sips -Z 1600)
//    <tuning>/ref100/<Slider>/<value>.jpg  1:1 pixels, centered 1600×1067 crop of the full-res export
//    <tuning>/refhl/<Slider>/<value>.jpg   (optional) 1:1 crop at a fixed offset (bright metal), see `crops`
//  Every <Slider> folder present is calibrated; folder names map to EditSettings fields
//  (Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Texture, Clarity, Dehaze, Vibrance,
//  Saturation). File name = slider value ("-100", "+2", "0").
//
//  For each slider and value it renders the DNG through the REAL pipeline (RenderPipeline.render,
//  same stages as the app) with only that slider changed, writes ours next to the refs
//  (<tuning>/out/<label>/ours…/<Slider>/<value>.jpg), side-by-side montages
//  (<tuning>/out/<label>/montage…/<Slider>.jpg, LR left | ours right, one row per value) and a ±50
//  ladder of ours (<tuning>/out/<label>/ladder/<Slider>.jpg), and prints metrics:
//
//  - The slider's EFFECT is compared, not the absolute look (Lightroom's Adobe Standard rendering
//    and our camera-matched Apple decode already differ at 0): ΔL*(v) = L*(v) − L*(0) per pixel.
//    · zone table: pixels binned by LR-0 L* into 8 zones; mean ΔL* / ΔC* of LR vs ours per zone
//    · zoneL / zoneC = RMS over zones of (ours − LR) mean shift
//    · eff% = RMS over pixels (box-averaged to 1/4 res) of (ΔL*ours − ΔL*LR) / RMS(ΔL*LR) × 100
//    · bands: band-pass energy of L* (fine σ1, medium σ1.5–6, coarse σ6–24) as log2 ratio to 0
//    · haze: mean dark channel (min sRGB) and mean chroma shift (Dehaze)
//  - Baseline: ours(0) vs LR(0) per zone.
//  Summary lines are also written to <tuning>/out/<label>/metrics.tsv.
//
//  Tools/harness.sh /private/tmp/claude-501/tuning-out/lrmatch_check Tools/lrmatch_check.swift
//  /private/tmp/claude-501/tuning-out/lrmatch_check [dng] [tuning-dir] [label] [only-slider[,slider…]] [nocrop]
//  /private/tmp/claude-501/tuning-out/lrmatch_check fit highlights-|highlights+|shadows-|shadows+|basemix [max-evals]
//    Nelder–Mead over AdjustmentOps.ToneModel constants (prints the best values to paste into ToneModel).
//

import Foundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers

// MARK: - Slider registry

nonisolated struct SliderSpec {
    let name: String
    let apply: (inout EditSettings, Double) -> Void
}

nonisolated let sliderSpecs: [String: SliderSpec] = {
    let list: [SliderSpec] = [
        .init(name: "exposure") { $0.tone.exposure = $1 },
        .init(name: "contrast") { $0.tone.contrast = $1 },
        .init(name: "highlights") { $0.tone.highlights = $1 },
        .init(name: "shadows") { $0.tone.shadows = $1 },
        .init(name: "whites") { $0.tone.whites = $1 },
        .init(name: "blacks") { $0.tone.blacks = $1 },
        .init(name: "texture") { $0.presence.texture = $1 },
        .init(name: "clarity") { $0.presence.clarity = $1 },
        .init(name: "dehaze") { $0.presence.dehaze = $1 },
        .init(name: "vibrance") { $0.presence.vibrance = $1 },
        .init(name: "saturation") { $0.presence.saturation = $1 },
    ]
    return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
}()

// MARK: - Images as L*a*b* arrays

nonisolated struct LabImage {
    let w: Int, h: Int
    var L: [Float], C: [Float], dark: [Float]

    init(cg: CGImage) {
        let w = cg.width, h = cg.height
        self.w = w; self.h = h
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var lut = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            let c = Float(i) / 255
            lut[i] = c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
        }
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrtf(t) : 7.787 * t + 16 / 116 }
        var L = [Float](repeating: 0, count: w * h), C = L, D = L
        for i in 0..<(w * h) {
            let r = lut[Int(px[i * 4])], g = lut[Int(px[i * 4 + 1])], b = lut[Int(px[i * 4 + 2])]
            let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
            let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
            let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
            let fx = f(x), fy = f(y), fz = f(z)
            L[i] = 116 * fy - 16
            let a = 500 * (fx - fy), bb = 200 * (fy - fz)
            C[i] = (a * a + bb * bb).squareRoot()
            D[i] = Float(min(px[i * 4], px[i * 4 + 1], px[i * 4 + 2])) / 255
        }
        self.L = L; self.C = C; self.dark = D
    }
}

/// Separable Gaussian blur with clamped edges.
nonisolated func gaussian(_ src: [Float], w: Int, h: Int, sigma: Float) -> [Float] {
    let r = max(1, Int((3 * sigma).rounded(.up)))
    var k = (0...(2 * r)).map { i -> Float in let d = Float(i - r); return expf(-d * d / (2 * sigma * sigma)) }
    let s = k.reduce(0, +); k = k.map { $0 / s }
    var tmp = [Float](repeating: 0, count: w * h), out = tmp
    src.withUnsafeBufferPointer { S in
        tmp.withUnsafeMutableBufferPointer { T in
            for y in 0..<h {
                let row = y * w
                for x in 0..<w {
                    var acc: Float = 0
                    for j in 0...(2 * r) { acc += k[j] * S[row + min(max(x + j - r, 0), w - 1)] }
                    T[row + x] = acc
                }
            }
        }
    }
    tmp.withUnsafeBufferPointer { T in
        out.withUnsafeMutableBufferPointer { O in
            for y in 0..<h {
                for x in 0..<w {
                    var acc: Float = 0
                    for j in 0...(2 * r) { acc += k[j] * T[min(max(y + j - r, 0), h - 1) * w + x] }
                    O[y * w + x] = acc
                }
            }
        }
    }
    return out
}

/// Band-pass energies of L* (fine, medium, coarse) inside `roi`.
nonisolated func bandEnergies(_ img: LabImage, roi: (Int, Int, Int, Int)) -> [Double] {
    let g1 = gaussian(img.L, w: img.w, h: img.h, sigma: 1)
    let g15 = gaussian(img.L, w: img.w, h: img.h, sigma: 1.5)
    let g6 = gaussian(img.L, w: img.w, h: img.h, sigma: 6)
    let g24 = gaussian(img.L, w: img.w, h: img.h, sigma: 24)
    var e = [Double](repeating: 0, count: 3); var n = 0
    for y in roi.1..<roi.3 { for x in roi.0..<roi.2 {
        let i = y * img.w + x
        let f = img.L[i] - g1[i], m = g15[i] - g6[i], c = g6[i] - g24[i]
        e[0] += Double(f * f); e[1] += Double(m * m); e[2] += Double(c * c); n += 1
    } }
    return e.map { $0 / Double(max(n, 1)) }
}

// MARK: - Metrics

nonisolated struct EffectMetrics {
    var zoneN = [Int](repeating: 0, count: 8)
    var zoneLRdL = [Double](repeating: 0, count: 8), zoneOursdL = [Double](repeating: 0, count: 8)
    var zoneLRdC = [Double](repeating: 0, count: 8), zoneOursdC = [Double](repeating: 0, count: 8)
    var zoneL = 0.0, zoneC = 0.0, effPct = 0.0, effRMS = 0.0, lrRMS = 0.0
    var bandsLR = [Double](), bandsOurs = [Double]()
    var darkLR = 0.0, darkOurs = 0.0, chromaLR = 0.0, chromaOurs = 0.0
}

nonisolated func zoneIndex(_ l: Float) -> Int { min(7, max(0, Int(l / 12.5))) }

/// Effect of `v` relative to `0` for LR and ours, over the common area minus a border.
nonisolated func effectMetrics(lr0: LabImage, lrV: LabImage, our0: LabImage, ourV: LabImage, border: Int, bands: Bool,
                               bands0: (lr: [Double], ours: [Double])?) -> EffectMetrics {
    var m = EffectMetrics()
    let w = min(lr0.w, lrV.w, our0.w, ourV.w), h = min(lr0.h, lrV.h, our0.h, ourV.h)
    let x0 = border, y0 = border, x1 = w - border, y1 = h - border
    var dkL = 0.0, dkO = 0.0, chL = 0.0, chO = 0.0, n = 0
    for y in y0..<y1 { for x in x0..<x1 {
        let il = y * lr0.w + x, io = y * our0.w + x, ilv = y * lrV.w + x, iov = y * ourV.w + x
        let z = zoneIndex(lr0.L[il])
        m.zoneN[z] += 1
        m.zoneLRdL[z] += Double(lrV.L[ilv] - lr0.L[il]); m.zoneOursdL[z] += Double(ourV.L[iov] - our0.L[io])
        m.zoneLRdC[z] += Double(lrV.C[ilv] - lr0.C[il]); m.zoneOursdC[z] += Double(ourV.C[iov] - our0.C[io])
        dkL += Double(lrV.dark[ilv] - lr0.dark[il]); dkO += Double(ourV.dark[iov] - our0.dark[io])
        chL += Double(lrV.C[ilv] - lr0.C[il]); chO += Double(ourV.C[iov] - our0.C[io])
        n += 1
    } }
    var sL = 0.0, sC = 0.0, zn = 0
    for z in 0..<8 where m.zoneN[z] > 0 {
        let c = Double(m.zoneN[z])
        m.zoneLRdL[z] /= c; m.zoneOursdL[z] /= c; m.zoneLRdC[z] /= c; m.zoneOursdC[z] /= c
        if m.zoneN[z] >= max(200, n / 400) {
            sL += pow(m.zoneOursdL[z] - m.zoneLRdL[z], 2); sC += pow(m.zoneOursdC[z] - m.zoneLRdC[z], 2); zn += 1
        }
    }
    m.zoneL = (sL / Double(max(zn, 1))).squareRoot(); m.zoneC = (sC / Double(max(zn, 1))).squareRoot()
    m.darkLR = dkL / Double(max(n, 1)); m.darkOurs = dkO / Double(max(n, 1))
    m.chromaLR = chL / Double(max(n, 1)); m.chromaOurs = chO / Double(max(n, 1))
    // Spatial: 4×4 box averages of the per-pixel effect (tolerates sub-pixel misalignment).
    var se = 0.0, sl = 0.0, sn = 0
    let b = 4
    var by = y0
    while by + b <= y1 {
        var bx = x0
        while bx + b <= x1 {
            var dl = 0.0, dlo = 0.0
            for y in by..<(by + b) { for x in bx..<(bx + b) {
                dl += Double(lrV.L[y * lrV.w + x] - lr0.L[y * lr0.w + x])
                dlo += Double(ourV.L[y * ourV.w + x] - our0.L[y * our0.w + x])
            } }
            dl /= Double(b * b); dlo /= Double(b * b)
            se += (dlo - dl) * (dlo - dl); sl += dl * dl; sn += 1
            bx += b
        }
        by += b
    }
    m.effRMS = (se / Double(max(sn, 1))).squareRoot()
    m.lrRMS = (sl / Double(max(sn, 1))).squareRoot()
    m.effPct = 100 * m.effRMS / max(m.lrRMS, 1e-6)
    if bands, let bands0 {
        let roi = (x0, y0, x1, y1)
        let eL = bandEnergies(lrV, roi: roi), eO = bandEnergies(ourV, roi: roi)
        m.bandsLR = zip(eL, bands0.lr).map { log2($0 / max($1, 1e-9)) }
        m.bandsOurs = zip(eO, bands0.ours).map { log2($0 / max($1, 1e-9)) }
    }
    return m
}

/// Best integer shift (dx, dy) of `b` relative to `a` matching high-passed L* (|dx|,|dy| ≤ r).
nonisolated func bestShift(_ a: LabImage, _ b: LabImage, region: (Int, Int, Int, Int), r: Int) -> (Int, Int, Double) {
    let ha = zip(a.L, gaussian(a.L, w: a.w, h: a.h, sigma: 2)).map { $0 - $1 }
    let hb = zip(b.L, gaussian(b.L, w: b.w, h: b.h, sigma: 2)).map { $0 - $1 }
    var best = (0, 0, -2.0)
    for dy in -r...r { for dx in -r...r {
        var sab = 0.0, saa = 0.0, sbb = 0.0
        var y = region.1
        while y < region.3 {
            var x = region.0
            while x < region.2 {
                let xb = x + dx, yb = y + dy
                if xb >= 0, yb >= 0, xb < b.w, yb < b.h {
                    let va = Double(ha[y * a.w + x]), vb = Double(hb[yb * b.w + xb])
                    sab += va * vb; saa += va * va; sbb += vb * vb
                }
                x += 1
            }
            y += 1
        }
        let c = sab / max((saa * sbb).squareRoot(), 1e-9)
        if c > best.2 { best = (dx, dy, c) }
    } }
    return best
}

/// Transfer table: pixels binned by L*(0) (bins of 5) -> mean L*(v) and mean C*(v)/C*(0), for one pair.
nonisolated func transferTable(_ a0: LabImage, _ aV: LabImage) -> String {
    var n = [Int](repeating: 0, count: 20), l = [Double](repeating: 0, count: 20)
    var c0 = [Double](repeating: 0, count: 20), c1 = [Double](repeating: 0, count: 20)
    let w = min(a0.w, aV.w), h = min(a0.h, aV.h)
    for y in 8..<(h - 8) { for x in 8..<(w - 8) {
        let i0 = y * a0.w + x, i1 = y * aV.w + x
        let b = min(19, max(0, Int(a0.L[i0] / 5)))
        n[b] += 1; l[b] += Double(aV.L[i1]); c0[b] += Double(a0.C[i0]); c1[b] += Double(aV.C[i1])
    } }
    return (0..<20).filter { n[$0] > 300 }.map { String(format: "%d:%.0f/x%.2f", $0 * 5 + 2, l[$0] / Double(n[$0]), c1[$0] / max(c0[$0], 1e-3)) }.joined(separator: " ")
}

// MARK: - IO helpers

nonisolated func loadCG(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

nonisolated func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.92) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

/// Grid montage: rows of (label, image) cells, each cell `cellW` wide (aspect of the first image).
/// `crop1to1`: draw the center cellW×cellH of each image at 1:1 instead of scaling it down.
nonisolated func montage(_ rows: [[(String, CGImage)]], cellW: Int, crop1to1: Bool) -> CGImage? {
    guard let first = rows.first?.first?.1 else { return nil }
    let cellH = Int((Double(cellW) * Double(first.height) / Double(first.width)).rounded())
    let cols = rows.map(\.count).max() ?? 1
    let W = cols * cellW + (cols - 1) * 4, H = rows.count * cellH + (rows.count - 1) * 4
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.interpolationQuality = .high
    for (ri, row) in rows.enumerated() {
        for (ci, cell) in row.enumerated() {
            let x = ci * (cellW + 4), yTop = ri * (cellH + 4)
            let rect = CGRect(x: x, y: H - yTop - cellH, width: cellW, height: cellH)
            ctx.saveGState(); ctx.clip(to: rect)
            if crop1to1 {
                let img = cell.1
                let ox = (img.width - cellW) / 2, oy = (img.height - cellH) / 2
                ctx.draw(img, in: CGRect(x: x - ox, y: Int(rect.minY) - (img.height - cellH - oy), width: img.width, height: img.height))
            } else {
                ctx.draw(cell.1, in: rect)
            }
            ctx.restoreGState()
            // Label
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 22, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 0.2, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: cell.0, attributes: attrs))
            let tw = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
            ctx.fill(CGRect(x: Double(x) + 6, y: rect.maxY - 34, width: tw + 12, height: 28))
            ctx.textPosition = CGPoint(x: Double(x) + 12, y: rect.maxY - 27)
            CTLineDraw(line, ctx)
        }
    }
    return ctx.makeImage()
}

nonisolated func fmtValue(_ v: Double) -> String {
    let s = v == v.rounded() ? String(Int(v)) : String(v)
    return v > 0 ? "+" + s : s
}


// MARK: - Fitting (Nelder–Mead over model constants)

nonisolated func nelderMead(_ x0: [Double], step: [Double], maxEvals: Int, _ f: ([Double]) -> Double) -> ([Double], Double) {
    let n = x0.count
    var simplex: [[Double]] = [x0]
    for i in 0..<n { var x = x0; x[i] += step[i]; simplex.append(x) }
    var vals = simplex.map(f)
    var evals = n + 1
    while evals < maxEvals {
        let order = vals.indices.sorted { vals[$0] < vals[$1] }
        simplex = order.map { simplex[$0] }; vals = order.map { vals[$0] }
        let centroid = (0..<n).map { j in simplex.dropLast().map { $0[j] }.reduce(0, +) / Double(n) }
        func along(_ t: Double) -> [Double] { (0..<n).map { centroid[$0] + t * (simplex[n][$0] - centroid[$0]) } }
        let xr = along(-1); let fr = f(xr); evals += 1
        if fr < vals[0] {
            let xe = along(-2); let fe = f(xe); evals += 1
            if fe < fr { simplex[n] = xe; vals[n] = fe } else { simplex[n] = xr; vals[n] = fr }
        } else if fr < vals[n - 1] {
            simplex[n] = xr; vals[n] = fr
        } else {
            let xc = along(fr < vals[n] ? -0.5 : 0.5); let fc = f(xc); evals += 1
            if fc < min(fr, vals[n]) { simplex[n] = xc; vals[n] = fc } else {
                for i in 1...n { simplex[i] = (0..<n).map { simplex[0][$0] + 0.5 * (simplex[i][$0] - simplex[0][$0]) }; vals[i] = f(simplex[i]); evals += 1 }
            }
        }
        let spread = (vals.max() ?? 0) - (vals.min() ?? 0)
        if spread < 1e-3 { break }
    }
    let best = vals.indices.min { vals[$0] < vals[$1] }!
    return (simplex[best], vals[best])
}

/// A tunable model constant (AdjustmentOps.ToneModel / PresenceModel `.current`).
nonisolated struct ModelParam {
    let get: () -> Double
    let set: (Double) -> Void
}

nonisolated func tp(_ kp: WritableKeyPath<AdjustmentOps.ToneModel, Double>) -> ModelParam {
    ModelParam(get: { AdjustmentOps.ToneModel.current[keyPath: kp] }, set: { AdjustmentOps.ToneModel.current[keyPath: kp] = $0 })
}
nonisolated func pp(_ kp: WritableKeyPath<AdjustmentOps.PresenceModel, Double>) -> ModelParam {
    ModelParam(get: { AdjustmentOps.PresenceModel.current[keyPath: kp] }, set: { AdjustmentOps.PresenceModel.current[keyPath: kp] = $0 })
}

/// Every tunable constant by name (fit specs + `TONE="name=value,…"` overrides for experiments).
nonisolated let modelParams: [String: ModelParam] = [
    "out.hueKeep": ModelParam(get: { OutputStage.hueKeep }, set: { OutputStage.hueKeep = $0 }),
    "hn.slope": tp(\.highlightsNeg.x), "hn.pivot": tp(\.highlightsNeg.y), "hn.knee": tp(\.highlightsNeg.z), "hn.cap": tp(\.highlightsNeg.w),
    "hp.slope": tp(\.highlightsPos.x), "hp.pivot": tp(\.highlightsPos.y), "hp.knee": tp(\.highlightsPos.z), "hp.cap": tp(\.highlightsPos.w),
    "sn.slope": tp(\.shadowsNeg.x), "sn.pivot": tp(\.shadowsNeg.y), "sn.knee": tp(\.shadowsNeg.z), "sn.cap": tp(\.shadowsNeg.w),
    "sp.slope": tp(\.shadowsPos.x), "sp.pivot": tp(\.shadowsPos.y), "sp.knee": tp(\.shadowsPos.z), "sp.cap": tp(\.shadowsPos.w),
    "baseMix": tp(\.baseMix), "hKeep": tp(\.highlightsDetailKeep), "sKeep": tp(\.shadowsDetailKeep),
    "baseRadius": tp(\.baseRadius), "baseEps": tp(\.baseEps),
    "contrastK": tp(\.contrastK), "whitesK": tp(\.whitesK), "blacksK": tp(\.blacksK),
    "lift.lo": tp(\.liftNeutral.x), "lift.hi": tp(\.liftNeutral.y),
    "tex.radius": pp(\.textureRadius), "tex.pos": pp(\.texturePos), "tex.neg": pp(\.textureNeg),
    "cl.radius": pp(\.clarityRadius), "cl.eps": pp(\.clarityEps), "cl.pos": pp(\.clarityPos), "cl.neg": pp(\.clarityNeg),
    "dh.radius": pp(\.dehazeRadius),
    "dh+.w": pp(\.dehazePlus.x), "dh+.A": pp(\.dehazePlus.y), "dh+.tmin": pp(\.dehazePlus.z), "dh+.gamma": pp(\.dehazePlus.w),
    "dh-.k0": pp(\.dehazeMinus.x), "dh-.k1": pp(\.dehazeMinus.y), "dh-.A": pp(\.dehazeMinus.z), "dh-.desat": pp(\.dehazeMinus.w),
]

nonisolated func applyToneOverrides() {
    guard let spec = ProcessInfo.processInfo.environment["TONE"], !spec.isEmpty else { return }
    for kv in spec.split(separator: ",") {
        let parts = kv.split(separator: "=")
        guard parts.count == 2, let p = modelParams[String(parts[0])], let v = Double(parts[1]) else { print("bad TONE item \(kv)"); continue }
        p.set(v)
    }
    print("TONE overrides: \(spec)")
}

nonisolated struct FitSpec {
    let slider: String
    let values: [Double]
    let params: [(String, Double)]   // name in modelParams, initial step
    var bands = false                // include band-energy error (detail sliders)
}

nonisolated let fitSpecs: [String: FitSpec] = [
    "highlights-": FitSpec(slider: "highlights", values: [-100], params: [("hn.slope", 0.08), ("hn.pivot", 0.6), ("hn.knee", 0.5), ("hn.cap", 0.4)]),
    "highlights+": FitSpec(slider: "highlights", values: [100], params: [("hp.slope", 0.08), ("hp.pivot", 0.6), ("hp.knee", 0.5), ("hp.cap", 0.3)]),
    "shadows-": FitSpec(slider: "shadows", values: [-100], params: [("sn.slope", 0.08), ("sn.pivot", 0.6), ("sn.knee", 0.5), ("sn.cap", 0.3)]),
    "shadows+": FitSpec(slider: "shadows", values: [100], params: [("sp.slope", 0.08), ("sp.pivot", 0.6), ("sp.knee", 0.5), ("sp.cap", 0.4)]),
    "shadows": FitSpec(slider: "shadows", values: [-100, 100], params: [
        ("sn.slope", 0.08), ("sn.pivot", 0.6), ("sn.knee", 0.5), ("sn.cap", 0.3),
        ("sp.slope", 0.08), ("sp.pivot", 0.6), ("sp.knee", 0.5), ("sp.cap", 0.4), ("sKeep", 0.3)], bands: true),
    "highlights": FitSpec(slider: "highlights", values: [-100, 100], params: [
        ("hn.slope", 0.08), ("hn.pivot", 0.6), ("hn.knee", 0.5), ("hn.cap", 0.3),
        ("hp.slope", 0.08), ("hp.pivot", 0.6), ("hp.knee", 0.5), ("hp.cap", 0.3), ("hKeep", 0.3)], bands: true),
    "base-": FitSpec(slider: "highlights", values: [-100], params: [
        ("hn.slope", 0.08), ("hn.pivot", 0.6), ("hn.knee", 0.5), ("hn.cap", 0.3), ("baseRadius", 0.008), ("baseEps", 0.006)]),
    "texture": FitSpec(slider: "texture", values: [-100, 100], params: [("tex.radius", 0.0008), ("tex.pos", 0.15), ("tex.neg", 0.1)], bands: true),
    "clarity": FitSpec(slider: "clarity", values: [-100, 100], params: [
        ("cl.radius", 0.008), ("cl.eps", 0.01), ("cl.pos", 0.3), ("cl.neg", 0.2)], bands: true),
    "dehaze+": FitSpec(slider: "dehaze", values: [100], params: [("dh+.w", 0.15), ("dh+.A", 0.1), ("dh+.tmin", 0.1), ("dh+.gamma", 0.3)], bands: true),
    "dehaze-": FitSpec(slider: "dehaze", values: [-100], params: [("dh-.k0", 0.1), ("dh-.k1", 0.1), ("dh-.A", 0.1), ("dh-.desat", 0.15)], bands: true),
]

nonisolated func runFit(name: String, source: RenderSource, tuning: URL, maxEvals: Int) {
    guard let spec = fitSpecs[name], let slider = sliderSpecs[spec.slider] else { print("unknown fit \(name): \(fitSpecs.keys.sorted())"); return }
    let folder = spec.slider.prefix(1).uppercased() + spec.slider.dropFirst()
    func ref(_ dir: String, _ v: Double) -> LabImage? {
        let d = tuning.appendingPathComponent(dir).appendingPathComponent(folder)
        for n in [fmtValue(v), v == v.rounded() ? String(Int(v)) : String(v)] {
            if let cg = loadCG(d.appendingPathComponent(n + ".jpg")) { return LabImage(cg: cg) }
        }
        return nil
    }
    // Whole image at 1600 + the bright-metal 1:1 crop if present (crop origins as in the main run).
    let crops: [(String, (Int, Int)?)] = [("ref", nil), ("ref100", (3384, 2258)), ("refhl", (2615, 1177))]
    func render(_ s: EditSettings, crop: (Int, Int)?) -> LabImage? {
        let cg: CGImage?
        if let o = crop {
            let full = RenderPipeline.render(source: source, settings: s)
            let H = Int(full.extent.height)
            let r = CGRect(x: o.0, y: H - o.1 - 1067, width: 1600, height: 1067)
            cg = RenderPipeline.makeCGImage(full.cropped(to: r), colorSpace: RenderPipeline.sRGB)
        } else {
            cg = RenderPipeline.makeCGImage(RenderPipeline.render(source: source, settings: s, targetSize: CGSize(width: 1600, height: 1600)),
                                            colorSpace: RenderPipeline.sRGB)
        }
        return cg.map { LabImage(cg: $0) }
    }
    let useBands = ProcessInfo.processInfo.environment["FIT_BANDS"].flatMap(Double.init) ?? (spec.bands ? 2 : 0)
    let params = spec.params.map { (name: $0.0, p: modelParams[$0.0]!, step: $0.1) }
    var cases: [(dir: String, crop: (Int, Int)?, lr0: LabImage, ours0: LabImage, lrV: [Double: LabImage], b0: (lr: [Double], ours: [Double]))] = []
    for (dir, crop) in crops {
        guard let lr0 = ref(dir, 0), let o0 = render(EditSettings(), crop: crop) else { continue }
        var lrV: [Double: LabImage] = [:]
        for v in spec.values { lrV[v] = ref(dir, v) }
        let roi = (8, 8, min(lr0.w, o0.w) - 8, min(lr0.h, o0.h) - 8)
        let b0 = useBands > 0 ? (lr: bandEnergies(lr0, roi: roi), ours: bandEnergies(o0, roi: roi)) : (lr: [], ours: [])
        if lrV.count == spec.values.count { cases.append((dir, crop, lr0, o0, lrV, b0)) }
    }
    print("fit \(name) on \(cases.map(\.dir)) values \(spec.values)")
    var evalN = 0
    func objective(_ x: [Double]) -> Double {
        for (i, p) in params.enumerated() { p.p.set(x[i]) }
        var total = 0.0
        for c in cases {
            for v in spec.values {
                var s = EditSettings(); slider.apply(&s, v)
                guard let o = render(s, crop: c.crop) else { return 1e9 }
                let em = effectMetrics(lr0: c.lr0, lrV: c.lrV[v]!, our0: c.ours0, ourV: o, border: 8, bands: useBands > 0,
                                       bands0: useBands > 0 ? c.b0 : nil)
                total += em.zoneL + 0.5 * em.effRMS + 0.5 * em.zoneC
                if useBands > 0 { total += useBands * zip(em.bandsLR, em.bandsOurs).map { abs($0 - $1) }.reduce(0, +) / 3 }
            }
        }
        evalN += 1
        print(String(format: "  #%d %@ -> %.3f", evalN, x.map { String(format: "%.3f", $0) }.joined(separator: " "), total))
        return total
    }
    let x0 = params.map { $0.p.get() }
    let (best, val) = nelderMead(x0, step: params.map(\.step), maxEvals: maxEvals, objective)
    print("BEST \(name): " + zip(params, best).map { String(format: "%@=%.4f", $0.0.name, $0.1) }.joined(separator: ",") + String(format: "  (objective %.3f, start %.3f)", val, objective(x0)))
}

// MARK: - Main

@main
struct LRMatchCheck {
    struct CropSpec {
        let dir: String            // "ref100", "refhl"
        let size: (Int, Int)       // 1600×1067
        var origin: (Int, Int)?    // top-left in full-res oriented pixels; nil = centered (aligned at run time)
    }

    static func main() async throws {
        let args = CommandLine.arguments
        applyToneOverrides()
        if args.count > 2, args[1] == "fit" {
            let dngURL = URL(fileURLWithPath: "/Users/snivik/Pictures/Lightroom Tuning/L1100118.DNG")
            guard let src = RenderPipeline.makeSource(url: dngURL) else { exit(1) }
            runFit(name: args[2], source: src, tuning: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Containers/dev.snivik.sloproom/Data/tmp/tuning"),
                   maxEvals: args.count > 3 ? Int(args[3]) ?? 60 : 60)
            return
        }
        let dng = URL(fileURLWithPath: args.count > 1 && !args[1].isEmpty ? args[1] : "/Users/snivik/Pictures/Lightroom Tuning/L1100118.DNG")
        let tuning = URL(fileURLWithPath: args.count > 2 && !args[2].isEmpty ? args[2]
                         : NSHomeDirectory() + "/Library/Containers/dev.snivik.sloproom/Data/tmp/tuning")
        let label = args.count > 3 && !args[3].isEmpty ? args[3] : "run"
        let only = args.count > 4 && !args[4].isEmpty ? Set(args[4].lowercased().split(separator: ",").map(String.init)) : nil
        let doCrops = !(args.count > 5 && args[5] == "nocrop")
        let fm = FileManager.default
        let outRoot = tuning.appendingPathComponent("out").appendingPathComponent(label)
        try fm.createDirectory(at: outRoot, withIntermediateDirectories: true)

        var t = Date()
        guard let source = RenderPipeline.makeSource(url: dng) else { print("cannot open \(dng.path)"); exit(1) }
        print(String(format: "makeSource %.0f ms, %.0f×%.0f, baseline offset %+.2f EV", Date().timeIntervalSince(t) * 1000,
                     source.orientedSize.width, source.orientedSize.height, source.baselineOffset))

        // Discover sliders.
        let refDir = tuning.appendingPathComponent("ref")
        let folders = ((try? fm.contentsOfDirectory(atPath: refDir.path)) ?? []).sorted()
        var sliders: [(folder: String, spec: SliderSpec, values: [Double])] = []
        for folder in folders {
            guard let spec = sliderSpecs[folder.lowercased()] else {
                if !folder.hasPrefix(".") { print("  (skipping unknown slider folder \(folder))") }
                continue
            }
            if let only, !only.contains(folder.lowercased()) { continue }
            let files = (try? fm.contentsOfDirectory(atPath: refDir.appendingPathComponent(folder).path)) ?? []
            let values = files.compactMap { f -> Double? in
                guard f.hasSuffix(".jpg") else { return nil }
                return Double(f.dropLast(4).replacingOccurrences(of: "+", with: ""))
            }.sorted()
            guard values.contains(0), values.count > 1 else { print("  (\(folder): needs 0.jpg and one more value)"); continue }
            sliders.append((folder, spec, values))
        }
        print("Sliders: " + sliders.map { "\($0.folder) \($0.values.map(fmtValue))" }.joined(separator: ", "))

        func refURL(_ dir: String, _ folder: String, _ v: Double) -> URL {
            let d = tuning.appendingPathComponent(dir).appendingPathComponent(folder)
            for name in [fmtValue(v), v == v.rounded() ? String(Int(v)) : String(v)] {
                let u = d.appendingPathComponent(name + ".jpg")
                if fm.fileExists(atPath: u.path) { return u }
            }
            return d.appendingPathComponent(fmtValue(v) + ".jpg")
        }
        func settingsFor(_ spec: SliderSpec, _ v: Double) -> EditSettings { var s = EditSettings(); spec.apply(&s, v); return s }

        let target = CGSize(width: 1600, height: 1600)
        func renderWhole(_ s: EditSettings) -> CGImage? {
            RenderPipeline.makeCGImage(RenderPipeline.render(source: source, settings: s, targetSize: target), colorSpace: RenderPipeline.sRGB)
        }
        /// Full-resolution render (export path), cropped to a top-left-origin rect.
        func renderCrop(_ s: EditSettings, origin: (Int, Int), size: (Int, Int)) -> CGImage? {
            let full = RenderPipeline.render(source: source, settings: s)
            let H = Int(full.extent.height)
            let rect = CGRect(x: origin.0, y: H - origin.1 - size.1, width: size.0, height: size.1)
            return RenderPipeline.makeCGImage(full.cropped(to: rect), colorSpace: RenderPipeline.sRGB)
        }

        // ---- Whole-image baseline + alignment check (on the first slider's 0) ----
        var tsv = ""
        var ref0Whole: LabImage?
        if let first = sliders.first, let lr0cg = loadCG(refURL("ref", first.folder, 0)), let o0 = renderWhole(EditSettings()) {
            let lr0 = LabImage(cg: lr0cg), ours0 = LabImage(cg: o0)
            ref0Whole = lr0
            print(String(format: "\nWhole image: LR %d×%d, ours %d×%d", lr0.w, lr0.h, ours0.w, ours0.h))
            let qw = lr0.w / 4, qh = lr0.h / 4
            for (name, reg) in [("top-left", (40, 40, qw, qh)), ("top-right", (lr0.w - qw, 40, lr0.w - 40, qh)),
                                ("center", (lr0.w / 2 - qw / 2, lr0.h / 2 - qh / 2, lr0.w / 2 + qw / 2, lr0.h / 2 + qh / 2)),
                                ("bottom-left", (40, lr0.h - qh, qw, lr0.h - 40)), ("bottom-right", (lr0.w - qw, lr0.h - qh, lr0.w - 40, lr0.h - 40))] {
                let s = bestShift(lr0, ours0, region: reg, r: 3)
                print(String(format: "  alignment %-12@ ours shifted by (%+d, %+d) px, corr %.3f", name as NSString, s.0, s.1, s.2))
            }
            // Baseline per zone.
            var zn = [Int](repeating: 0, count: 8), zd = [Double](repeating: 0, count: 8), zc = [Double](repeating: 0, count: 8)
            var absd = 0.0, n = 0
            let w = min(lr0.w, ours0.w), h = min(lr0.h, ours0.h)
            for y in 8..<(h - 8) { for x in 8..<(w - 8) {
                let il = y * lr0.w + x, io = y * ours0.w + x
                let z = zoneIndex(lr0.L[il]); zn[z] += 1
                zd[z] += Double(ours0.L[io] - lr0.L[il]); zc[z] += Double(ours0.C[io] - lr0.C[il])
                absd += Double(abs(ours0.L[io] - lr0.L[il])); n += 1
            } }
            print("  baseline ours(0) − LR(0) by LR zone (L* zone: n%, ΔL*, ΔC*):")
            var line = "   "
            for z in 0..<8 where zn[z] > 0 {
                line += String(format: " [%2d-%3d] %4.1f%% %+5.1f %+5.1f |", z * 12 + z / 2, (z + 1) * 12 + (z + 1) / 2,
                               100 * Double(zn[z]) / Double(n), zd[z] / Double(zn[z]), zc[z] / Double(zn[z]))
            }
            print(line)
            print(String(format: "  baseline mean |ΔL*| %.2f", absd / Double(max(n, 1))))
            tsv += String(format: "baseline\t0\tmeanAbsDL\t%.3f\n", absd / Double(max(n, 1)))
            // Are all LR 0.jpg the same rendering?
            for s in sliders.dropFirst() {
                if let cg = loadCG(refURL("ref", s.folder, 0)) {
                    let o = LabImage(cg: cg)
                    var d = 0.0
                    for i in 0..<min(o.L.count, lr0.L.count) { d += Double(abs(o.L[i] - lr0.L[i])) }
                    print(String(format: "  LR %@/0.jpg vs %@/0.jpg: mean |ΔL*| %.3f", s.folder, first.folder, d / Double(lr0.L.count)))
                }
            }
        }
        _ = ref0Whole

        // ---- Crop windows ----
        var crops: [CropSpec] = []
        if doCrops {
            crops.append(CropSpec(dir: "ref100", size: (1600, 1067), origin: nil))
            crops.append(CropSpec(dir: "refhl", size: (1600, 1067), origin: (2615, 1177)))   // bright metal (sips --cropOffset 1177 2615)
        }
        // Resolve the centered crop origin by alignment against the first slider that has ref100/…/0.jpg.
        for ci in crops.indices where crops[ci].origin == nil {
            let size = crops[ci].size
            let nominal = ((Int(source.orientedSize.width) - size.0) / 2, (Int(source.orientedSize.height) - size.1) / 2)
            guard let s = sliders.first(where: { fm.fileExists(atPath: refURL(crops[ci].dir, $0.folder, 0).path) }),
                  let lrcg = loadCG(refURL(crops[ci].dir, s.folder, 0)) else { continue }
            let m = 6
            guard let big = renderCrop(EditSettings(), origin: (nominal.0 - m, nominal.1 - m), size: (size.0 + 2 * m, size.1 + 2 * m)) else { continue }
            let lr = LabImage(cg: lrcg), ours = LabImage(cg: big)
            let sh = bestShift(lr, ours, region: (40, 40, lr.w - 40, lr.h - 40), r: m)
            crops[ci].origin = (nominal.0 - m + sh.0, nominal.1 - m + sh.1)
            print(String(format: "\n%@: centered crop aligned at full-res origin (%d, %d) (nominal (%d, %d)), corr %.3f",
                         crops[ci].dir, crops[ci].origin!.0, crops[ci].origin!.1, nominal.0, nominal.1, sh.2))
        }

        // ---- Per slider ----
        var timing: [String] = []
        for s in sliders {
            print("\n=== \(s.folder) ===")
            struct Variant { let name: String; let refDir: String; let ourDir: String; let montageDir: String; let isCrop: Bool; let crop: CropSpec? }
            var variants = [Variant(name: "whole", refDir: "ref", ourDir: "ours", montageDir: "montage", isCrop: false, crop: nil)]
            for c in crops where c.origin != nil && fm.fileExists(atPath: refURL(c.dir, s.folder, 0).path) {
                let suffix = String(c.dir.dropFirst(3))   // "100", "hl"
                variants.append(Variant(name: c.dir, refDir: c.dir, ourDir: "ours" + suffix, montageDir: "montage" + suffix, isCrop: true, crop: c))
            }
            for vt in variants {
                guard let lr0cg = loadCG(refURL(vt.refDir, s.folder, 0)) else { continue }
                var ours: [Double: CGImage] = [:]
                for v in s.values {
                    let st = settingsFor(s.spec, v)
                    t = Date()
                    let cg = vt.isCrop ? renderCrop(st, origin: vt.crop!.origin!, size: vt.crop!.size) : renderWhole(st)
                    let ms = Date().timeIntervalSince(t) * 1000
                    guard let cg else { print("  render failed \(v)"); continue }
                    ours[v] = cg
                    timing.append(String(format: "%@ %@ %@: %.0f ms", s.folder, vt.name, fmtValue(v), ms))
                    writeJPEG(cg, to: outRoot.appendingPathComponent(vt.ourDir).appendingPathComponent(s.folder).appendingPathComponent(fmtValue(v) + ".jpg"))
                }
                guard let o0cg = ours[0] else { continue }
                let lr0 = LabImage(cg: lr0cg), o0 = LabImage(cg: o0cg)
                let detail = ["texture", "clarity", "dehaze"].contains(s.spec.name) || vt.isCrop
                let roi = (8, 8, min(lr0.w, o0.w) - 8, min(lr0.h, o0.h) - 8)
                let b0 = detail ? (lr: bandEnergies(lr0, roi: roi), ours: bandEnergies(o0, roi: roi)) : nil
                var rows: [[(String, CGImage)]] = []
                print("  [\(vt.name)]")
                for v in s.values {
                    guard let ocg = ours[v], let lrcg = loadCG(refURL(vt.refDir, s.folder, v)) else { continue }
                    rows.append([("LR \(fmtValue(v))", lrcg), ("ours \(fmtValue(v))", ocg)])
                    guard v != 0 else { continue }
                    let m = effectMetrics(lr0: lr0, lrV: LabImage(cg: lrcg), our0: o0, ourV: LabImage(cg: ocg),
                                          border: 8, bands: detail, bands0: b0)
                    var zl = "    zones ΔL* LR/ours:"
                    for z in 0..<8 where m.zoneN[z] > 200 { zl += String(format: " z%d %+5.1f/%+5.1f", z, m.zoneLRdL[z], m.zoneOursdL[z]) }
                    var zc = "    zones ΔC* LR/ours:"
                    for z in 0..<8 where m.zoneN[z] > 200 { zc += String(format: " z%d %+5.1f/%+5.1f", z, m.zoneLRdC[z], m.zoneOursdC[z]) }
                    print(String(format: "  %@ %@: zoneL %.2f zoneC %.2f | eff %.1f%% (err %.2f / LR %.2f L*) | dark Δ LR %+.3f ours %+.3f | chroma Δ LR %+.2f ours %+.2f",
                                 s.folder, fmtValue(v), m.zoneL, m.zoneC, m.effPct, m.effRMS, m.lrRMS, m.darkLR, m.darkOurs, m.chromaLR, m.chromaOurs))
                    print(zl); print(zc)
                    if ProcessInfo.processInfo.environment["CURVES"] != nil {
                        print("    curve LR  : " + transferTable(lr0, LabImage(cg: lrcg)))
                        print("    curve ours: " + transferTable(o0, LabImage(cg: ocg)))
                    }
                    if !m.bandsLR.isEmpty {
                        print(String(format: "    bands log2(E/E0) fine/med/coarse: LR %+.2f %+.2f %+.2f | ours %+.2f %+.2f %+.2f",
                                     m.bandsLR[0], m.bandsLR[1], m.bandsLR[2], m.bandsOurs[0], m.bandsOurs[1], m.bandsOurs[2]))
                    }
                    let bandErr = m.bandsLR.isEmpty ? 0 : zip(m.bandsLR, m.bandsOurs).map { abs($0 - $1) }.reduce(0, +) / 3
                    tsv += String(format: "%@\t%@\t%@\tzoneL\t%.3f\tzoneC\t%.3f\teff%%\t%.1f\tbandErr\t%.3f\tdarkLR\t%.4f\tdarkOurs\t%.4f\n",
                                  s.folder, vt.name, fmtValue(v), m.zoneL, m.zoneC, m.effPct, bandErr, m.darkLR, m.darkOurs)
                }
                if let mg = montage(rows, cellW: 800, crop1to1: vt.isCrop) {
                    writeJPEG(mg, to: outRoot.appendingPathComponent(vt.montageDir).appendingPathComponent(s.folder + ".jpg"), quality: 0.88)
                }
            }
            // ±50 ladder of ours (whole image): plausible interpolation check.
            let lo = s.values.first!, hi = s.values.last!
            let ladder = [lo, lo / 2, 0, hi / 2, hi]
            var cells: [(String, CGImage)] = []
            for v in ladder { if let cg = renderWhole(settingsFor(s.spec, v)) { cells.append(("ours \(fmtValue(v))", cg)) } }
            if cells.count == 5, let mg = montage([Array(cells[0..<3]), Array(cells[3..<5])], cellW: 640, crop1to1: false) {
                writeJPEG(mg, to: outRoot.appendingPathComponent("ladder").appendingPathComponent(s.folder + ".jpg"), quality: 0.85)
            }
        }
        // Sliders without Lightroom references: sanity ladder (ours only) + monotonic / clipping checks.
        if let list = ProcessInfo.processInfo.environment["SANITY"] {
            var w0: LabImage?
            if let cg = renderWhole(EditSettings()) { w0 = LabImage(cg: cg) }
            for name in list.lowercased().split(separator: ",").map(String.init) {
                guard let spec = sliderSpecs[name], let o0 = w0 else { continue }
                let vals: [Double] = name == "exposure" ? [-2, -1, 0, 1, 2] : [-100, -50, 0, 50, 100]
                var cells: [(String, CGImage)] = []
                print("\n=== sanity \(name) ===")
                func clipFrac(_ a: LabImage) -> (Double, Double) {
                    var hi = 0, lo = 0
                    for l in a.L { if l > 99.0 { hi += 1 } else if l < 1.0 { lo += 1 } }
                    return (100 * Double(hi) / Double(a.L.count), 100 * Double(lo) / Double(a.L.count))
                }
                let c0 = clipFrac(o0)
                print(String(format: "  0: clipped white %.2f%%, black %.2f%%", c0.0, c0.1))
                for v in vals {
                    guard let cg = renderWhole(settingsFor(spec, v)) else { continue }
                    cells.append(("ours \(fmtValue(v))", cg))
                    guard v != 0 else { continue }
                    let o = LabImage(cg: cg)
                    // Mean L*(v) per L*(0) bin must increase with the bin (no inversion).
                    var n = [Int](repeating: 0, count: 20), l = [Double](repeating: 0, count: 20)
                    for i in 0..<min(o.L.count, o0.L.count) { let b = min(19, max(0, Int(o0.L[i] / 5))); n[b] += 1; l[b] += Double(o.L[i]) }
                    let means = (0..<20).filter { n[$0] > 200 }.map { l[$0] / Double(n[$0]) }
                    let monotonic = zip(means, means.dropFirst()).allSatisfy { $1 >= $0 - 0.3 }
                    let c = clipFrac(o)
                    print(String(format: "  %@: clipped white %.2f%% black %.2f%% | monotonic %@ | curve %@", fmtValue(v), c.0, c.1,
                                 monotonic ? "yes" : "NO", means.map { String(format: "%.0f", $0) }.joined(separator: " ")))
                }
                if cells.count == 5, let mg = montage([Array(cells[0..<3]), Array(cells[3..<5])], cellW: 640, crop1to1: false) {
                    writeJPEG(mg, to: outRoot.appendingPathComponent("sanity").appendingPathComponent(name + ".jpg"), quality: 0.85)
                }
            }
        }
        print("\nTimings (cold, harness context):")
        for l in timing { print("  " + l) }
        let tsvURL = outRoot.appendingPathComponent("metrics.tsv")
        try? tsv.write(to: tsvURL, atomically: true, encoding: .utf8)
        print("\nmetrics -> \(tsvURL.path)")
        print("ALL LRMATCH DONE")
    }
}
