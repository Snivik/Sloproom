//
//  DevelopKernels.swift
//  sloproom
//
//  Custom Core Image color kernels for the develop stages, written in Metal and compiled at
//  runtime with `CIKernel.kernels(withMetalString:)` (no -fcikernel build flags needed; requires a
//  Metal-backed CIContext, which RenderPipeline always uses on Apple Silicon).
//
//  Conventions (see docs/ARCHITECTURE.md "Color spaces per stage"):
//  - Inputs are the pipeline working space: LINEAR, extended-range sRGB primaries.
//  - "P" = perceptual luminance = Y^(1/2.2) (Y = Rec.709 luminance, sign-preserving). Tone and
//    detail operations work on P and are applied back to RGB as a luminance ratio (keeps hue).
//  - Color operations (vibrance, saturation, color mixer) work in Oklab / OkLCh.
//

import Foundation
import CoreImage

nonisolated enum DevelopKernels {
    /// Perceptual luminance P in RGB (alpha 1). Guide/base image for local operations.
    static let perceptualLuma = kernel("dk_perceptualLuma")
    /// Perceptual (P-encoded) min(r, g, b) in RGB — dark channel for dehaze.
    static let darkChannel = kernel("dk_darkChannel")
    /// Guided filter: (guide I, value p) -> (I, I², p, I·p).
    static let guidedPack = kernel("dk_gfPack")
    /// Guided filter: (blurred pack, eps) -> (a, b, 0, 1).
    static let guidedCoefficients = kernel("dk_gfAB")
    /// Guided filter: (guide I, upsampled (a, b)) -> q = a·I + b in RGB.
    static let guidedApply = kernel("dk_gfApply")
    /// (image, base, a = contrast/highlights/shadows/whites, b = blacks/useBase/liftLo/liftHi,
    ///  hn, hp, sn, sp, m, d = AdjustmentOps.ToneModel rows), sliders -1...1.
    static let tone = kernel("dk_tone")
    /// (image, textureBlur, clarityBase, k = texture/clarity/-/-, m = AdjustmentOps.PresenceModel detail row), -1...1.
    static let detail = kernel("dk_detail")
    /// (image, darkBase, amount -1...1, plus = dehaze+ row, minus = dehaze− row of AdjustmentOps.PresenceModel).
    static let dehaze = kernel("dk_dehaze")
    /// (image, p = vibrance/saturation/-/-).
    static let vibranceSaturation = kernel("dk_vibSat")
    /// (image, hue0, hue1, sat0, sat1, lum0, lum1): 8 bands as two float4 each, -1...1.
    static let colorMixer = kernel("dk_colorMixer")
    /// (image, rect = x/y/w/h of the final extent, p = amount/midpoint/roundness/feather).
    static let vignette = kernel("dk_vignette")
    /// (image, noise (r channel, mean 0.5), amount).
    static let grain = kernel("dk_grain")
    /// (image, range = (start, end) max-channel levels): fades color to neutral (same luminance) towards the raw clip.
    static let clipNeutral = kernel("dk_clipNeutral")
    /// (image, knee P, hue keep 0…1): (partly) hue-preserving per-channel highlight shoulder of the extended range into 0…1 (OutputStage).
    static let shoulder = kernel("dk_shoulder")

    /// Each kernel is compiled from its OWN Metal source (shared helpers + one function):
    /// Core Image resolves every kernel of a multi-function Metal string to the same function.
    private static func kernel(_ name: String) -> CIColorKernel? {
        guard let body = kernelSources[name] else { return nil }
        let source = prelude + "extern \"C\" { namespace coreimage {\n" + body + "\n}}\n"
        do {
            let kernels = try CIKernel.kernels(withMetalString: source)
            if let k = kernels.first(where: { $0.name == name }) as? CIColorKernel { return k }
            print("DevelopKernels: \(name) not found in compiled source")
        } catch {
            print("DevelopKernels: failed to compile \(name): \(error)")
        }
        return nil
    }

    /// Compiles all kernels (call once off the main thread, e.g. when Develop opens).
    static func warmUp() {
        _ = [perceptualLuma, darkChannel, guidedPack, guidedCoefficients, guidedApply, tone, detail, dehaze, vibranceSaturation, colorMixer, vignette, grain, shoulder, clipNeutral]
    }

    /// Runs a kernel over `image`'s extent; returns `image` unchanged if the kernel is unavailable.
    static func apply(_ kernel: CIColorKernel?, _ image: CIImage, _ args: [Any]) -> CIImage {
        guard let kernel else { return image }
        return kernel.apply(extent: image.extent, arguments: [image] + args) ?? image
    }

    static func vector(_ a: Double, _ b: Double = 0, _ c: Double = 0, _ d: Double = 0) -> CIVector {
        CIVector(x: CGFloat(a), y: CGFloat(b), z: CGFloat(c), w: CGFloat(d))
    }

    // MARK: - Metal source

    private static let prelude = #"""
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    namespace dk {
        constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);
        inline float luma(float3 c) { return dot(c, kLuma); }
        inline float toP(float y) { return sign(y) * pow(abs(y), 1.0 / 2.2); }
        inline float fromP(float p) { return sign(p) * pow(abs(p), 2.2); }

        /// Scales rgb so its luminance becomes yNew (keeps chromaticity); near-black adds gray.
        inline float3 withLuma(float3 c, float y, float yNew) {
            if (y > 1e-5) { return c * (yNew / y); }
            return c + (yNew - y);
        }

        /// Applies a new perceptual luminance p2 (was p). Darkening scales rgb (keeps hue and
        /// saturation); lifting near-black pixels adds neutral light instead, so their unreliable
        /// chroma (noise, flare) isn't amplified into colored blotches.
        inline float3 withP(float3 c, float y, float p, float p2) {
            float y2 = fromP(max(p2, 0.0));
            float3 ratio = withLuma(c, y, y2);
            if (p2 <= p) { return ratio; }
            float m = 1.0 - smoothstep(0.03, 0.22, p);
            return mix(ratio, c + (y2 - y), m);
        }

        inline float cbrtS(float x) { return sign(x) * pow(abs(x), 1.0 / 3.0); }

        inline float3 toOklab(float3 c) {
            float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
            float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
            float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
            l = cbrtS(l); m = cbrtS(m); s = cbrtS(s);
            return float3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                          1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                          0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s);
        }

        inline float3 fromOklab(float3 lab) {
            float l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
            float m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
            float s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
            l = l * l * l; m = m * m * m; s = s * s * s;
            return float3( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                          -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                          -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
        }

        /// Smooth max(t, 0) with a knee of width k (hyperbola): 0 far below, t far above.
        inline float softPos(float t, float k) { return 0.5 * (t + sqrt(t * t + k * k)); }

        /// Contrast: a power curve in P around a mid-gray pivot (= a slope change in log
        /// luminance), c in -1...1. Extends smoothly above 1; OutputStage rolls the top off.
        inline float contrastCurve(float x, float c, float k) {
            const float pv = 0.46;
            if (c == 0.0 || x <= 0.0) { return x; }
            return pv * pow(x / pv, exp2(k * c));
        }

        /// Highlights / shadows (EV gains from the smooth base's log luminance, Lightroom-like:
        /// power-law compression / expansion of the base above / below a pivot), whites / blacks /
        /// contrast, on perceptual luminance. b = local (smoothed) P. Model rows (see AdjustmentOps.ToneModel):
        /// hn/hp/sn/sp = (slope EV per stop, pivot log2 Y, knee width stops, cap EV), m = (-, contrast, whites, blacks).
        inline float toneP(float p, float b, float bs, float4 a, float blacks,
                           float4 hn, float4 hp, float4 sn, float4 sp, float4 m, float4 d) {
            float x = contrastCurve(p, a.x, m.y);
            float lb = log2(max(fromP(max(b, 0.0)), 1e-6));
            float evH = 0.0, evS = 0.0;
            if (a.y < 0.0) { evH = a.y * min(hn.x * softPos(lb - hn.y, hn.z), hn.w); }
            if (a.y > 0.0) { evH = a.y * min(hp.x * softPos(lb - hp.y, hp.z), hp.w); }
            if (a.z > 0.0) { evS = a.z * min(sp.x * softPos(sp.y - lb, sp.z), sp.w); }
            if (a.z < 0.0) { evS = a.z * min(sn.x * softPos(sn.y - lb, sn.z), sn.w); }
            // Applied as a gain on P (local contrast scales with the region, like a ratio); a share
            // `keep` of the detail around the smooth base `bs` keeps its perceptual amplitude instead
            // (d.x for highlights, d.y for shadows).
            float g = exp2((evH + evS) / 2.2);
            float keep = (abs(evH) * d.x + abs(evS) * d.y) / max(abs(evH) + abs(evS), 1e-6);
            x = x * g + keep * (1.0 - g) * (x - bs);
            // Whites: scale the top of the curve (incl. the extended range above 1).
            x *= 1.0 + m.z * a.w * smoothstep(0.25, 1.0, x);
            // Blacks: move the black point, fading out towards the midtones.
            float bp = -m.w * blacks;
            float moved = (x - bp) / (1.0 - bp);
            x = mix(moved, x, smoothstep(0.0, 0.55, x));
            return x;
        }

        /// withP for tone lifts: keeps the pixel's chroma (luminance ratio) except in the deepest
        /// shadows (P < lo…hi), where lifting adds neutral light so noise isn't colored up.
        inline float3 withPLift(float3 c, float y, float p, float p2, float lo, float hi) {
            float y2 = fromP(max(p2, 0.0));
            float3 ratio = withLuma(c, y, y2);
            if (p2 <= p) { return ratio; }
            float m = 1.0 - smoothstep(lo, hi, p);
            return mix(ratio, c + (y2 - y), m);
        }

        /// Smooth partition of unity over the 8 color-mixer bands (OkLCh hue, degrees).
        constant float kBandHue[8] = { 29.2, 55.0, 105.0, 142.5, 194.8, 264.1, 293.8, 328.4 };

        inline void bandWeights(float h, thread int &i0, thread int &i1, thread float &t) {
            i0 = 7; i1 = 0;
            for (int i = 0; i < 8; i++) {
                int j = (i + 1) % 8;
                float c0 = kBandHue[i], c1 = kBandHue[j] + (j == 0 ? 360.0 : 0.0);
                float hh = (j == 0 && h < c0) ? h + 360.0 : h;
                if (hh >= c0 && hh < c1) { i0 = i; i1 = j; t = (hh - c0) / (c1 - c0); t = t * t * (3.0 - 2.0 * t); return; }
            }
            t = 0.0;
        }

        inline float gapNext(int i) { float d = kBandHue[(i + 1) % 8] - kBandHue[i]; return d < 0.0 ? d + 360.0 : d; }
        inline float gapPrev(int i) { float d = kBandHue[i] - kBandHue[(i + 7) % 8]; return d < 0.0 ? d + 360.0 : d; }
        inline float band(float4 lo, float4 hi, int i) { return i < 4 ? lo[i] : hi[i - 4]; }
    }

    """#

    private static let kernelSources: [String: String] = [
        "dk_perceptualLuma": #"""
    [[stitchable]] float4 dk_perceptualLuma(sample_t s) {
        float p = dk::toP(dk::luma(s.rgb));
        return float4(p, p, p, 1.0);
    }
    """#,
        "dk_darkChannel": #"""
    [[stitchable]] float4 dk_darkChannel(sample_t s) {
        float d = dk::toP(max(min(min(s.r, s.g), s.b), 0.0));
        return float4(d, d, d, 1.0);
    }
    """#,
        "dk_gfPack": #"""
    [[stitchable]] float4 dk_gfPack(sample_t i, sample_t p) {
        return float4(i.r, i.r * i.r, p.r, i.r * p.r);
    }
    """#,
        "dk_gfAB": #"""
    [[stitchable]] float4 dk_gfAB(sample_t m, float eps) {
        float varI = max(m.g - m.r * m.r, 0.0);
        float cov = m.a - m.r * m.b;
        float a = cov / (varI + eps);
        return float4(a, m.b - a * m.r, 0.0, 1.0);
    }
    """#,
        "dk_gfApply": #"""
    [[stitchable]] float4 dk_gfApply(sample_t i, sample_t ab) {
        float q = ab.r * i.r + ab.g;
        return float4(q, q, q, 1.0);
    }
    """#,
        "dk_tone": #"""
    [[stitchable]] float4 dk_tone(sample_t s, sample_t base, float4 a, float4 b,
                                  float4 hn, float4 hp, float4 sn, float4 sp, float4 m, float4 d) {
        float y = dk::luma(s.rgb);
        float p = dk::toP(max(y, 0.0));
        float bs = b.y > 0.5 ? base.r : p;
        float bp = mix(p, bs, m.x);
        float p2 = dk::toneP(p, bp, bs, a, b.x, hn, hp, sn, sp, m, d);
        return float4(dk::withPLift(s.rgb, max(y, 0.0), p, p2, b.z, b.w), s.a);
    }
    """#,
        "dk_detail": #"""
    [[stitchable]] float4 dk_detail(sample_t s, sample_t texBlur, sample_t clarityBase, float4 k, float4 m) {
        float y = dk::luma(s.rgb);
        float p = dk::toP(max(y, 0.0));
        // Texture: unsharp mask on P with a small radius (fine and medium detail; negative smooths).
        float kt = k.x > 0.0 ? m.x * k.x : m.y * k.x;
        float pt = p + kt * (p - texBlur.r);
        // Clarity: local contrast around a large, mildly edge-aware base, weighted to the midtones.
        float pc = clamp(p, 0.0, 1.0);
        float mid = clamp(1.0 - pow(abs(2.0 * pc - 1.0), 2.0), 0.0, 1.0);
        float kc = k.y > 0.0 ? m.z * k.y : m.w * k.y;
        float p2 = pt + kc * (p - clarityBase.r) * mid;
        return float4(dk::withP(s.rgb, max(y, 0.0), p, p2), s.a);
    }
    """#,
        "dk_dehaze": #"""
    [[stitchable]] float4 dk_dehaze(sample_t s, sample_t darkBase, float amount, float4 plus, float4 minus) {
        // Haze model I = J·t + A·(1 − t) on P-encoded channels (dark channel prior, airlight A):
        // amount > 0 removes it (J = (I − A)/t + A, t from the smoothed dark channel),
        // amount < 0 adds a veil whose density follows the dark channel.
        float3 c = s.rgb;
        float3 pc = float3(dk::toP(c.r), dk::toP(c.g), dk::toP(c.b));
        float d = clamp(darkBase.r, 0.0, 1.0);
        if (amount > 0.0) {
            float A = plus.y;
            float t = max(1.0 - amount * plus.x * pow(d / A, plus.w), plus.z);
            pc = (pc - A) / t + A;
            pc = max(pc, float3(-0.02));
        } else {
            float k = -amount;
            float t = clamp(1.0 - k * (minus.x + minus.y * d), 0.05, 1.0);
            pc = pc * t + minus.z * (1.0 - t);
            float yp = dk::luma(pc);
            pc = mix(pc, float3(yp), clamp(k * minus.w, 0.0, 1.0));
        }
        return float4(dk::fromP(pc.r), dk::fromP(pc.g), dk::fromP(pc.b), s.a);
    }
    """#,
        "dk_vibSat": #"""
    [[stitchable]] float4 dk_vibSat(sample_t s, float4 p) {
        float3 lab = dk::toOklab(s.rgb);
        float C = length(lab.yz);
        float h = atan2(lab.z, lab.y) * 57.29578;
        if (h < 0.0) { h += 360.0; }
        float gain = 1.0 + p.y;
        float lowSat = 1.0 - smoothstep(0.0, 0.18, C);
        if (p.x > 0.0) {
            // Skin tones (OkLCh hue ~ 25...85°, moderate chroma) are protected.
            float dh = abs(h - 55.0);
            float skin = (1.0 - smoothstep(22.0, 40.0, dh)) * (1.0 - smoothstep(0.1, 0.18, C));
            gain *= 1.0 + 1.0 * p.x * lowSat * (1.0 - 0.8 * skin);
        } else {
            gain *= 1.0 + p.x * (0.5 + 0.5 * lowSat);
        }
        lab.yz *= max(gain, 0.0);
        return float4(dk::fromOklab(lab), s.a);
    }
    """#,
        "dk_colorMixer": #"""
    [[stitchable]] float4 dk_colorMixer(sample_t s, float4 h0, float4 h1, float4 s0, float4 s1, float4 l0, float4 l1) {
        float3 lab = dk::toOklab(s.rgb);
        float C = length(lab.yz);
        if (C < 1e-4) { return s; }
        float h = atan2(lab.z, lab.y) * 57.29578;
        if (h < 0.0) { h += 360.0; }
        int i0, i1; float t;
        dk::bandWeights(h, i0, i1, t);
        float w0 = 1.0 - t, w1 = t;
        float hs0 = dk::band(h0, h1, i0), hs1 = dk::band(h0, h1, i1);
        float dh = w0 * hs0 * 0.6 * (hs0 > 0.0 ? dk::gapNext(i0) : dk::gapPrev(i0))
                 + w1 * hs1 * 0.6 * (hs1 > 0.0 ? dk::gapNext(i1) : dk::gapPrev(i1));
        float ds = w0 * dk::band(s0, s1, i0) + w1 * dk::band(s0, s1, i1);
        float dl = w0 * dk::band(l0, l1, i0) + w1 * dk::band(l0, l1, i1);
        // Near-neutral pixels have an unstable hue: fade the effect in with chroma.
        float f = smoothstep(0.0, 0.05, C);
        float hr = (h + dh * f) * 0.017453293;
        float C2 = C * max(1.0 + ds * f, 0.0);
        float L2 = lab.x * (1.0 + (dl > 0.0 ? 0.35 : 0.3) * dl * smoothstep(0.0, 0.03, C));
        return float4(dk::fromOklab(float3(L2, C2 * cos(hr), C2 * sin(hr))), s.a);
    }
    """#,
        "dk_vignette": #"""
    [[stitchable]] float4 dk_vignette(sample_t s, float4 rect, float4 p, destination dest) {
        float2 c = rect.xy + rect.zw * 0.5;
        float2 u = (dest.coord() - c) / (rect.zw * 0.5);         // -1...1 across the frame
        float roundness = p.z;
        // roundness > 0: towards a circle (in pixels); < 0: towards a rounded rectangle.
        float m = min(rect.z, rect.w);
        float2 axis = mix(float2(1.0), rect.zw / m, max(roundness, 0.0));
        float n = 2.0 + 6.0 * max(-roundness, 0.0);
        float2 v = abs(u * axis);
        float d = pow(pow(v.x, n) + pow(v.y, n), 1.0 / n) / pow(pow(axis.x, n) + pow(axis.y, n), 1.0 / n);
        float d0 = 0.25 + 0.7 * p.y;                              // midpoint
        float f = max(p.w, 0.02);                                 // feather
        float w = smoothstep(d0 * (1.0 - f), d0 + (1.2 - d0) * f, d);
        float y = dk::luma(s.rgb);
        float pp = dk::toP(max(y, 0.0));
        float amt = p.x;
        float p2 = amt < 0.0 ? pp * (1.0 + 0.95 * amt * w) : pp + (1.0 - min(pp, 1.0)) * 0.9 * amt * w;
        return float4(dk::withP(s.rgb, max(y, 0.0), pp, p2), s.a);
    }
    """#,
        "dk_grain": #"""
    [[stitchable]] float4 dk_grain(sample_t s, sample_t noise, float amount) {
        float y = dk::luma(s.rgb);
        float p = dk::toP(max(y, 0.0));
        float pc = clamp(p, 0.0, 1.0);
        float w = 0.35 + 2.6 * pc * (1.0 - pc);
        float p2 = p + (noise.r - 0.5) * amount * w;
        // Monochrome (luminance-only) grain.
        return float4(dk::withP(s.rgb, max(y, 0.0), p, p2), s.a);
    }
    """#,
        "dk_clipNeutral": #"""
    [[stitchable]] float4 dk_clipNeutral(sample_t s, float4 r) {
        float m = max(max(s.r, s.g), s.b);
        if (m <= r.x) { return s; }
        float t = smoothstep(r.x, r.y, m);
        float y = dk::luma(s.rgb);
        return float4(mix(s.rgb, float3(y), t), s.a);
    }
    """#,
        "dk_shoulder": #"""
    [[stitchable]] float4 dk_shoulder(sample_t s, float knee, float hueKeep) {
        // Per channel, in P: identity below the knee, then an exponential approach to 1
        // (slope 1 at the knee, so no visible break). Bright saturated colors therefore move
        // towards white like film / Lightroom; the middle channel is then re-placed between the
        // new max and min channels so the HUE is kept (a plain per-channel curve turns a bright
        // blue sky cyan).
        float3 c = s.rgb;
        float hi = max(max(c.r, c.g), c.b);
        float kl = dk::fromP(knee);
        if (hi <= kl) { return s; }
        float w = 1.0 - knee;
        float3 p = float3(dk::toP(max(c.r, 0.0)), dk::toP(max(c.g, 0.0)), dk::toP(max(c.b, 0.0)));
        float3 q = select(p, knee + w * (1.0 - exp(-(p - knee) / w)), p > knee);
        float3 o = float3(dk::fromP(q.r), dk::fromP(q.g), dk::fromP(q.b));
        float lo = min(min(c.r, c.g), c.b);
        if (hi - lo > 1e-5) {
            float hiO = max(max(o.r, o.g), o.b), loO = min(min(o.r, o.g), o.b);
            o = mix(o, loO + (hiO - loO) * (c - lo) / (hi - lo), hueKeep);
        }
        return float4(o, s.a);
    }
    """#,
    ]
}
